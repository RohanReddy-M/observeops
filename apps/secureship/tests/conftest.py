"""
Test environment setup.

OTEL_SDK_DISABLED stops the OTLP exporter retrying against a collector that does
not exist during tests. Without it every run ends with a backoff loop
("Transient error StatusCode.UNAVAILABLE ... retrying in 32s") that adds nothing
but noise and seconds to CI.

Set before `main` is imported, because the tracer provider is configured at
import time.
"""
import os

os.environ.setdefault("OTEL_SDK_DISABLED", "true")
