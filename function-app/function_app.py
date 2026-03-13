import base64
import json
import logging
import os
import shutil
import subprocess
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import azure.functions as func
from azure.data.tables import TableServiceClient, UpdateMode
from azure.core.exceptions import ResourceExistsError
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.queue import QueueClient
from mygeotab import API


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
BASE_DIR = Path(__file__).resolve().parent
EXCHANGE_SYNC_SCRIPT = BASE_DIR / "exchange_sync.ps1"
SYNC_JOBS_TABLE_NAME = "FleetBridgeSyncJobs"
SYNC_QUEUE_NAME = "fleetbridge-sync-jobs"
SYNC_JOBS_PARTITION_KEY = "syncjobs"
MAX_RESULT_STORAGE_CHARS = 800_000

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


def json_response(payload: dict[str, Any], status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
    )


def parse_json(req: func.HttpRequest) -> dict[str, Any]:
    try:
        body = req.get_json()
    except ValueError:
        body = {}
    return body if isinstance(body, dict) else {}


def get_secret_client() -> SecretClient | None:
    key_vault_url = os.getenv("KEY_VAULT_URL")
    if not key_vault_url:
        return None
    return SecretClient(vault_url=key_vault_url, credential=DefaultAzureCredential())


def get_secret_value(secret_name: str | None) -> str:
    if not secret_name:
        return ""
    client = get_secret_client()
    if not client:
        return ""
    return client.get_secret(secret_name).value


def get_table_client():
    connection_string = os.getenv("AzureWebJobsStorage", "")
    if not connection_string:
        raise RuntimeError("AzureWebJobsStorage is not configured")

    service_client = TableServiceClient.from_connection_string(connection_string)
    service_client.create_table_if_not_exists(SYNC_JOBS_TABLE_NAME)
    table_client = service_client.get_table_client(SYNC_JOBS_TABLE_NAME)
    return table_client


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
        return get_table_client().get_entity(
            partition_key=SYNC_JOBS_PARTITION_KEY,
            row_key=job_id,
        )
    except Exception:
        return None


def merge_job_entity(job_id: str, updates: dict[str, Any]) -> None:
    table_client = get_table_client()
    entity = {
        "PartitionKey": SYNC_JOBS_PARTITION_KEY,
        "RowKey": job_id,
        **updates,
    }
    table_client.upsert_entity(mode=UpdateMode.MERGE, entity=entity)


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
        "createdAt": entity.get("createdAt"),
        "updatedAt": entity.get("updatedAt"),
        "startedAt": entity.get("startedAt"),
        "completedAt": entity.get("completedAt"),
        "requestedMaxDevices": entity.get("requestedMaxDevices", 0),
        "processed": entity.get("processed", 0),
        "successful": entity.get("successful", 0),
        "failed": entity.get("failed", 0),
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


def mygeotab_credentials(body: dict[str, Any]) -> tuple[str, str, str, str]:
    database = body.get("database") or os.getenv("MYGEOTAB_DATABASE", "") or get_secret_value(os.getenv("MYGEOTAB_DATABASE_SECRET_NAME"))
    username = body.get("username") or os.getenv("MYGEOTAB_USERNAME", "") or get_secret_value(os.getenv("MYGEOTAB_USERNAME_SECRET_NAME"))
    server = body.get("server") or os.getenv("MYGEOTAB_SERVER", "") or get_secret_value(os.getenv("MYGEOTAB_SERVER_SECRET_NAME")) or "my.geotab.com"

    password = body.get("password", "")
    if password:
        return database, username, password, server

    password_secret_name = os.getenv("MYGEOTAB_PASSWORD_SECRET_NAME")
    password = get_secret_value(password_secret_name)
    return database, username, password, server


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
    normalized = {
        "bookable": False,
        "recurring": True,
        "approvers": "",
        "fleetManagers": "",
        "conflicts": False,
        "windowDays": 90,
        "maxDurationHours": 24,
        "language": "en-AU",
    }

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
    secret_name = os.getenv("EXCHANGE_CERTIFICATE_SECRET_NAME")
    cert_value = get_secret_value(secret_name)
    password = get_secret_value(os.getenv("EXCHANGE_CERTIFICATE_PASSWORD_SECRET_NAME"))
    return cert_value, password


def invoke_exchange_sync(device: dict[str, Any]) -> dict[str, Any]:
    pwsh_path = shutil.which("pwsh")
    if not pwsh_path:
        raise RuntimeError("pwsh is not available in the Function App runtime")

    if not EXCHANGE_SYNC_SCRIPT.exists():
        raise RuntimeError("exchange_sync.ps1 is missing")

    equipment_domain = (os.getenv("EQUIPMENT_DOMAIN", "") or get_secret_value(os.getenv("EQUIPMENT_DOMAIN_SECRET_NAME"))).strip()
    exchange_app_id = os.getenv("EXCHANGE_CLIENT_ID", "").strip()
    exchange_org = os.getenv("EXCHANGE_ORGANIZATION") or equipment_domain

    if not equipment_domain:
        raise RuntimeError("EQUIPMENT_DOMAIN is not configured")
    if not exchange_app_id:
        raise RuntimeError("EXCHANGE_CLIENT_ID is not configured")

    cert_b64, cert_password = exchange_certificate_material()
    if not cert_b64:
        raise RuntimeError("Exchange certificate secret could not be loaded")

    alias = device["serial"].strip().lower()
    primary_smtp_address = f"{alias}@{equipment_domain}"

    try:
        cert_bytes = base64.b64decode(cert_b64, validate=True)
    except Exception:
        cert_bytes = cert_b64.encode("utf-8")

    with tempfile.NamedTemporaryFile(suffix=".pfx", delete=False) as temp_cert:
        temp_cert.write(cert_bytes)
        temp_cert_path = temp_cert.name

    try:
        command = [
            pwsh_path,
            "-NoProfile",
            "-File",
            str(EXCHANGE_SYNC_SCRIPT),
            "-PrimarySmtpAddress",
            primary_smtp_address,
            "-Alias",
            alias,
            "-DisplayName",
            device["name"],
            "-Organization",
            exchange_org,
            "-AppId",
            exchange_app_id,
            "-CertificatePath",
            temp_cert_path,
            "-CertificatePassword",
            cert_password,
            "-TimeZone",
            device["timeZone"] or os.getenv("DEFAULT_TIMEZONE", "AUS Eastern Standard Time"),
            "-Language",
            str(device.get("language") or "en-AU"),
            "-AllowConflicts",
            powershell_bool(parse_bool(device.get("conflicts"))),
            "-BookingWindowInDays",
            str(parse_int(device.get("windowDays"), 90)),
            "-MaximumDurationInMinutes",
            str(parse_int(device.get("maxDurationHours"), 24) * 60),
            "-AllowRecurringMeetings",
            powershell_bool(parse_bool(device.get("recurring"), True)),
            "-MakeVisible",
            powershell_bool(bool_setting("MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC", True)),
            "-FleetManagers",
            str(device.get("fleetManagers") or ""),
            "-Approvers",
            str(device.get("approvers") or ""),
            "-VIN",
            str(device.get("vin") or ""),
            "-LicensePlate",
            str(device.get("licensePlate") or ""),
        ]

        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )

        stdout = completed.stdout.strip()
        if not stdout:
            raise RuntimeError(completed.stderr.strip() or "Exchange sync script returned no output")

        try:
            result = json.loads(stdout.splitlines()[-1])
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Exchange sync script returned invalid JSON: {stdout}") from exc

        if completed.returncode != 0 and result.get("success") is not True:
            raise RuntimeError(result.get("message") or completed.stderr.strip() or "Exchange sync failed")

        return {
            "deviceId": device["id"],
            "serial": device["serial"],
            "vehicleName": device["name"],
            **result,
        }
    finally:
        try:
            os.remove(temp_cert_path)
        except FileNotFoundError:
            pass


def process_devices(devices: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int, int]:
    max_workers = max(1, int_setting("SYNC_MAX_WORKERS", 4))

    if max_workers == 1 or len(devices) <= 1:
        results = []
        successful = 0
        failed = 0
        for device in devices:
            try:
                result = invoke_exchange_sync(device)
                successful += 1 if result.get("success") else 0
                failed += 0 if result.get("success") else 1
                results.append(result)
            except Exception as exc:
                failed += 1
                results.append(
                    {
                        "success": False,
                        "serial": device["serial"],
                        "vehicleName": device["name"],
                        "message": str(exc),
                    }
                )
        return results, successful, failed

    results: list[dict[str, Any] | None] = [None] * len(devices)
    successful = 0
    failed = 0

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_map = {
            executor.submit(invoke_exchange_sync, device): (index, device)
            for index, device in enumerate(devices)
        }
        for future in as_completed(future_map):
            index, device = future_map[future]
            try:
                result = future.result()
                successful += 1 if result.get("success") else 0
                failed += 0 if result.get("success") else 1
                results[index] = result
            except Exception as exc:
                failed += 1
                results[index] = {
                    "success": False,
                    "serial": device["serial"],
                    "vehicleName": device["name"],
                    "message": str(exc),
                }

    return [item for item in results if item is not None], successful, failed


def run_sync(body: dict[str, Any]) -> dict[str, Any]:
    max_devices = parse_int(body.get("maxDevices", 0), 0)
    started_at = utc_now()

    database, username, password, server = mygeotab_credentials(body)
    if not all([database, username, password, server]):
        raise RuntimeError("MyGeotab credentials are not fully configured")

    logging.info("sync job started maxDevices=%s database=%s server=%s", max_devices, database, server)

    devices = fetch_mygeotab_devices(database, username, password, server, max_devices)
    results, successful, failed = process_devices(devices)
    execution_time_ms = int((utc_now() - started_at).total_seconds() * 1000)
    overall_success = failed == 0

    return {
        "success": overall_success,
        "mode": "single-tenant",
        "message": "Sync completed" if overall_success else "Sync completed with failures",
        "processed": len(devices),
        "successful": successful,
        "failed": failed,
        "executionTimeMs": execution_time_ms,
        "results": results,
        "requestedMaxDevices": max_devices,
    }


def service_config_summary() -> dict[str, Any]:
    database_configured = bool(os.getenv("MYGEOTAB_DATABASE")) or bool(os.getenv("MYGEOTAB_DATABASE_SECRET_NAME"))
    username_configured = bool(os.getenv("MYGEOTAB_USERNAME")) or bool(os.getenv("MYGEOTAB_USERNAME_SECRET_NAME"))
    server_configured = bool(os.getenv("MYGEOTAB_SERVER")) or bool(os.getenv("MYGEOTAB_SERVER_SECRET_NAME"))

    return {
        "deploymentMode": "single-tenant",
        "backend": "azure-function-app",
        "equipmentDomain": os.getenv("EQUIPMENT_DOMAIN", ""),
        "defaultTimezone": os.getenv("DEFAULT_TIMEZONE", "AUS Eastern Standard Time"),
        "makeMailboxVisibleOnFirstSync": bool_setting("MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC", True),
        "syncMode": "async-job",
        "keyVaultConfigured": bool(os.getenv("KEY_VAULT_URL")),
        "myGeotabDatabaseConfigured": database_configured,
        "myGeotabUsernameConfigured": username_configured,
        "myGeotabServerConfigured": server_configured,
        "exchangeTenantConfigured": bool(os.getenv("EXCHANGE_TENANT_ID")),
        "exchangeClientConfigured": bool(os.getenv("EXCHANGE_CLIENT_ID")),
        "pwshAvailable": bool(shutil.which("pwsh")),
    }


@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return json_response(
        {
            "status": "healthy",
            "timestamp": utc_now_iso(),
            "service": "fleetbridge",
            "config": service_config_summary(),
        }
    )


@app.route(route="update-device-properties", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def update_device_properties(req: func.HttpRequest) -> func.HttpResponse:
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

    return json_response(
        {
            "success": True,
            "timestamp": utc_now_iso(),
            "mode": "scaffold",
            "message": "Function App endpoint scaffolded. MyGeotab property update logic is not implemented yet.",
            "deviceId": device_id,
            "propertyKeys": sorted(properties.keys()),
        }
    )


@app.route(route="sync-to-exchange", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def sync_to_exchange(req: func.HttpRequest) -> func.HttpResponse:
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

    job_id = uuid.uuid4().hex
    created_at = utc_now_iso()

    merge_job_entity(
        job_id,
        {
            "status": "queued",
            "createdAt": created_at,
            "updatedAt": created_at,
            "requestedMaxDevices": max_devices,
            "processed": 0,
            "successful": 0,
            "failed": 0,
            "executionTimeMs": 0,
            "message": "Sync job queued",
            "error": "",
            "resultsJson": "[]",
            "resultsTruncated": False,
        },
    )

    message_payload = json.dumps(
        {
            "jobId": job_id,
            "request": body,
        }
    )
    encoded_message = base64.b64encode(message_payload.encode("utf-8")).decode("utf-8")
    get_queue_client().send_message(encoded_message)

    return json_response(
        {
            "success": True,
            "accepted": True,
            "jobId": job_id,
            "status": "queued",
            "message": "Sync job queued",
            "statusUrl": f"/api/sync-status?jobId={job_id}",
            "timestamp": created_at,
            "targetModel": {
                "mailboxLookup": "serial",
                "displayNameSource": "vehicle-name",
                "mailboxCreation": "manual-by-admin",
                "visibilityChange": "first-sync",
            },
        },
        status_code=202,
    )


@app.route(route="sync-status", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def sync_status(req: func.HttpRequest) -> func.HttpResponse:
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
    except Exception as exc:
        logging.exception("Invalid sync job message")
        raise RuntimeError("Invalid sync job payload") from exc

    started_at = utc_now_iso()
    merge_job_entity(
        job_id,
        {
            "status": "running",
            "startedAt": started_at,
            "updatedAt": started_at,
            "message": "Sync job running",
            "error": "",
        },
    )

    try:
        result = run_sync(request_body)
        completed_at = utc_now_iso()
        results_json, results_truncated = serialize_results(result["results"])
        merge_job_entity(
            job_id,
            {
                "status": "completed",
                "updatedAt": completed_at,
                "completedAt": completed_at,
                "processed": result["processed"],
                "successful": result["successful"],
                "failed": result["failed"],
                "executionTimeMs": result["executionTimeMs"],
                "message": result["message"],
                "error": "",
                "resultsJson": results_json,
                "resultsTruncated": results_truncated,
            },
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
                "message": "Sync job failed",
                "error": str(exc),
            },
        )
        raise
