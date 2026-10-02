"""PySpark practice over the real log files. Fill in each TODO, then run in the container:

  docker run --rm -v "${PWD}/analytics:/home/jovyan/work" jupyter/pyspark-notebook spark-submit /home/jovyan/work/practice/pyspark_exercises.py

Solutions: pyspark_solutions.py (same command, different file). Read only after trying.
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

spark = SparkSession.builder.appName("pyspark-practice").getOrCreate()
spark.sparkContext.setLogLevel("WARN")

# A small lookup table — the classic "broadcast the small side" case.
services = spark.createDataFrame(
    [("secureship", "platform"), ("statusservice", "platform"), ("ragservice", "ai"), ("billing", "payments")],
    ["service", "team"],
)

# 1. Read the JSONL files with the explicit SCHEMA. (transformation — nothing runs yet)
df = None  # TODO: spark.read....

# 2. How many rows? (action)
# TODO: print(df.count())

# 3. Keep rows where status_code and request_id are not null, then drop duplicate request_ids.
clean = None  # TODO

# 4. Errors per service: requests, errors, error_rate — groupBy + agg. Show it.
# TODO

# 5. Top 3 slowest paths per service by average duration — groupBy, then a Window + row_number.
# TODO

# 6. LEFT JOIN requests-per-service onto `services` so 'billing' shows with 0 requests. Broadcast the small side.
# TODO

# 7. Register clean as a temp view and run the errors-per-service query in SQL.
# TODO: clean.createOrReplaceTempView("requests"); spark.sql("...").show()

# 8. Write the errors-per-service result as Parquet partitioned by service to BASE/../data/practice_out (overwrite).
# TODO

spark.stop()
