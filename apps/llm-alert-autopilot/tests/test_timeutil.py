"""
Tests for the timestamp parser behind the MTTR metric.

AlertManager timestamps are RFC 3339 as Go writes them: the fractional part has
anywhere from zero to nine digits because trailing zeros are trimmed. The parser
this replaced only handled six or more, so the millisecond timestamps Prometheus
normally sends raised an error that was swallowed, and alert_mttr_seconds never
received an observation.
"""
import os
import sys
from datetime import timezone

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from timeutil import parse_rfc3339  # noqa: E402


@pytest.mark.parametrize("value", [
    "2026-10-07T05:10:15Z",                # no fractional seconds
    "2026-10-07T05:10:15.1Z",
    "2026-10-07T05:10:15.123Z",            # milliseconds: what Prometheus usually sends
    "2026-10-07T05:10:15.123456Z",
    "2026-10-07T05:10:15.123456789Z",      # nanoseconds
])
def test_accepts_every_fraction_length_go_can_emit(value):
    parsed = parse_rfc3339(value)
    assert parsed.tzinfo == timezone.utc
    assert (parsed.year, parsed.hour, parsed.minute, parsed.second) == (2026, 5, 10, 15)


def test_duration_between_two_millisecond_timestamps():
    started = parse_rfc3339("2026-10-07T05:10:15.123Z")
    ended = parse_rfc3339("2026-10-07T05:12:45.623Z")
    assert (ended - started).total_seconds() == 150.5


def test_offset_is_converted_to_utc():
    assert parse_rfc3339("2026-10-07T10:40:15.5+05:30") == parse_rfc3339("2026-10-07T05:10:15.5Z")


@pytest.mark.parametrize("value", ["", "yesterday", "2026-10-07", "2026-10-07 05:10", "0001-01-01T00:00:00"])
def test_rejects_things_that_are_not_timestamps(value):
    with pytest.raises(ValueError):
        parse_rfc3339(value)
