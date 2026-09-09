# ObserveOps Log Analytics — a PySpark batch + streaming pipeline

A small data pipeline over ObserveOps's own telemetry: the structured JSON
logs the services emit (the same lines Promtail ships to Loki) are processed
with Apache Spark into per-service error rates, p95 latency per endpoint, and
requests per minute, written as Parquet partitioned by date.

It exists to answer one question with real code instead of a diagram:
*what does the batch/streaming ETL layer look like on top of this platform?*

```
data/raw/*.jsonl  ──▶  log_pipeline.py (batch)     ──▶  data/curated/*/date=.../*.parquet
                  ──▶  stream_pipeline.py (stream)  ──▶  1-minute windows, console
```

## What each file does

| File | Role |
|---|---|
| `generate_logs.py` | Produces sample logs in the real ObserveOps log schema, with deliberate duplicates and malformed rows for the quality gates to catch. Pure Python. |
| `log_pipeline.py` | **Batch ETL.** Explicit schema → drop malformed rows → dedupe by `request_id` → aggregate → Parquet partitioned by date (dynamic partition overwrite, so a re-run is idempotent). |
| `stream_pipeline.py` | **Structured Streaming.** Same aggregation over the folder as an unbounded source, with a 10-minute watermark and a checkpoint. |
| `pipeline_notebook.ipynb` | The batch pipeline as a notebook, step by step. |

## Run it (Docker — no Java or Spark install needed)

From the repo root, in PowerShell:

```powershell
# 1) generate three days of sample logs (plain Python, runs anywhere)
python analytics/generate_logs.py

# 2) batch ETL
docker run --rm -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook spark-submit /home/jovyan/work/log_pipeline.py

# 3) streaming — process what's there and exit
docker run --rm -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook spark-submit /home/jovyan/work/stream_pipeline.py --once

# 4) notebook UI (open the URL it prints, then work/pipeline_notebook.ipynb)
docker run --rm -p 8888:8888 -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook
```

`spark-submit` is how a Spark job is handed to any cluster — local, YARN,
Kubernetes, or a Databricks job — and it puts Spark's Python libraries on the
path, which plain `python` in this image does not.

Verified run (3 days of generated logs):

```
raw rows         : 60900
after validation : 60600   (dropped 300 malformed)
after dedupe     : 60000   (dropped 600 duplicates)
```

## What it demonstrates, in the JD's words

- **ETL** — extract (JSON logs), transform (validate, dedupe, type), load (Parquet).
- **Batch vs streaming** — the same DataFrame logic run once over a pile of files, and run continuously over the folder as new files arrive.
- **Data quality** — schema enforced instead of inferred, required-field gate, dedupe by natural key, and a raw→clean→deduped row-count reconciliation printed on every run.
- **Idempotent loads** — Parquet partitioned by date with dynamic partition overwrite: re-running a day rewrites only that day.
- **Spark fundamentals** — lazy transformations vs. actions (`count()`, `write`), `groupBy` as a shuffle, `percentile_approx` for p95, watermarks for late data.

## Honest scope

Runs locally on a single-node Spark inside a container over generated sample
data (~60k rows). It is not a production job, not on Databricks, and not
reading from Kafka. It is the smallest real pipeline that exercises the batch
and streaming APIs end to end over this platform's own log format.
