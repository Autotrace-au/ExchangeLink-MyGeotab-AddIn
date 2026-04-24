import base64
import json
import logging
import os
import shutil
import subprocess
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from threading import Lock
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import azure.functions as func
from azure.data.tables import TableServiceClient, UpdateMode
from azure.core.exceptions import ResourceExistsError
from azure.storage.queue import QueueClient
from mygeotab import API


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
BASE_DIR = Path(__file__).resolve().parent
EXCHANGE_SYNC_SCRIPT = BASE_DIR / "exchange_sync.ps1"
SYNC_JOBS_TABLE_NAME = "FleetBridgeSyncJobs"
SYNC_CONFIG_TABLE_NAME = "FleetBridgeSyncConfig"
SYNC_QUEUE_NAME = "fleetbridge-sync-jobs"
SYNC_JOBS_PARTITION_KEY = "syncjobs"
SYNC_CONFIG_PARTITION_KEY = "config"
SYNC_SCHEDULE_ROW_KEY = "syncSchedule"
MAX_RESULT_STORAGE_CHARS = 800_000
PROGRESS_LINE_PREFIX = "__FLEETBRIDGE_PROGRESS__"
CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
}
SCHEDULE_PRESET_EVERY_15_MINUTES = "every-15-minutes"
SCHEDULE_PRESET_HOURLY = "hourly"
SCHEDULE_PRESET_DAILY = "daily"
SCHEDULE_PRESET_WEEKLY = "weekly"
VALID_SCHEDULE_PRESETS = {
    SCHEDULE_PRESET_EVERY_15_MINUTES,
    SCHEDULE_PRESET_HOURLY,
    SCHEDULE_PRESET_DAILY,
    SCHEDULE_PRESET_WEEKLY,
}
WEEKDAY_NAMES = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
]
SCHEDULE_TRIGGER_SOURCES = {"manual", "scheduled"}

PROPERTY_NAME_MAP = {
    "Enable Equipment Booking": "bookable",
    "Allow Recurring Bookings": "recurring",
    "Booking Approvers": "approvers",
    "Fleet Managers": "fleetManagers",
    "Allow Double Booking": "conflicts",
    "Booking Window (Days)": "windowDays",
    "Maximum Booking Duration (Hours)": "maxDurationHours",
    "Mailbox Language": "language",
}

UPDATE_PROPERTY_NAME_MAP = {
    "bookable": "Enable Equipment Booking",
    "recurring": "Allow Recurring Bookings",
    "approvers": "Booking Approvers",
    "fleetManagers": "Fleet Managers",
    "conflicts": "Allow Double Booking",
    "windowDays": "Booking Window (Days)",
    "maxDurationHours": "Maximum Booking Duration (Hours)",
    "language": "Mailbox Language",
}

DEFAULT_PROPERTY_VALUES = {
    "bookable": False,
    "recurring": False,
    "approvers": "",
    "fleetManagers": "",
    "conflicts": False,
    "windowDays": 90,
    "maxDurationHours": 24,
    "language": "en-AU",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().isoformat()


def bool_setting(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def int_setting(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default


def chunked(items: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    if size <= 0:
        return [items]
    return [items[index : index + size] for index in range(0, len(items), size)]


def json_response(
    payload: dict[str, Any],
    status_code: int = 200,
    headers: dict[str, str] | None = None,
) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
        headers={**CORS_HEADERS, **(headers or {})},
    )


def cors_preflight_response() -> func.HttpResponse:
    return func.HttpResponse(status_code=204, headers=CORS_HEADERS)


def parse_json(req: func.HttpRequest) -> dict[str, Any]:
    try:
        body = req.get_json()
    except ValueError:
        body = {}
    return body if isinstance(body, dict) else {}


def get_table_client(table_name: str):
    connection_string = os.getenv("AzureWebJobsStorage", "")
    if not connection_string:
        raise RuntimeError("AzureWebJobsStorage is not configured")

    service_client = TableServiceClient.from_connection_string(connection_string)
    service_client.create_table_if_not_exists(table_name)
    table_client = service_client.get_table_client(table_name)
    return table_client


def get_jobs_table_client():
    return get_table_client(SYNC_JOBS_TABLE_NAME)


def get_config_table_client():
    return get_table_client(SYNC_CONFIG_TABLE_NAME)


def get_queue_client() -> QueueClient:
    connection_string = os.getenv("AzureWebJobsStorage", "")
    if not connection_string:
        raise RuntimeError("AzureWebJobsStorage is not configured")

    queue_client = QueueClient.from_connection_string(
        conn_str=connection_string,
        queue_name=SYNC_QUEUE_NAME,
    )
    try:
        queue_client.create_queue()
    except ResourceExistsError:
        pass
    return queue_client


def get_job_entity(job_id: str) -> dict[str, Any] | None:
    try:
        return get_jobs_table_client().get_entity(
            partition_key=SYNC_JOBS_PARTITION_KEY,
            row_key=job_id,
        )
    except Exception:
        return None


def merge_job_entity(job_id: str, updates: dict[str, Any]) -> None:
    table_client = get_jobs_table_client()
    entity = {
        "PartitionKey": SYNC_JOBS_PARTITION_KEY,
        "RowKey": job_id,
        **updates,
    }
    table_client.upsert_entity(mode=UpdateMode.MERGE, entity=entity)


def get_schedule_entity() -> dict[str, Any] | None:
    try:
        return get_config_table_client().get_entity(
            partition_key=SYNC_CONFIG_PARTITION_KEY,
            row_key=SYNC_SCHEDULE_ROW_KEY,
        )
    except Exception:
        return None


def merge_schedule_entity(updates: dict[str, Any]) -> None:
    entity = {
        "PartitionKey": SYNC_CONFIG_PARTITION_KEY,
        "RowKey": SYNC_SCHEDULE_ROW_KEY,
        **updates,
    }
    get_config_table_client().upsert_entity(mode=UpdateMode.MERGE, entity=entity)


def default_schedule_payload() -> dict[str, Any]:
    return {
        "configured": False,
        "enabled": False,
        "preset": SCHEDULE_PRESET_DAILY,
        "timezone": "UTC",
        "weeklyDay": "monday",
        "dailyTime": "09:00",
        "nextRunAtUtc": None,
        "lastEvaluatedAt": None,
        "lastScheduledJobId": None,
        "lastScheduledRunAt": None,
        "lastCompletionAt": None,
        "lastRunStatus": "",
        "lastRunMessage": "",
    }


def parse_schedule_time(value: Any) -> tuple[int, int]:
    raw_value = str(value or "").strip()
    if not raw_value:
        raise ValueError("dailyTime is required")

    try:
        parsed_time = time.fromisoformat(raw_value)
    except ValueError as exc:
        raise ValueError("dailyTime must be in HH:MM format") from exc

    if parsed_time.second or parsed_time.microsecond:
        raise ValueError("dailyTime must be in HH:MM format")

    return parsed_time.hour, parsed_time.minute


def normalize_schedule_timezone(value: Any) -> str:
    timezone_name = str(value or "").strip()
    if not timezone_name:
        raise ValueError("timezone is required")

    try:
        ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError as exc:
        raise ValueError(f"Unsupported timezone: {timezone_name}") from exc

    return timezone_name


def normalize_weekly_day(value: Any) -> str:
    weekly_day = str(value or "").strip().lower()
    if weekly_day not in WEEKDAY_NAMES:
        raise ValueError(f"weeklyDay must be one of: {', '.join(WEEKDAY_NAMES)}")
    return weekly_day


def normalize_local_schedule_candidate(candidate: datetime) -> datetime:
    return candidate.astimezone(timezone.utc).astimezone(candidate.tzinfo)


def compute_next_run_at_utc(schedule: dict[str, Any], reference_time: datetime | None = None) -> str:
    preset = str(schedule.get("preset") or "").strip()
    if preset not in VALID_SCHEDULE_PRESETS:
        raise ValueError(f"preset must be one of: {', '.join(sorted(VALID_SCHEDULE_PRESETS))}")

    timezone_name = normalize_schedule_timezone(schedule.get("timezone"))
    zone = ZoneInfo(timezone_name)
    now_utc = reference_time or utc_now()
    local_now = now_utc.astimezone(zone)

    if preset == SCHEDULE_PRESET_EVERY_15_MINUTES:
        current = local_now.replace(second=0, microsecond=0)
        next_minute = ((current.minute // 15) + 1) * 15
        if next_minute >= 60:
            candidate = (current.replace(minute=0) + timedelta(hours=1)).replace(second=0, microsecond=0)
        else:
            candidate = current.replace(minute=next_minute, second=0, microsecond=0)
    elif preset == SCHEDULE_PRESET_HOURLY:
        candidate = (local_now.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1))
    elif preset == SCHEDULE_PRESET_DAILY:
        hour, minute = parse_schedule_time(schedule.get("dailyTime"))
        candidate = local_now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if candidate <= local_now:
            candidate += timedelta(days=1)
        candidate = normalize_local_schedule_candidate(candidate)
    else:
        hour, minute = parse_schedule_time(schedule.get("dailyTime"))
        target_weekday = WEEKDAY_NAMES.index(normalize_weekly_day(schedule.get("weeklyDay")))
        days_ahead = (target_weekday - local_now.weekday()) % 7
        candidate = (local_now + timedelta(days=days_ahead)).replace(hour=hour, minute=minute, second=0, microsecond=0)
        if candidate <= local_now:
            candidate += timedelta(days=7)
        candidate = normalize_local_schedule_candidate(candidate)

    return candidate.astimezone(timezone.utc).isoformat()


def build_schedule_entity(payload: dict[str, Any], existing: dict[str, Any] | None = None) -> dict[str, Any]:
    existing = existing or {}
    enabled = parse_bool(payload.get("enabled"), False)
    preset = str(payload.get("preset") or "").strip()
    timezone_name = normalize_schedule_timezone(payload.get("timezone"))

    if preset not in VALID_SCHEDULE_PRESETS:
        raise ValueError(f"preset must be one of: {', '.join(sorted(VALID_SCHEDULE_PRESETS))}")

    normalized: dict[str, Any] = {
        "configured": True,
        "enabled": enabled,
        "preset": preset,
        "timezone": timezone_name,
        "weeklyDay": "",
        "dailyTime": "",
        "nextRunAtUtc": None,
        "lastEvaluatedAt": existing.get("lastEvaluatedAt"),
        "lastScheduledJobId": existing.get("lastScheduledJobId"),
        "lastScheduledRunAt": existing.get("lastScheduledRunAt"),
        "lastCompletionAt": existing.get("lastCompletionAt"),
        "lastRunStatus": existing.get("lastRunStatus", ""),
        "lastRunMessage": existing.get("lastRunMessage", ""),
        "updatedAt": utc_now_iso(),
    }

    if preset in {SCHEDULE_PRESET_DAILY, SCHEDULE_PRESET_WEEKLY}:
        hour, minute = parse_schedule_time(payload.get("dailyTime"))
        normalized["dailyTime"] = f"{hour:02d}:{minute:02d}"

    if preset == SCHEDULE_PRESET_WEEKLY:
        normalized["weeklyDay"] = normalize_weekly_day(payload.get("weeklyDay"))

    if enabled:
        normalized["nextRunAtUtc"] = compute_next_run_at_utc(normalized)

    return normalized


def list_active_sync_jobs() -> list[dict[str, Any]]:
    try:
        entities = get_jobs_table_client().query_entities(
            query_filter=f"PartitionKey eq '{SYNC_JOBS_PARTITION_KEY}'"
        )
    except Exception:
        logging.exception("Failed to query active sync jobs")
        return []

    return [
        entity
        for entity in entities
        if str(entity.get("status") or "").lower() in {"queued", "running"}
    ]


def active_sync_job_summary() -> dict[str, Any] | None:
    active_jobs = sorted(
        list_active_sync_jobs(),
        key=lambda entity: str(entity.get("createdAt") or ""),
    )
    if not active_jobs:
        return None
    return parse_job_entity(active_jobs[0])


def schedule_job_summary(job_id: str | None) -> dict[str, Any] | None:
    if not job_id:
        return None
    entity = get_job_entity(job_id)
    if not entity:
        return None
    parsed = parse_job_entity(entity)
    return {
        "jobId": parsed["jobId"],
        "status": parsed["status"],
        "currentStage": parsed["currentStage"],
        "triggerSource": parsed.get("triggerSource", ""),
        "createdAt": parsed["createdAt"],
        "startedAt": parsed["startedAt"],
        "completedAt": parsed["completedAt"],
        "updatedAt": parsed["updatedAt"],
        "successful": parsed["successful"],
        "failed": parsed["failed"],
        "message": parsed["message"],
        "error": parsed["error"],
    }


def parse_schedule_entity(entity: dict[str, Any] | None) -> dict[str, Any]:
    base = dict(default_schedule_payload())
    if entity:
        base.update(
            {
                "configured": True,
                "enabled": parse_bool(entity.get("enabled"), False),
                "preset": entity.get("preset") or base["preset"],
                "timezone": entity.get("timezone") or base["timezone"],
                "weeklyDay": entity.get("weeklyDay") or base["weeklyDay"],
                "dailyTime": entity.get("dailyTime") or base["dailyTime"],
                "nextRunAtUtc": entity.get("nextRunAtUtc"),
                "lastEvaluatedAt": entity.get("lastEvaluatedAt"),
                "lastScheduledJobId": entity.get("lastScheduledJobId"),
                "lastScheduledRunAt": entity.get("lastScheduledRunAt"),
                "lastCompletionAt": entity.get("lastCompletionAt"),
                "lastRunStatus": entity.get("lastRunStatus", ""),
                "lastRunMessage": entity.get("lastRunMessage", ""),
            }
        )

    base["lastScheduledJob"] = schedule_job_summary(base.get("lastScheduledJobId"))
    base["activeSyncJob"] = active_sync_job_summary()
    return base


def enqueue_sync_job(request_body: dict[str, Any] | None = None, *, trigger_source: str = "manual") -> dict[str, Any]:
    if trigger_source not in SCHEDULE_TRIGGER_SOURCES:
        raise ValueError(f"Unsupported trigger source: {trigger_source}")

    body = request_body or {}
    job_id = uuid.uuid4().hex
    created_at = utc_now_iso()
    max_devices = parse_int(body.get("maxDevices", 0), 0)

    merge_job_entity(
        job_id,
        {
            "status": "queued",
            "createdAt": created_at,
            "updatedAt": created_at,
            "currentStage": "Queued",
            "requestedMaxDevices": max_devices,
            "total": 0,
            "processed": 0,
            "successful": 0,
            "failed": 0,
            "percentComplete": 0,
            "executionTimeMs": 0,
            "message": "Sync job queued",
            "error": "",
            "resultsJson": "[]",
            "resultsTruncated": False,
            "triggerSource": trigger_source,
        },
    )

    message_payload = json.dumps(
        {
            "jobId": job_id,
            "request": body,
            "triggerSource": trigger_source,
        }
    )
    encoded_message = base64.b64encode(message_payload.encode("utf-8")).decode("utf-8")
    get_queue_client().send_message(encoded_message)

    return {
        "success": True,
        "accepted": True,
        "jobId": job_id,
        "status": "queued",
        "currentStage": "Queued",
        "message": "Sync job queued",
        "statusUrl": f"/api/sync-status?jobId={job_id}",
        "total": 0,
        "processed": 0,
        "successful": 0,
        "failed": 0,
        "percentComplete": 0,
        "timestamp": created_at,
        "triggerSource": trigger_source,
        "targetModel": {
            "mailboxLookup": "serial",
            "displayNameSource": "vehicle-name",
            "mailboxCreation": "manual-by-admin",
            "visibilityChange": "first-sync",
        },
    }


def run_scheduler_tick() -> dict[str, Any]:
    now = utc_now()
    now_iso = now.isoformat()
    schedule_entity = get_schedule_entity()
    schedule = parse_schedule_entity(schedule_entity)

    if not schedule["configured"]:
        return {"status": "noop", "message": "No persisted sync schedule found."}

    if not schedule["enabled"]:
        merge_schedule_entity({"lastEvaluatedAt": now_iso})
        return {"status": "noop", "message": "Sync schedule is disabled."}

    next_run_at = schedule.get("nextRunAtUtc")
    if not next_run_at:
        next_run_at = compute_next_run_at_utc(schedule, reference_time=now)
        merge_schedule_entity(
            {
                "lastEvaluatedAt": now_iso,
                "nextRunAtUtc": next_run_at,
            }
        )
        return {"status": "noop", "message": "Schedule was missing nextRunAtUtc and has been repaired.", "nextRunAtUtc": next_run_at}

    try:
        next_run_at_dt = datetime.fromisoformat(str(next_run_at))
    except ValueError as exc:
        raise RuntimeError(f"Invalid persisted nextRunAtUtc value: {next_run_at}") from exc

    if next_run_at_dt > now:
        merge_schedule_entity({"lastEvaluatedAt": now_iso})
        return {"status": "noop", "message": "Next sync run is not due yet.", "nextRunAtUtc": next_run_at}

    active_job = active_sync_job_summary()
    next_run_after_now = compute_next_run_at_utc(schedule, reference_time=now)
    if active_job:
        message = f"Skipped scheduled sync because job {active_job['jobId']} is already {active_job['status']}."
        merge_schedule_entity(
            {
                "lastEvaluatedAt": now_iso,
                "nextRunAtUtc": next_run_after_now,
                "lastRunStatus": "skipped",
                "lastRunMessage": message,
            }
        )
        return {
            "status": "skipped",
            "message": message,
            "activeJobId": active_job["jobId"],
            "nextRunAtUtc": next_run_after_now,
        }

    queued_job = enqueue_sync_job({}, trigger_source="scheduled")
    merge_schedule_entity(
        {
            "lastEvaluatedAt": now_iso,
            "lastScheduledJobId": queued_job["jobId"],
            "lastScheduledRunAt": now_iso,
            "nextRunAtUtc": next_run_after_now,
            "lastRunStatus": "queued",
            "lastRunMessage": queued_job["message"],
        }
    )
    return {
        "status": "queued",
        "message": queued_job["message"],
        "jobId": queued_job["jobId"],
        "nextRunAtUtc": next_run_after_now,
    }


def serialize_results(results: list[dict[str, Any]]) -> tuple[str, bool]:
    payload = json.dumps(results)
    if len(payload) <= MAX_RESULT_STORAGE_CHARS:
        return payload, False

    truncated_payload = json.dumps(
        {
            "truncated": True,
            "totalResults": len(results),
            "keptResults": results[:100],
        }
    )
    return truncated_payload, True


def percent_complete(processed: int, total: int) -> int:
    if total <= 0:
        return 0
    return max(0, min(100, round((processed / total) * 100)))


def update_job_progress(
    job_id: str,
    *,
    status: str = "running",
    current_stage: str,
    message: str,
    total: int | None = None,
    processed: int | None = None,
    successful: int | None = None,
    failed: int | None = None,
) -> None:
    entity = get_job_entity(job_id) or {}

    total_value = int(total if total is not None else entity.get("total", 0) or 0)
    processed_value = int(processed if processed is not None else entity.get("processed", 0) or 0)
    successful_value = int(successful if successful is not None else entity.get("successful", 0) or 0)
    failed_value = int(failed if failed is not None else entity.get("failed", 0) or 0)

    merge_job_entity(
        job_id,
        {
            "status": status,
            "updatedAt": utc_now_iso(),
            "currentStage": current_stage,
            "message": message,
            "total": total_value,
            "processed": processed_value,
            "successful": successful_value,
            "failed": failed_value,
            "percentComplete": percent_complete(processed_value, total_value),
        },
    )


def parse_job_entity(entity: dict[str, Any]) -> dict[str, Any]:
    results: Any = []
    results_json = entity.get("resultsJson", "[]")
    try:
        results = json.loads(results_json) if results_json else []
    except json.JSONDecodeError:
        results = []

    return {
        "jobId": entity["RowKey"],
        "status": entity.get("status", "unknown"),
        "triggerSource": entity.get("triggerSource", "manual"),
        "createdAt": entity.get("createdAt"),
        "updatedAt": entity.get("updatedAt"),
        "startedAt": entity.get("startedAt"),
        "completedAt": entity.get("completedAt"),
        "currentStage": entity.get("currentStage", ""),
        "requestedMaxDevices": entity.get("requestedMaxDevices", 0),
        "total": entity.get("total", 0),
        "processed": entity.get("processed", 0),
        "successful": entity.get("successful", 0),
        "failed": entity.get("failed", 0),
        "percentComplete": entity.get("percentComplete", 0),
        "executionTimeMs": entity.get("executionTimeMs", 0),
        "message": entity.get("message", ""),
        "error": entity.get("error", ""),
        "results": results,
        "resultsTruncated": bool(entity.get("resultsTruncated", False)),
        "targetModel": {
            "mailboxLookup": "serial",
            "displayNameSource": "vehicle-name",
            "mailboxCreation": "manual-by-admin",
            "visibilityChange": "first-sync",
        },
    }


def mygeotab_credentials(body: dict[str, Any] | None = None) -> tuple[str, str, str, str]:
    body = body or {}

    return (
        str(body.get("myGeotabDatabase") or os.getenv("MYGEOTAB_DATABASE", "")).strip(),
        str(body.get("myGeotabUsername") or os.getenv("MYGEOTAB_USERNAME", "")).strip(),
        str(body.get("myGeotabPassword") or os.getenv("MYGEOTAB_PASSWORD", "")),
        str(body.get("myGeotabServer") or os.getenv("MYGEOTAB_SERVER", "my.geotab.com")).strip()
        or "my.geotab.com",
    )


def parse_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def parse_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def powershell_bool(value: bool) -> str:
    return "1" if value else "0"


def normalize_custom_properties(device: dict[str, Any], property_names: dict[str, str]) -> dict[str, Any]:
    normalized = dict(DEFAULT_PROPERTY_VALUES)

    for custom_property in device.get("customProperties", []) or []:
        property_id = custom_property.get("property", {}).get("id")
        property_name = property_names.get(property_id)
        value = custom_property.get("value")
        if not property_name:
            continue
        normalized_key = PROPERTY_NAME_MAP.get(property_name)
        if not normalized_key:
            continue

        if normalized_key in {"bookable", "recurring", "conflicts"}:
            normalized[normalized_key] = parse_bool(value, normalized[normalized_key])
        elif normalized_key in {"windowDays", "maxDurationHours"}:
            normalized[normalized_key] = parse_int(value, normalized[normalized_key])
        else:
            normalized[normalized_key] = value or normalized[normalized_key]

    return normalized


def to_mygeotab_string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def get_mygeotab_api(database: str, username: str, password: str, server: str) -> API:
    api = API(username=username, password=password, database=database, server=server)
    api.authenticate()
    return api


def fetch_device_for_update(api: API, device_identifier: str) -> dict[str, Any]:
    for search in (
        {"id": device_identifier},
        {"serialNumber": device_identifier},
        {"name": device_identifier},
    ):
        devices = api.get("Device", search=search) or []
        if devices:
            return devices[0]
    raise RuntimeError(f"Device not found by id/serial/name: {device_identifier}")


def build_update_property_lookup(api: API) -> dict[str, dict[str, str]]:
    properties = api.get("Property") or []
    lookup: dict[str, dict[str, str]] = {}

    for key, property_name in UPDATE_PROPERTY_NAME_MAP.items():
        match = next((prop for prop in properties if prop.get("name") == property_name), None)
        if not match:
            continue

        lookup[key] = {
            "id": match["id"],
            "name": property_name,
            "propertySetId": ((match.get("propertySet") or {}).get("id") or ""),
        }

    return lookup


def build_device_custom_property_updates(
    device: dict[str, Any],
    requested_properties: dict[str, Any],
    property_lookup: dict[str, dict[str, str]],
) -> tuple[list[dict[str, Any]], list[str]]:
    existing_custom_properties = device.get("customProperties", []) or []
    existing_by_property_id: dict[str, dict[str, Any]] = {}

    for item in existing_custom_properties:
        property_id = ((item.get("property") or {}).get("id") or "")
        if property_id:
            existing_by_property_id[property_id] = item

    updates: list[dict[str, Any]] = []
    missing_keys: list[str] = []

    for key, raw_value in requested_properties.items():
        property_info = property_lookup.get(key)
        if not property_info:
            missing_keys.append(key)
            continue

        existing_item = existing_by_property_id.get(property_info["id"], {})
        update_item: dict[str, Any] = {}

        if existing_item.get("id"):
            update_item["id"] = existing_item["id"]
        if existing_item.get("version"):
            update_item["version"] = existing_item["version"]

        property_ref: dict[str, Any] = {"id": property_info["id"]}
        if property_info.get("propertySetId"):
            property_ref["propertySet"] = {"id": property_info["propertySetId"]}

        update_item["property"] = property_ref
        update_item["value"] = to_mygeotab_string(raw_value)
        updates.append(update_item)

    return updates, missing_keys


def update_mygeotab_device_properties(device_identifier: str, properties: dict[str, Any]) -> dict[str, Any]:
    database, username, password, server = mygeotab_credentials()
    missing_credentials = [
        name
        for name, value in (
            ("database", database),
            ("username", username),
            ("password", password),
            ("server", server),
        )
        if not value
    ]
    if missing_credentials:
        raise RuntimeError(f"Missing MyGeotab configuration: {', '.join(missing_credentials)}")

    api = get_mygeotab_api(database, username, password, server)
    device = fetch_device_for_update(api, device_identifier)
    property_lookup = build_update_property_lookup(api)
    property_updates, missing_keys = build_device_custom_property_updates(device, properties, property_lookup)

    if not property_updates:
        raise RuntimeError("No valid ExchangeLink property definitions were found for the requested update")

    api.set("Device", {"id": device["id"], "customProperties": property_updates})

    return {
        "deviceId": device["id"],
        "deviceName": device.get("name", ""),
        "deviceIdentifier": device_identifier,
        "updatedPropertyCount": len(property_updates),
        "updatedProperties": sorted(
            property_lookup[key]["name"]
            for key in properties.keys()
            if key in property_lookup
        ),
        "missingPropertyDefinitions": sorted(missing_keys),
        "database": database,
    }


def fetch_mygeotab_devices(database: str, username: str, password: str, server: str, max_devices: int) -> list[dict[str, Any]]:
    api = API(username=username, password=password, database=database, server=server)
    api.authenticate()

    devices = api.get("Device")
    properties = api.get("Property")
    property_names = {item.get("id"): item.get("name") for item in properties if item.get("id")}

    normalized_devices: list[dict[str, Any]] = []
    for device in devices:
        serial = device.get("serialNumber")
        if not serial:
            continue

        property_state = normalize_custom_properties(device, property_names)
        normalized_devices.append(
            {
                "id": device.get("id"),
                "name": device.get("name") or serial,
                "serial": serial.strip(),
                "vin": device.get("vehicleIdentificationNumber") or "",
                "licensePlate": device.get("licensePlate") or "",
                "timeZone": device.get("timeZoneId") or os.getenv("DEFAULT_TIMEZONE", "AUS Eastern Standard Time"),
                **property_state,
            }
        )

    if max_devices > 0:
        return normalized_devices[:max_devices]
    return normalized_devices


def exchange_certificate_material() -> tuple[str, str]:
    return os.getenv("EXCHANGE_CERTIFICATE", ""), os.getenv("EXCHANGE_CERTIFICATE_PASSWORD", "")


def exchange_sync_settings() -> dict[str, Any]:
    pwsh_path = shutil.which("pwsh")
    if not pwsh_path:
        raise RuntimeError("pwsh is not available in the backend runtime")

    if not EXCHANGE_SYNC_SCRIPT.exists():
        raise RuntimeError("exchange_sync.ps1 is missing")

    equipment_domain = os.getenv("EQUIPMENT_DOMAIN", "").strip()
    exchange_app_id = os.getenv("EXCHANGE_CLIENT_ID", "").strip()
    exchange_org = os.getenv("EXCHANGE_ORGANIZATION") or equipment_domain

    if not equipment_domain:
        raise RuntimeError("EQUIPMENT_DOMAIN is not configured")
    if not exchange_app_id:
        raise RuntimeError("EXCHANGE_CLIENT_ID is not configured")

    cert_b64, cert_password = exchange_certificate_material()
    if not cert_b64:
        raise RuntimeError("Exchange certificate secret could not be loaded")

    try:
        cert_bytes = base64.b64decode(cert_b64, validate=True)
    except Exception:
        cert_bytes = cert_b64.encode("utf-8")

    return {
        "pwshPath": pwsh_path,
        "equipmentDomain": equipment_domain,
        "exchangeAppId": exchange_app_id,
        "exchangeOrg": exchange_org,
        "certBytes": cert_bytes,
        "certPassword": cert_password,
    }


def build_exchange_sync_payload(device: dict[str, Any], settings: dict[str, Any]) -> dict[str, Any]:
    alias = device["serial"].strip().lower()
    primary_smtp_address = f"{alias}@{settings['equipmentDomain']}"

    return {
        "deviceId": device["id"],
        "serial": device["serial"],
        "vehicleName": device["name"],
        "bookable": powershell_bool(parse_bool(device.get("bookable"))),
        "primarySmtpAddress": primary_smtp_address,
        "alias": alias,
        "displayName": device["name"],
        "timeZone": device["timeZone"] or os.getenv("DEFAULT_TIMEZONE", "AUS Eastern Standard Time"),
        "language": str(device.get("language") or "en-AU"),
        "allowConflicts": powershell_bool(parse_bool(device.get("conflicts"))),
        "bookingWindowInDays": parse_int(device.get("windowDays"), 90),
        "maximumDurationInMinutes": parse_int(device.get("maxDurationHours"), 24) * 60,
        "allowRecurringMeetings": powershell_bool(parse_bool(device.get("recurring"), False)),
        "makeVisible": powershell_bool(bool_setting("MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC", True)),
        "fleetManagers": str(device.get("fleetManagers") or ""),
        "approvers": str(device.get("approvers") or ""),
        "vin": str(device.get("vin") or ""),
        "licensePlate": str(device.get("licensePlate") or ""),
    }


def invoke_exchange_sync_batch(
    devices: list[dict[str, Any]],
    item_progress_callback: Any | None = None,
) -> list[dict[str, Any]]:
    if not devices:
        return []

    settings = exchange_sync_settings()
    payload = [build_exchange_sync_payload(device, settings) for device in devices]

    with tempfile.NamedTemporaryFile(suffix=".pfx", delete=False) as temp_cert:
        temp_cert.write(settings["certBytes"])
        temp_cert_path = temp_cert.name

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8", delete=False) as temp_input:
        json.dump(payload, temp_input)
        temp_input_path = temp_input.name

    try:
        command = [
            settings["pwshPath"],
            "-NoProfile",
            "-File",
            str(EXCHANGE_SYNC_SCRIPT),
            "-InputJsonPath",
            temp_input_path,
            "-Organization",
            settings["exchangeOrg"],
            "-AppId",
            settings["exchangeAppId"],
            "-CertificatePath",
            temp_cert_path,
            "-CertificatePassword",
            settings["certPassword"],
        ]

        completed = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        stdout_lines: list[str] = []
        if completed.stdout is not None:
            for raw_line in completed.stdout:
                line = raw_line.strip()
                if not line:
                    continue

                if line.startswith(PROGRESS_LINE_PREFIX):
                    progress_payload = line[len(PROGRESS_LINE_PREFIX) :]
                    if item_progress_callback:
                        try:
                            item_progress_callback(json.loads(progress_payload))
                        except json.JSONDecodeError:
                            stdout_lines.append(line)
                    continue

                stdout_lines.append(line)

        stderr = completed.stderr.read().strip() if completed.stderr is not None else ""
        return_code = completed.wait()
        stdout = "\n".join(stdout_lines).strip()
        if not stdout:
            raise RuntimeError(stderr or "Exchange sync script returned no output")

        try:
            results = json.loads(stdout.splitlines()[-1])
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Exchange sync script returned invalid JSON: {stdout}") from exc

        if not isinstance(results, list):
            raise RuntimeError("Exchange sync script returned an invalid result payload")

        result_map = {
            str(item.get("serial", "")).strip(): item
            for item in results
            if isinstance(item, dict)
        }
        batch_results: list[dict[str, Any]] = []

        for payload_item in payload:
            serial = payload_item["serial"]
            result = result_map.get(serial)
            if result is None:
                if return_code != 0:
                    raise RuntimeError(stderr or "Exchange sync failed")
                result = {
                    "success": False,
                    "message": "Exchange sync script returned no result for device",
                    "found": False,
                }

            batch_results.append(
                {
                    "deviceId": payload_item["deviceId"],
                    "serial": serial,
                    "vehicleName": payload_item["vehicleName"],
                    **result,
                }
            )

        return batch_results
    finally:
        try:
            os.remove(temp_cert_path)
        except FileNotFoundError:
            pass
        try:
            os.remove(temp_input_path)
        except FileNotFoundError:
            pass


def process_devices(
    devices: list[dict[str, Any]],
    progress_callback: Any | None = None,
) -> tuple[list[dict[str, Any]], int, int]:
    max_workers = max(1, int_setting("SYNC_MAX_WORKERS", 4))
    batch_size = max(1, int_setting("SYNC_BATCH_SIZE", 20))
    device_batches = chunked(devices, batch_size)
    total = len(devices)
    progress_lock = Lock()
    processed = 0
    successful = 0
    failed = 0
    batch_progress_serials: dict[int, set[str]] = {}

    def emit_progress_update(batch_key: int, item: dict[str, Any]) -> None:
        nonlocal processed, successful, failed
        serial = str(item.get("serial", "")).strip()
        with progress_lock:
            batch_progress_serials.setdefault(batch_key, set()).add(serial)
            processed += 1
            if item.get("success"):
                successful += 1
            else:
                failed += 1
            processed_value = min(processed, total)
            successful_value = successful
            failed_value = failed

        if progress_callback:
            progress_callback(
                processed=processed_value,
                successful=successful_value,
                failed=failed_value,
            )

    def reconcile_batch_results(batch_key: int, batch_results: list[dict[str, Any]]) -> None:
        nonlocal processed, successful, failed
        for result in batch_results:
            serial = str(result.get("serial", "")).strip()
            with progress_lock:
                seen_serials = batch_progress_serials.setdefault(batch_key, set())
                if serial in seen_serials:
                    continue
                seen_serials.add(serial)
                processed = min(processed + 1, total)
                successful += 1 if result.get("success") else 0
                failed += 0 if result.get("success") else 1
                processed_state = processed
                successful_state = successful
                failed_state = failed

            if progress_callback:
                progress_callback(
                    processed=processed_state,
                    successful=successful_state,
                    failed=failed_state,
                )

    def reconcile_batch_failure(batch_key: int, device_batch: list[dict[str, Any]]) -> None:
        missing_results = [
            {
                "success": False,
                "serial": device["serial"],
                "vehicleName": device["name"],
            }
            for device in device_batch
            if str(device["serial"]).strip() not in batch_progress_serials.setdefault(batch_key, set())
        ]
        reconcile_batch_results(batch_key, missing_results)

    if max_workers == 1 or len(device_batches) <= 1:
        results = []
        for device_batch in device_batches:
            batch_key = id(device_batch)
            try:
                batch_results = invoke_exchange_sync_batch(
                    device_batch,
                    item_progress_callback=lambda item, current_batch_key=batch_key: emit_progress_update(current_batch_key, item),
                )
                reconcile_batch_results(batch_key, batch_results)
                results.extend(batch_results)
            except Exception as exc:
                for device in device_batch:
                    results.append(
                        {
                            "success": False,
                            "serial": device["serial"],
                            "vehicleName": device["name"],
                            "message": str(exc),
                        }
                    )
                reconcile_batch_failure(batch_key, device_batch)
        return results, successful, failed

    results: list[dict[str, Any] | None] = [None] * len(devices)
    serial_to_index = {device["serial"]: index for index, device in enumerate(devices)}

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_map = {
            executor.submit(
                invoke_exchange_sync_batch,
                device_batch,
                lambda item, current_batch_key=id(device_batch): emit_progress_update(current_batch_key, item),
            ): device_batch
            for device_batch in device_batches
        }
        for future in as_completed(future_map):
            device_batch = future_map[future]
            batch_key = id(device_batch)
            try:
                batch_results = future.result()
                reconcile_batch_results(batch_key, batch_results)
                for result in batch_results:
                    index = serial_to_index.get(result["serial"])
                    if index is not None:
                        results[index] = result
            except Exception as exc:
                for device in device_batch:
                    index = serial_to_index[device["serial"]]
                    results[index] = {
                        "success": False,
                        "serial": device["serial"],
                        "vehicleName": device["name"],
                        "message": str(exc),
                    }
                reconcile_batch_failure(batch_key, device_batch)

    return [item for item in results if item is not None], successful, failed


def run_sync(body: dict[str, Any], job_id: str | None = None) -> dict[str, Any]:
    max_devices = parse_int(body.get("maxDevices", 0), 0)
    started_at = utc_now()

    database, username, password, server = mygeotab_credentials(body)
    if not all([database, username, password, server]):
        raise RuntimeError("MyGeotab credentials are not fully configured")

    logging.info("sync job started maxDevices=%s database=%s server=%s", max_devices, database, server)

    if job_id:
        update_job_progress(
            job_id,
            current_stage="Loading devices",
            message="Loading devices from MyGeotab",
            total=0,
            processed=0,
            successful=0,
            failed=0,
        )

    devices = fetch_mygeotab_devices(database, username, password, server, max_devices)
    total_devices = len(devices)

    if job_id:
        update_job_progress(
            job_id,
            current_stage="Syncing mailboxes",
            message="Syncing devices with Exchange Online",
            total=total_devices,
            processed=0,
            successful=0,
            failed=0,
        )

    def progress_callback(*, processed: int, successful: int, failed: int) -> None:
        if not job_id:
            return
        update_job_progress(
            job_id,
            current_stage="Syncing mailboxes",
            message=f"Syncing devices with Exchange Online ({processed}/{total_devices})",
            total=total_devices,
            processed=processed,
            successful=successful,
            failed=failed,
        )

    results, successful, failed = process_devices(devices, progress_callback if job_id else None)
    execution_time_ms = int((utc_now() - started_at).total_seconds() * 1000)
    overall_success = failed == 0

    return {
        "success": overall_success,
        "mode": "single-tenant",
        "message": "Sync completed" if overall_success else "Sync completed with failures",
        "currentStage": "Completed",
        "total": total_devices,
        "percentComplete": 100 if total_devices == 0 or successful + failed >= total_devices else percent_complete(successful + failed, total_devices),
        "processed": len(devices),
        "successful": successful,
        "failed": failed,
        "executionTimeMs": execution_time_ms,
        "results": results,
        "requestedMaxDevices": max_devices,
    }


def service_config_summary() -> dict[str, Any]:
    database_configured = bool(os.getenv("MYGEOTAB_DATABASE"))
    username_configured = bool(os.getenv("MYGEOTAB_USERNAME"))
    server_configured = bool(os.getenv("MYGEOTAB_SERVER"))
    schedule = parse_schedule_entity(get_schedule_entity())

    return {
        "deploymentMode": "single-tenant",
        "backend": "azure-container-apps",
        "equipmentDomain": os.getenv("EQUIPMENT_DOMAIN", ""),
        "defaultTimezone": os.getenv("DEFAULT_TIMEZONE", "AUS Eastern Standard Time"),
        "makeMailboxVisibleOnFirstSync": bool_setting("MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC", True),
        "syncMode": "async-job",
        "myGeotabDatabaseConfigured": database_configured,
        "myGeotabUsernameConfigured": username_configured,
        "myGeotabServerConfigured": server_configured,
        "exchangeTenantConfigured": bool(os.getenv("EXCHANGE_TENANT_ID")),
        "exchangeClientConfigured": bool(os.getenv("EXCHANGE_CLIENT_ID")),
        "pwshAvailable": bool(shutil.which("pwsh")),
        "schedulerMode": "container-app-job",
        "schedulerHeartbeatCron": os.getenv("SCHEDULER_HEARTBEAT_CRON", "*/5 * * * *"),
        "schedulerConfigured": schedule["configured"],
        "schedulerEnabled": schedule["enabled"],
        "schedulerNextRunAtUtc": schedule.get("nextRunAtUtc"),
    }


@app.route(route="health", methods=["GET", "OPTIONS"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return cors_preflight_response()

    return json_response(
        {
            "status": "healthy",
            "timestamp": utc_now_iso(),
            "service": "exchangelink",
            "config": service_config_summary(),
        }
    )


@app.route(route="update-device-properties", methods=["POST", "OPTIONS"], auth_level=func.AuthLevel.ANONYMOUS)
def update_device_properties(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return cors_preflight_response()

    body = parse_json(req)
    device_id = body.get("deviceId")
    properties = body.get("properties")

    if not device_id:
        return json_response(
            {
                "success": False,
                "error": "Missing required field: deviceId",
                "timestamp": utc_now_iso(),
            },
            status_code=400,
        )

    if not isinstance(properties, dict) or not properties:
        return json_response(
            {
                "success": False,
                "error": "Missing required field: properties",
                "timestamp": utc_now_iso(),
            },
            status_code=400,
        )

    logging.info(
        "update-device-properties called for deviceId=%s propertyCount=%s",
        device_id,
        len(properties),
    )

    try:
        result = update_mygeotab_device_properties(device_id, properties)
    except Exception as error:
        logging.exception("Failed to update MyGeotab device properties for deviceId=%s", device_id)
        return json_response(
            {
                "success": False,
                "timestamp": utc_now_iso(),
                "error": str(error),
                "deviceId": device_id,
                "propertyKeys": sorted(properties.keys()),
            },
            status_code=500,
        )

    return json_response(
        {
            "success": True,
            "timestamp": utc_now_iso(),
            "message": "Device properties updated",
            "deviceId": result["deviceId"],
            "deviceName": result["deviceName"],
            "propertyKeys": sorted(properties.keys()),
            "updatedPropertyCount": result["updatedPropertyCount"],
            "updatedProperties": result["updatedProperties"],
            "missingPropertyDefinitions": result["missingPropertyDefinitions"],
        }
    )


@app.route(route="sync-schedule", methods=["GET", "PUT", "OPTIONS"], auth_level=func.AuthLevel.ANONYMOUS)
def sync_schedule(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return cors_preflight_response()

    if req.method == "GET":
        try:
            schedule = parse_schedule_entity(get_schedule_entity())
        except Exception as error:
            logging.exception("Failed to load sync schedule")
            return json_response(
                {
                    "success": False,
                    "error": str(error),
                    "timestamp": utc_now_iso(),
                },
                status_code=500,
            )

        return json_response(
            {
                "success": True,
                "timestamp": utc_now_iso(),
                "schedule": schedule,
            }
        )

    body = parse_json(req)
    try:
        existing = get_schedule_entity()
        schedule_updates = build_schedule_entity(body, existing=existing)
    except ValueError as exc:
        return json_response(
            {
                "success": False,
                "error": str(exc),
                "timestamp": utc_now_iso(),
            },
            status_code=400,
        )

    try:
        merge_schedule_entity(schedule_updates)
        schedule = parse_schedule_entity(get_schedule_entity())
    except Exception as error:
        logging.exception("Failed to save sync schedule")
        return json_response(
            {
                "success": False,
                "error": str(error),
                "timestamp": utc_now_iso(),
            },
            status_code=500,
        )

    return json_response(
        {
            "success": True,
            "timestamp": utc_now_iso(),
            "message": "Sync schedule saved",
            "schedule": schedule,
        }
    )


@app.route(route="sync-to-exchange", methods=["POST", "OPTIONS"], auth_level=func.AuthLevel.ANONYMOUS)
def sync_to_exchange(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return cors_preflight_response()

    body = parse_json(req)
    max_devices = body.get("maxDevices", 0)

    try:
        max_devices = int(max_devices or 0)
    except (TypeError, ValueError):
        return json_response(
            {
                "success": False,
                "error": "maxDevices must be an integer",
                "timestamp": utc_now_iso(),
            },
            status_code=400,
        )

    return json_response(enqueue_sync_job(body, trigger_source="manual"), status_code=202)


@app.route(route="sync-status", methods=["GET", "OPTIONS"], auth_level=func.AuthLevel.ANONYMOUS)
def sync_status(req: func.HttpRequest) -> func.HttpResponse:
    if req.method == "OPTIONS":
        return cors_preflight_response()

    job_id = (req.params.get("jobId") or "").strip()
    if not job_id:
        return json_response(
            {
                "success": False,
                "error": "Missing required query parameter: jobId",
                "timestamp": utc_now_iso(),
            },
            status_code=400,
        )

    entity = get_job_entity(job_id)
    if not entity:
        return json_response(
            {
                "success": False,
                "error": "Sync job not found",
                "jobId": job_id,
                "timestamp": utc_now_iso(),
            },
            status_code=404,
        )

    payload = {
        "success": entity.get("status") == "completed" and not entity.get("failed", 0),
        "timestamp": utc_now_iso(),
        "mode": "single-tenant",
        **parse_job_entity(entity),
    }
    return json_response(payload)


@app.queue_trigger(arg_name="msg", queue_name=SYNC_QUEUE_NAME, connection="AzureWebJobsStorage")
def process_sync_job(msg: func.QueueMessage) -> None:
    try:
        payload = json.loads(msg.get_body().decode("utf-8"))
        job_id = payload["jobId"]
        request_body = payload.get("request", {})
        trigger_source = str(payload.get("triggerSource") or "manual").strip().lower()
    except Exception as exc:
        logging.exception("Invalid sync job message")
        raise RuntimeError("Invalid sync job payload") from exc

    if trigger_source not in SCHEDULE_TRIGGER_SOURCES:
        trigger_source = "manual"

    started_at = utc_now_iso()
    merge_job_entity(
        job_id,
        {
            "status": "running",
            "startedAt": started_at,
            "updatedAt": started_at,
            "currentStage": "Starting",
            "message": "Sync job starting",
            "error": "",
            "triggerSource": trigger_source,
        },
    )

    try:
        result = run_sync(request_body, job_id=job_id)
        completed_at = utc_now_iso()
        results_json, results_truncated = serialize_results(result["results"])
        merge_job_entity(
            job_id,
            {
                "status": "completed",
                "updatedAt": completed_at,
                "completedAt": completed_at,
                "currentStage": result.get("currentStage", "Completed"),
                "total": result.get("total", result["processed"]),
                "processed": result["processed"],
                "successful": result["successful"],
                "failed": result["failed"],
                "percentComplete": result.get("percentComplete", 100),
                "executionTimeMs": result["executionTimeMs"],
                "message": result["message"],
                "error": "",
                "resultsJson": results_json,
                "resultsTruncated": results_truncated,
                "triggerSource": trigger_source,
            },
        )
        if trigger_source == "scheduled":
            merge_schedule_entity(
                {
                    "lastCompletionAt": completed_at,
                    "lastRunStatus": "completed",
                    "lastRunMessage": result["message"],
                }
            )
    except Exception as exc:
        logging.exception("Sync job failed jobId=%s", job_id)
        completed_at = utc_now_iso()
        merge_job_entity(
            job_id,
            {
                "status": "failed",
                "updatedAt": completed_at,
                "completedAt": completed_at,
                "currentStage": "Failed",
                "message": "Sync job failed",
                "error": str(exc),
                "triggerSource": trigger_source,
            },
        )
        if trigger_source == "scheduled":
            merge_schedule_entity(
                {
                    "lastCompletionAt": completed_at,
                    "lastRunStatus": "failed",
                    "lastRunMessage": str(exc),
                }
            )
        raise
