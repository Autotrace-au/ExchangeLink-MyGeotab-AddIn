import pathlib
import sys
import types
import unittest
from datetime import datetime, timezone
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def install_test_stubs():
    azure_module = types.ModuleType("azure")
    azure_functions = types.ModuleType("azure.functions")
    azure_data = types.ModuleType("azure.data")
    azure_data_tables = types.ModuleType("azure.data.tables")
    azure_core = types.ModuleType("azure.core")
    azure_core_exceptions = types.ModuleType("azure.core.exceptions")
    azure_storage = types.ModuleType("azure.storage")
    azure_storage_queue = types.ModuleType("azure.storage.queue")
    mygeotab_module = types.ModuleType("mygeotab")

    class DummyFunctionApp:
        def __init__(self, *args, **kwargs):
            pass

        def route(self, *args, **kwargs):
            def decorator(fn):
                return fn
            return decorator

        def queue_trigger(self, *args, **kwargs):
            def decorator(fn):
                return fn
            return decorator

    class DummyHttpResponse:
        def __init__(self, body=None, status_code=200, mimetype=None, headers=None, *args, **kwargs):
            self.body = body
            self.status_code = status_code
            self.mimetype = mimetype
            self.headers = headers or {}
            self.args = args
            self.kwargs = kwargs

    class DummyAuthLevel:
        FUNCTION = "FUNCTION"
        ANONYMOUS = "ANONYMOUS"

    class DummyTableServiceClient:
        @classmethod
        def from_connection_string(cls, *args, **kwargs):
            return cls()

        def create_table_if_not_exists(self, *args, **kwargs):
            return None

        def get_table_client(self, *args, **kwargs):
            return self

        def get_entity(self, *args, **kwargs):
            raise RuntimeError("not implemented in tests")

        def upsert_entity(self, *args, **kwargs):
            return None

        def query_entities(self, *args, **kwargs):
            return []

    class DummyUpdateMode:
        MERGE = "MERGE"

    class DummyQueueClient:
        @classmethod
        def from_connection_string(cls, *args, **kwargs):
            return cls()

        def create_queue(self):
            return None

        def send_message(self, *args, **kwargs):
            return None

    class DummyAPI:
        def __init__(self, *args, **kwargs):
            pass

    class DummyQueueMessage:
        def get_body(self):
            return b"{}"

    azure_functions.FunctionApp = DummyFunctionApp
    azure_functions.HttpResponse = DummyHttpResponse
    azure_functions.AuthLevel = DummyAuthLevel
    azure_functions.HttpRequest = object
    azure_functions.QueueMessage = DummyQueueMessage
    azure_data_tables.TableServiceClient = DummyTableServiceClient
    azure_data_tables.UpdateMode = DummyUpdateMode
    azure_core_exceptions.ResourceExistsError = RuntimeError
    azure_storage_queue.QueueClient = DummyQueueClient
    mygeotab_module.API = DummyAPI

    sys.modules.setdefault("azure", azure_module)
    sys.modules.setdefault("azure.functions", azure_functions)
    sys.modules.setdefault("azure.data", azure_data)
    sys.modules.setdefault("azure.data.tables", azure_data_tables)
    sys.modules.setdefault("azure.core", azure_core)
    sys.modules.setdefault("azure.core.exceptions", azure_core_exceptions)
    sys.modules.setdefault("azure.storage", azure_storage)
    sys.modules.setdefault("azure.storage.queue", azure_storage_queue)
    sys.modules.setdefault("mygeotab", mygeotab_module)


install_test_stubs()

import function_app  # noqa: E402


class DummyRequest:
    def __init__(self, method="GET", headers=None, params=None, body=None):
        self.method = method
        self.headers = headers or {}
        self.params = params or {}
        self._body = body if body is not None else {}

    def get_json(self):
        return self._body


def response_payload(response):
    return function_app.json.loads(response.body)


class ScheduleLogicTests(unittest.TestCase):
    def test_every_15_minutes_rounds_forward(self):
        schedule = {
            "preset": "every-15-minutes",
            "timezone": "Australia/Adelaide",
        }
        reference = datetime(2026, 4, 23, 1, 7, tzinfo=timezone.utc)
        next_run = function_app.compute_next_run_at_utc(schedule, reference)
        self.assertEqual(next_run, "2026-04-23T01:15:00+00:00")

    def test_hourly_rounds_to_next_hour(self):
        schedule = {
            "preset": "hourly",
            "timezone": "UTC",
        }
        reference = datetime(2026, 4, 23, 1, 7, tzinfo=timezone.utc)
        next_run = function_app.compute_next_run_at_utc(schedule, reference)
        self.assertEqual(next_run, "2026-04-23T02:00:00+00:00")

    def test_daily_uses_tenant_timezone(self):
        schedule = {
            "preset": "daily",
            "timezone": "Australia/Adelaide",
            "dailyTime": "09:00",
        }
        reference = datetime(2026, 4, 22, 23, 0, tzinfo=timezone.utc)
        next_run = function_app.compute_next_run_at_utc(schedule, reference)
        self.assertEqual(next_run, "2026-04-22T23:30:00+00:00")

    def test_weekly_uses_named_weekday(self):
        schedule = {
            "preset": "weekly",
            "timezone": "Australia/Adelaide",
            "dailyTime": "09:00",
            "weeklyDay": "friday",
        }
        reference = datetime(2026, 4, 22, 23, 0, tzinfo=timezone.utc)
        next_run = function_app.compute_next_run_at_utc(schedule, reference)
        self.assertEqual(next_run, "2026-04-23T23:30:00+00:00")

    def test_daily_dst_gap_normalizes_forward(self):
        schedule = {
            "preset": "daily",
            "timezone": "America/New_York",
            "dailyTime": "02:30",
        }
        reference = datetime(2026, 3, 8, 5, 0, tzinfo=timezone.utc)
        next_run = function_app.compute_next_run_at_utc(schedule, reference)
        self.assertEqual(next_run, "2026-03-08T07:30:00+00:00")


class SecurityControlTests(unittest.TestCase):
    def test_missing_token_returns_401(self):
        req = DummyRequest(method="GET")
        _, response = function_app.require_authorization(req)
        self.assertEqual(response.status_code, 401)

    def test_valid_token_without_required_role_returns_403(self):
        req = DummyRequest(method="GET", headers={"Authorization": "Bearer token"})
        with patch.dict(function_app.os.environ, {"ENTRA_REQUIRED_ROLE": "ExchangeLink.Operator"}), \
                patch.object(function_app, "decode_entra_token", return_value={"roles": ["Reader"]}):
            _, response = function_app.require_authorization(req)
        self.assertEqual(response.status_code, 403)

    def test_valid_operator_token_reaches_protected_handler(self):
        req = DummyRequest(method="GET", headers={"Authorization": "Bearer token"})
        with patch.dict(function_app.os.environ, {"ENTRA_REQUIRED_ROLE": "ExchangeLink.Operator"}), \
                patch.object(function_app, "decode_entra_token", return_value={"roles": ["ExchangeLink.Operator"]}):
            claims, response = function_app.require_authorization(req)
        self.assertIsNone(response)
        self.assertEqual(claims["roles"], ["ExchangeLink.Operator"])

    def test_untrusted_cors_origin_is_not_echoed(self):
        req = DummyRequest(headers={"Origin": "https://evil.example"})
        with patch.dict(function_app.os.environ, {"ALLOWED_CORS_ORIGINS": "https://trusted.example"}):
            response = function_app.json_response({"ok": True}, req=req)
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)
        self.assertEqual(response.headers["Vary"], "Origin")

    def test_trusted_cors_origin_is_echoed(self):
        req = DummyRequest(headers={"Origin": "https://trusted.example"})
        with patch.dict(function_app.os.environ, {"ALLOWED_CORS_ORIGINS": "https://trusted.example"}):
            response = function_app.json_response({"ok": True}, req=req)
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], "https://trusted.example")

    def test_sync_credential_override_fields_are_rejected(self):
        req = DummyRequest(
            method="POST",
            headers={"Authorization": "Bearer token"},
            body={"maxDevices": 1, "myGeotabDatabase": "other"},
        )
        with patch.object(function_app, "decode_entra_token", return_value={"roles": ["ExchangeLink.Operator"]}):
            response = function_app.sync_to_exchange(req)
        self.assertEqual(response.status_code, 400)
        self.assertIn("myGeotabDatabase", response_payload(response)["unsupportedFields"])

    def test_manual_sync_is_rejected_while_job_active(self):
        active_job = {
            "jobId": "job1",
            "status": "running",
            "createdAt": "2026-04-24T00:00:00+00:00",
            "currentStage": "Syncing",
        }
        req = DummyRequest(method="POST", headers={"Authorization": "Bearer token"}, body={"maxDevices": 1})
        with patch.object(function_app, "decode_entra_token", return_value={"roles": ["ExchangeLink.Operator"]}), \
                patch.object(function_app, "active_sync_job_summary", return_value=active_job):
            response = function_app.sync_to_exchange(req)
        self.assertEqual(response.status_code, 409)

    def test_device_update_uses_only_canonical_id(self):
        calls = []

        class DummyApi:
            def get(self, type_name, search=None):
                calls.append(search)
                return []

        with self.assertRaisesRegex(RuntimeError, "Device not found by id"):
            function_app.fetch_device_for_update(DummyApi(), "serial-or-name")
        self.assertEqual(calls, [{"id": "serial-or-name"}])

    def test_health_omits_configuration_details(self):
        response = function_app.health(DummyRequest(method="GET"))
        payload = response_payload(response)
        self.assertEqual(payload["status"], "healthy")
        self.assertNotIn("config", payload)

    def test_sync_status_omits_mailbox_addresses(self):
        entity = {
            "RowKey": "job1",
            "status": "completed",
            "failed": 0,
            "resultsJson": function_app.json.dumps([
                {
                    "deviceId": "b1",
                    "serial": "abc",
                    "vehicleName": "Asset 1",
                    "primarySmtpAddress": "abc@example.com",
                    "success": True,
                    "message": "Updated abc@example.com",
                }
            ]),
        }
        req = DummyRequest(method="GET", headers={"Authorization": "Bearer token"}, params={"jobId": "job1"})
        with patch.object(function_app, "decode_entra_token", return_value={"roles": ["ExchangeLink.Operator"]}), \
                patch.object(function_app, "get_job_entity", return_value=entity):
            response = function_app.sync_status(req)
        payload = response_payload(response)
        self.assertNotIn("primarySmtpAddress", payload["results"][0])


if __name__ == "__main__":
    unittest.main()
