# Runbook: HighLatency

**Alert:** HighLatency | **Severity:** Warning
**Meaning:** p99 latency above 2 seconds.

## Steps
Check Grafana request duration dashboard. Check DynamoDB latency in AWS console.

## Note
RAGService /ai/* endpoints are expected to be slow (5-30s). Filter by job!=ragservice when investigating app latency.
