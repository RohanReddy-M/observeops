# Runbook: DiskSpaceLow

**Alert:** DiskSpaceLow / DiskSpaceCritical | **Severity:** Warning/Critical

## Steps
```bash
df -h
docker system df
docker system prune
```bash

## Fix
docker system prune recovers space from unused images/containers. For persistent growth, increase EBS volume in Terraform root_block_device.
