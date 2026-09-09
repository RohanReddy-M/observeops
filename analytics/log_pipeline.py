"""Batch ETL over ObserveOps JSON logs with PySpark.

Extract   : read newline-delimited JSON logs with an explicit schema
Transform : drop malformed rows, dedupe by request_id, derive the event date
Load      : write per-service metrics as Parquet, partitioned by date

Run (see README):
  docker run --rm -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook \
      python /home/jovyan/work/log_pipeline.py
"""
import os

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql import types as T

BASE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(BASE, "data", "raw")
OUT = os.path.join(BASE, "data", "curated")

# Explicit schema, not inferSchema: a malformed row becomes a null we can catch,
# instead of silently changing a column's type for the whole dataset.
SCHEMA = T.StructType(
    [
        T.StructField("timestamp", T.StringType()),
        T.StructField("level", T.StringType()),
        T.StructField("service", T.StringType()),
        T.StructField("request_id", T.StringType()),
        T.StructField("method", T.StringType()),
        T.StructField("path", T.StringType()),
        T.StructField("status_code", T.IntegerType()),
        T.StructField("duration_ms", T.DoubleType()),
    ]
)


def extract(spark):
    """E — read every raw log file. Nothing runs yet: Spark only records a plan."""
    return spark.read.schema(SCHEMA).json(os.path.join(RAW, "*.jsonl"))


def transform(raw):
    """T — type the timestamp, then two data-quality gates."""
    typed = raw.withColumn("ts", F.to_timestamp("timestamp")).withColumn(
        "date", F.to_date("ts")
    )
    # Gate 1: required fields must be present
    clean = typed.filter(
        F.col("request_id").isNotNull()
        & F.col("status_code").isNotNull()
        & F.col("ts").isNotNull()
    )
    # Gate 2: idempotent — a retried request logged twice must count once
    events = clean.dropDuplicates(["request_id"])
    return typed, clean, events


def aggregate(events):
    """The actual analytics. Each groupBy is a shuffle: rows with the same key
    have to travel to the same executor — the expensive part of any Spark job."""
    per_service_day = (
        events.groupBy("date", "service")
        .agg(
            F.count("*").alias("requests"),
            F.sum(F.when(F.col("status_code") >= 500, 1).otherwise(0)).alias("errors"),
            F.expr("percentile_approx(duration_ms, 0.95)").alias("p95_ms"),
        )
        .withColumn("error_rate", F.round(F.col("errors") / F.col("requests"), 4))
    )

    per_endpoint = events.groupBy("date", "service", "method", "path").agg(
        F.count("*").alias("requests"),
        F.expr("percentile_approx(duration_ms, 0.95)").alias("p95_ms"),
    )

    per_minute = (
        events.withColumn("minute", F.date_trunc("minute", F.col("ts")))
        .groupBy("date", "service", "minute")
        .count()
        .withColumnRenamed("count", "requests")
    )
    return per_service_day, per_endpoint, per_minute


def load(name, df):
    """L — Parquet partitioned by date. With dynamic partition overwrite, re-running
    one day rewrites only that day's partition: the batch form of an idempotent write."""
    path = os.path.join(OUT, name)
    df.write.mode("overwrite").partitionBy("date").parquet(path)
    print(f"wrote {path}")


def main():
    spark = (
        SparkSession.builder.appName("observeops-log-analytics")
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    raw = extract(spark)
    typed, clean, events = transform(raw)

    # Reconciliation: know exactly what each quality gate removed.
    # count() is an action — this is where the plan actually executes.
    n_raw, n_clean, n_events = raw.count(), clean.count(), events.count()
    print(f"raw rows         : {n_raw}")
    print(f"after validation : {n_clean}   (dropped {n_raw - n_clean} malformed)")
    print(f"after dedupe     : {n_events}   (dropped {n_clean - n_events} duplicates)")

    per_service_day, per_endpoint, per_minute = aggregate(events)
    load("per_service_day", per_service_day)
    load("per_endpoint", per_endpoint)
    load("per_minute", per_minute)

    print("\nError rate and p95 latency per service per day:")
    per_service_day.orderBy("date", "service").show(50, truncate=False)
    spark.stop()


if __name__ == "__main__":
    main()
