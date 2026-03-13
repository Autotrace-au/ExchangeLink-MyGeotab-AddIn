import base64
import json
import logging
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

from mygeotab import API


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
BASE_DIR = Path(__file__).resolve().parent
EXCHANGE_SYNC_SCRIPT = BASE_DIR / "exchange_sync.ps1"

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


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def bool_setting(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


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

    started_at = datetime.now(timezone.utc)

    database, username, password, server = mygeotab_credentials(body)
    if not all([database, username, password, server]):
        return json_response(
            {
                "success": False,
                "error": "MyGeotab credentials are not fully configured",
                "timestamp": utc_now_iso(),
            },
            status_code=500,
        )

    logging.info("sync-to-exchange called maxDevices=%s database=%s server=%s", max_devices, database, server)

    try:
        devices = fetch_mygeotab_devices(database, username, password, server, max_devices)
    except Exception as exc:
        logging.exception("Failed to load devices from MyGeotab")
        return json_response(
            {
                "success": False,
                "error": f"Failed to load devices from MyGeotab: {exc}",
                "timestamp": utc_now_iso(),
            },
            status_code=500,
        )

    results: list[dict[str, Any]] = []
    successful = 0
    failed = 0

    for device in devices:
        try:
            result = invoke_exchange_sync(device)
            if result.get("success"):
                successful += 1
            else:
                failed += 1
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

    execution_time_ms = int((datetime.now(timezone.utc) - started_at).total_seconds() * 1000)
    overall_success = failed == 0

    return json_response(
        {
            "success": overall_success,
            "timestamp": utc_now_iso(),
            "mode": "single-tenant",
            "message": "Sync completed" if overall_success else "Sync completed with failures",
            "processed": len(devices),
            "successful": successful,
            "failed": failed,
            "executionTimeMs": execution_time_ms,
            "results": results,
            "requestedMaxDevices": max_devices,
            "targetModel": {
                "mailboxLookup": "serial",
                "displayNameSource": "vehicle-name",
                "mailboxCreation": "manual-by-admin",
                "visibilityChange": "first-sync",
            },
        },
        status_code=200 if overall_success else 207,
    )
