# AlertManager secrets

AlertManager reads its webhook URLs from files in this directory at notify time
(`api_url_file` / `url_file` in `../alertmanager.yml`). The files are **never
committed** — everything here except this README is gitignored.

| File | Used by | SSM parameter it is written from |
|---|---|---|
| `slack_webhook_critical` | `slack-critical` receiver | `/observeops/production/slack_webhook_critical` |
| `slack_webhook_warnings` | `slack-warnings` receiver | `/observeops/production/slack_webhook_warnings` |
| `healthchecks_url` | `watchdog-sink` receiver (deadman switch) | `/observeops/production/healthchecks_url` |

Each file contains exactly one URL and nothing else.

**Production:** `terraform/modules/compute/user_data_obs.sh` writes these from SSM
when the observability server boots.

**Local development:** the directory is empty, so Slack and heartbeat
notifications fail with a "no such file" error in the AlertManager log. That is
expected and harmless — alerts still fire, still appear in the AlertManager UI
at http://localhost:9093, and still reach the LLM autopilot. To get real Slack
messages locally, put a webhook URL in the two `slack_webhook_*` files:

```bash
echo -n 'https://hooks.slack.com/services/XXX/YYY/ZZZ' > monitoring/alertmanager/secrets/slack_webhook_critical
cp monitoring/alertmanager/secrets/slack_webhook_critical monitoring/alertmanager/secrets/slack_webhook_warnings
docker compose restart alertmanager
```

Why files instead of substituting the URLs into `alertmanager.yml`: the previous
approach ran `sed` over the tracked config at deploy time, which meant the file on
the server never matched git, a webhook URL containing `&` could be silently
mangled, and the config could not be used locally at all.
