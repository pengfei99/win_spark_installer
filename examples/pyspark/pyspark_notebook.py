import getpass
import sys
from pathlib import Path

# Add custom library path before imports
CASD_LIB_PATH = Path.home() / "AppData" / "Local" / "casd-tools" / "casd-token-conf"

if CASD_LIB_PATH.exists():
    sys.path.append(str(CASD_LIB_PATH))
else:
    print(f"[WARNING] Custom library path does not exist: {CASD_LIB_PATH}")
# import casd spark wrapper
from casd_spark import get_spark

# get user name
username = getpass.getuser()
# set spark job name
app_name = f"test_pyspark_for_{username}"

# Build HDFS paths using pathlib logic for safety
base_user_dir = f"/users/{username}"
src_data_path = f"hdfs://{base_user_dir}/stats.csv"
csv_out_path = f"hdfs://{base_user_dir}/tmp/count_resu_csv"
parquet_out_path = f"hdfs://{base_user_dir}/tmp/count_resu_parquet"

print(f"[INFO] Initializing Spark Session: {app_name}")
spark = get_spark(app_name=app_name)



print(f"[INFO] Reading source dataset from {src_data_path}")
src_df = spark.read.csv(src_data_path,header=True,inferSchema=True)
src_df.show()

print("[INFO] Source Schema:")
src_df.printSchema()

# Compute counts by sex
print("[INFO] Computing aggregation: count_by_sex")
count_by_sex = src_df.groupBy("sex").count()

# Save to CSV
print(f"[INFO] Writing CSV output to {csv_out_path}")
count_by_sex.write.mode("overwrite").option("header", "true").csv(csv_out_path)

# Save to Parquet
print(f"[INFO] Writing Parquet output to {parquet_out_path}")
count_by_sex.write.mode("overwrite").parquet(parquet_out_path)

print("[INFO] Pipeline completed successfully.")


# Guaranteed cleanup step without a context manager
print("[INFO] Stopping Spark session...")
spark.stop()