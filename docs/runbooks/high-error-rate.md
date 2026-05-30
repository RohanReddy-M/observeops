# Runbook: HighErrorRate

**Alert:** HighErrorRate / CriticalErrorRate | **Severity:** Warning/Critical

## Steps
```bash
docker logs secureship --tail=100
```bash

## Common Causes
DynamoDB connection issue, bad deploy, downstream service failure.

## Fix
Check logs for traceback. Roll back deploy if error started after a push.
