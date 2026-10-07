"""Timestamp parsing for AlertManager webhook payloads."""
import re
from datetime import datetime, timezone

# RFC 3339 as Go emits it: fractional seconds are optional and have anywhere from
# 1 to 9 digits, because Go trims trailing zeros (RFC3339Nano).
_RFC3339 = re.compile(
    r"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}:\d{2})$"
)


def parse_rfc3339(value: str) -> datetime:
    """Parse an RFC 3339 timestamp with 0-9 fractional digits into an aware datetime.

    The previous implementation sliced the string to 26 characters and appended "Z",
    which only produced a parseable value when the fraction had at least six digits.
    Prometheus usually sends millisecond precision ("...:05.123Z") and sometimes none
    at all ("...:05Z"); both raised ValueError, the exception was swallowed, and no
    MTTR was ever recorded for those alerts.
    """
    match = _RFC3339.match(value.strip())
    if not match:
        raise ValueError(f"not an RFC 3339 timestamp: {value!r}")
    date, clock, fraction, zone = match.groups()
    micros = (fraction or "0")[:6].ljust(6, "0")       # datetime holds microseconds
    offset = "+00:00" if zone in ("Z", "z") else zone
    return datetime.fromisoformat(f"{date}T{clock}.{micros}{offset}").astimezone(timezone.utc)
