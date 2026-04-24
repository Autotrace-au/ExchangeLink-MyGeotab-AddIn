import json
import logging
import sys

from function_app import run_scheduler_tick


def main() -> int:
    try:
        result = run_scheduler_tick()
        logging.info("Scheduler tick result: %s", json.dumps(result))
        print(json.dumps(result))
        return 0
    except Exception as exc:
        logging.exception("Scheduler tick failed")
        print(json.dumps({"status": "error", "message": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
