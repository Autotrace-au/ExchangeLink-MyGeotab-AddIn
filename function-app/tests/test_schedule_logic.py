import pathlib
import sys
import types
import unittest
from datetime import datetime, timezone


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
        def __init__(self, *args, **kwargs):
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


if __name__ == "__main__":
    unittest.main()
