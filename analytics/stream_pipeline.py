"""Structured Streaming version of the same pipeline: run continuously.

Spark treats data/raw as an unbounded table — every new .jsonl file that lands
there is picked up as a micro-batch and processed. Output is a 1-minute
windowed request/error count per service, printed as it updates.

Same DataFrame code as the batch job; what changes is the source semantics
(readStream), a watermark for late data, and a checkpoint so a restart resumes
where it left off instead of reprocessing everything.

Run (see README):
  ... python /home/jovyan/work/stream_pipeline.py --once   # process what's there, then exit
  ... python /home/jovyan/work/stream_pipeline.py          # keep running; drop new files in
"""
import os
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from log_pipeline import BASE, RAW, SCHEMA


def main(once=False):
    spark = SparkSession.builder.appName("observeops-log-stream").getOrCreate()
    spark.sparkContext.setLogLevel("WARN")

    # A folder as an unbounded source: each new file becomes one micro-batch.
    stream = spark.readStream.schema(SCHEMA).option("maxFilesPerTrigger", 1).json(RAW)

    events = (
        stream.withColumn("ts", F.to_timestamp("timestamp"))
        .filter(F.col("request_id").isNotNull() & F.col("status_code").isNotNull())
        # Watermark: an event more than 10 minutes late no longer updates its window.
        .withWatermark("ts", "10 minutes")
    )

    per_minute = events.groupBy(F.window("ts", "1 minute"), "service").agg(
        F.count("*").alias("requests"),
        F.sum(F.when(F.col("status_code") >= 500, 1).otherwise(0)).alias("errors"),
    )

    writer = (
        per_minute.writeStream.outputMode("update")
        .format("console")
        .option("truncate", False)
        .option("numRows", 20)
        .option("checkpointLocation", os.path.join(BASE, "data", "checkpoints", "per_minute"))
    )
    if once:
        writer = writer.trigger(availableNow=True)
    else:
        writer = writer.trigger(processingTime="5 seconds")

    query = writer.start()
    if not once:
        print("streaming... drop a new logs-*.jsonl into data/raw to see it processed (Ctrl+C to stop)")
    query.awaitTermination()
    spark.stop()


if __name__ == "__main__":
    main(once="--once" in sys.argv)
