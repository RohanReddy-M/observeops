"""Solutions for pyspark_exercises.py. Run in the container:

  docker run --rm -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook spark-submit /home/jovyan/work/practice/pyspark_solutions.py
"""
import os
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql import Window

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, ".."))
from log_pipeline import SCHEMA  # noqa: E402

RAW = os.path.join(BASE, "..", "data", "raw", "*.jsonl")
OUT = os.path.join(BASE, "..", "data", "practice_out")

spark = SparkSession.builder.appName("pyspark-practice").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

services = spark.createDataFrame(
    [("secureship", "platform"), ("statusservice", "platform"), ("ragservice", "ai"), ("billing", "payments")],
    ["service", "team"],
)

# 1. explicit schema — a malformed value becomes null instead of changing the column type
df = spark.read.schema(SCHEMA).json(RAW)

# 2. count() is an action: this is the first moment Spark actually reads the files
print("rows:", df.count())

# 3. two quality gates: required fields present, then one row per request_id
clean = (
    df.filter(F.col("status_code").isNotNull() & F.col("request_id").isNotNull())
      .dropDuplicates(["request_id"])
)
print("clean rows:", clean.count())

# 4. groupBy is a wide transformation → shuffle; agg does the counting per key
per_service = clean.groupBy("service").agg(
    F.count("*").alias("requests"),
    F.sum(F.when(F.col("status_code") >= 500, 1).otherwise(0)).alias("errors"),
).withColumn("error_rate", F.round(F.col("errors") / F.col("requests"), 4))
per_service.orderBy("service").show()

# 5. "per group" → Window.partitionBy; row_number ranks inside each service
per_path = clean.groupBy("service", "path").agg(F.avg("duration_ms").alias("avg_ms"))
w = Window.partitionBy("service").orderBy(F.col("avg_ms").desc())
top3 = per_path.withColumn("rn", F.row_number().over(w)).filter(F.col("rn") <= 3)
top3.orderBy("service", "rn").show(truncate=False)

# 6. LEFT keeps every service; broadcast avoids shuffling the big side; coalesce turns null into 0
joined = (
    services.join(F.broadcast(per_service), on="service", how="left")
            .withColumn("requests", F.coalesce(F.col("requests"), F.lit(0)))
            .select("service", "team", "requests")
)
joined.orderBy("service").show()

# 7. same data, SQL — same optimizer, same plan
clean.createOrReplaceTempView("requests")
spark.sql(
    """
    SELECT service, COUNT(*) AS requests,
           SUM(CASE WHEN status_code >= 500 THEN 1 ELSE 0 END) AS errors
    FROM requests
    GROUP BY service
    ORDER BY service
    """
).show()

# 8. write is an action; partitionBy makes one folder per service
per_service.write.mode("overwrite").partitionBy("service").parquet(OUT)
print("wrote", OUT)

spark.stop()
