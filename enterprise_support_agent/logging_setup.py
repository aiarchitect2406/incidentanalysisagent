"""Structured Cloud Logging with OpenTelemetry trace correlation.

Every emitted log line carries `logging.googleapis.com/trace` and
`logging.googleapis.com/spanId` fields when an OTel context is active,
so a Logs Explorer query against an event name returns rows that link
directly into the matching trace in the GEAP Observability tab.
"""
import logging
import os
import sys

_INITIALIZED = False


def init_logging() -> logging.Logger:
    """Idempotent setup. Safe to call from every module entry point."""
    global _INITIALIZED
    logger = logging.getLogger("enterprise_support_agent")
    if _INITIALIZED:
        return logger

    try:
        from google.cloud import logging as cloud_logging
        client = cloud_logging.Client()
        client.setup_logging(log_level=logging.INFO)
    except Exception:
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stdout,
            format="%(asctime)s %(levelname)s %(name)s %(message)s",
        )

    logger.addFilter(_TraceContextFilter())
    logger.setLevel(logging.INFO)
    _INITIALIZED = True
    return logger


class _TraceContextFilter(logging.Filter):
    """Attach OTel trace+span IDs in the format Cloud Logging recognizes."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            from opentelemetry import trace
            span = trace.get_current_span()
            ctx = span.get_span_context() if span else None
            if ctx and ctx.is_valid:
                project = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
                trace_id = format(ctx.trace_id, "032x")
                span_id = format(ctx.span_id, "016x")
                setattr(
                    record,
                    "logging.googleapis.com/trace",
                    f"projects/{project}/traces/{trace_id}",
                )
                setattr(record, "logging.googleapis.com/spanId", span_id)
                setattr(record, "logging.googleapis.com/trace_sampled", True)
        except Exception:
            pass
        return True


def event(logger: logging.Logger, name: str, **fields) -> None:
    """Emit a structured event row that Cloud Logging will index as jsonPayload."""
    payload = {"event": name, **fields}
    logger.info(name, extra={"json_fields": payload})
