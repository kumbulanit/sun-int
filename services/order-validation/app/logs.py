"""Logs as one JSON object per line, written to stdout.

JSON, so a log platform can search by field without parsing text. Stdout, so
the container platform collects it; the app never manages log files.
No line per successful request: at 600 req/s that would cost far more than it
tells us, and metrics count requests instead.
"""
import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # The trace this line belongs to, so a log line leads straight to its trace in Jaeger.
        trace_id = getattr(record, "otelTraceID", "0")
        if trace_id != "0":
            entry["trace_id"] = trace_id
        # Extra context: log.warning("...", extra={"fields": {"reason": "timeout"}})
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["error"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def setup_logging(level: str) -> None:
    """Send every log line, ours and the web server's, to stdout as JSON."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=level, handlers=[handler], force=True)
    # uvicorn sets up its own text loggers; hand them to ours so every line is JSON.
    # Leave "uvicorn.access" alone: uvicorn writes one line per request only if that
    # logger has somewhere to send it, and --no-access-log makes sure it doesn't.
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers.clear()
        logging.getLogger(name).propagate = True
    # httpx logs every call it makes at INFO, one line per pricing call. Warnings only.
    logging.getLogger("httpx").setLevel(logging.WARNING)
