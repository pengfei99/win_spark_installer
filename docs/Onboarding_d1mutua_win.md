# # CASD spark/hdfs cluster onboarding

This tutorial aims to help you to be familiar on how to use spark/hdfs cluster inside bulle D1MUTUA.

We will follow the below steps in this tutorial.

- understand the general architecture of the cluster
- check web interface access of the cluster
- check hdfs client of the cluster
- check spark client of the cluster

## 1. Architecture of the cluster

The below figure shows the general architecture of the cluster

![architecture.png](./imgs/drees_cluster_archi_v2.png "width=70%")

- The `TS-D1MUTUA`: is the main server(Windows) which you connect to via the `SD-BOX`.
- The `d1mutua-m01, d1mutua-w01/w02/w03`: are the servers which form the spark/hdfs cluster. The end users can not access 
    them directly, but through spark/hdfs client which are installed/configured on `TS-D1MUTUA`.

## 2. Check web interface access of the cluster

This step happens inside the `TS-D1MUTUA` server (Windows).

You can visit the following url by using the `Firefox` web browser.

- [hdfs web interface](https://d1mutua-m01.casd.fr:50470/explorer.html) : is the web interface which allows users to view directories and data in the hdfs cluster.
- [spark web interface](https://d1mutua-m01.casd.fr:8090/cluster) : is the web interface which allows users to view spark jobs and available resources of the cluster. 

> There is a shortcut created in `Bureau`->`Raccourcis`->`Cluster`. You only need to double-click on it. A `Firefox` web browser
> will be opened automatically.
>
> The first connection may take few seconds, because of the kerberos ticket and user groups checking.
> You may also need to accept the certificat if you see warnings.
  
## 3. Install Spark, HDFS client

To facilitate the installation of Spark and HDFS client, CASD has developed an installation script. 

> After this step, you only have a standard spark, hdfs client which works on local mode. To connect to the cluster,
> and submit jobs, you need to follow the instructions of step 4.
> If you encounter any error in this step. copy the error message and send to `datascience@casd.eu`


## 4. Configure Spark, HDFS client for cluster access


If everything works well, you can close the powershell terminal now

> If you encounter any error in this step. copy the error message and send to `datascience@casd.eu`

## 5. Check the hdfs client access

Open a new `powershell` terminal, and run the below command


```shell
# check the hdfs file system
hdfs dfs -ls /

# check user home folder, replace your_user_name by your current D1MUTUA user name.
hdfs dfs -ls /users/your_user_name

# for example, for /users/D1MUTUA_P_LIU0000, the expected output for user D1MUTUA_P_LIU0000
-rw-------+  3 D1MUTUA_P_LIU0000 hadoop         76 2026-03-06 11:18 /users/D1MUTUA_P_LIU0000/stats.csv
drwx------+  - D1MUTUA_P_LIU0000 hadoop          0 2026-03-10 17:16 /users/D1MUTUA_P_LIU0000/tmp
```

You can also try to access the project folder

```shell
# check the projects folder
hdfs dfs -ls /projects

# try to access a project 
hdfs dfs -ls /projects/BCL_EEC
```

### 5.1 transfer data from local file system to hdfs cluster

As `spark` is a framework for distributed computing, the data must be also distributed. That's why `spark` can't use 
data from the local file system of `TS-D1MUTUA` server. As a result, we must transfer data from `local file system` 
to `hdfs cluster`

Use the same `powershell` terminal of section 5. 

```shell
# go to public folder of `TS-D1MUTUA` server
cd C:\Users\Public\Documents\demo

# check data in the local file system
ls data

# you should see stats.csv in the output.

# now upload data  from `local file system` to `hdfs cluster`
hdfs dfs -put stats.csv /users/$USER/

# check the data in hdfs
hdfs dfs -ls /users/$USER

# download data from `hdfs cluster` to `local file system`
# . means current folder in `local file system`
hdfs dfs -get /users/$USER/stats.csv .
```

## 6. Check the spark client access

First check if you have spark installed in your environment. Use the same terminal of section 4.1.

```shell
# check current spark runtime version
spark-submit --version

# you should see the below output
Welcome to
      ____              __
     / __/__  ___ _____/ /__
    _\ \/ _ \/ _ `/ __/  '_/
   /___/ .__/\_,_/_/ /_/\_\   version 3.5.7
      /_/
                        
Using Scala version 2.12.18, OpenJDK 64-Bit Server VM, 11.0.30
Branch HEAD
Compiled by user runner on 2025-09-17T20:37:30Z
Revision ed00d046951a7ecda6429accd3b9c5b2dc792b65
Url https://github.com/apache/spark
Type --help for more information.

```

### 6.1 Create and submit a spark job

> Go to your document folder and create a file called `my_job.py`, then put the below code in it

```python
from pyspark.sql import SparkSession

def main():
    # Create Spark session
    spark = SparkSession.builder \
        .appName("my_spark_job") \
        .getOrCreate()

    # For a basic test, create a small DataFrame
    df = spark.createDataFrame([
        ("Alice", 25),
        ("Bob", 30),
        ("Charlie", 35)
    ], ["name", "age"])

    df.show()

    # Just for validation: print row count
    print(f"Total rows: {df.count()}")

    spark.stop()

if __name__ == "__main__":
    main()
```

Open a `powershell terminal`, submit the job to the cluster with the below command

```shell
cd "$HOME\Documents"

spark-submit --deploy-mode cluster --master yarn my_job.py

```

> You can notice in the above `spark-submit` command, that we have configured the spark client in mode cluster, 
> and master is yarn. So nothing runs inside 
> `TS-D1MUTUA` server. As a result, you don't need to activate python environment and pyspark
> You can check the status of your job via [yarn web UI](https://d1mutua-m01.casd.fr:8090/cluster).

> Another point, the cluster token management is completely transparent for the end user. Because CASD has written
> a script which overwrite the origin command `spark-submit`. So the `step 4` of this tutorial is essential, otherwise
> the `spark-submit` command will ont work.
> 

### 6.2 Use spark cluster in interactive mode(pySpark)

We have seen how to submit jobs to the cluster. For exploring data, you may want to run your spark job interactively(client mode). 
In this mode the `spark driver` runs on `TS-D1MUTUA` server. So we need to install a `python virtual environment and pyspark`

To do so, we need to open an `anaconda terminal`. Goto `Raccourcis`-> `Python`, click on `Anaconda Prompt(miniconda311)`, 
you should see a popup `anaconda terminal`. Now you can run the below command to create a `python virtual environment`.

```shell
# check your python version
python3 -V

# create a virtual env with the current python interpreter version
conda create -n spark_venv python --offline

# list all existing virtual env
conda env list

# you should see spark_venv in the output

# activate the python virtual venv
conda activate spark_venv

# check installed libs
pip list

# install pyspark, the pyspark version must match the spark version in the cluster
pip install pyspark==3.5.7

# install jupyterlab
pip install jupyterlab
```

Now you have all the required dependencies to use spark cluster in interactive mode with `pyspark`.

> The `conda` command only visible in `anaconda terminal`. If you open a `powershell` or `cmd` terminal, the command `conda` 
> does not exit inside them. So if you want to use **python virtual environment**, remember 
> to open an `anaconda terminal`. Goto `Raccourcis`-> `Python`, click on `Anaconda Prompt(miniconda311)`

```powershell
# if you open a new `anaconda terminal`, don't forget to activate the `virtual environment(e.g. spark_venv)` 
conda activate spark_venv

# if you are already in the activated `virtual environment(e.g. spark_venv)`, you can run the below command
# to open a jupyter lab.
jupyter lab --port=0

# In the GUI, create a new jupyter notebook and copy the below code in it
```

> The option `--port=0` is very important. If you forget this option, you may see error messages `Port already in use`.
> Normally a browser will be launched automatically. If you don't see a browser, you can open a firefox and copy
> the jupyterlab url in the firefox.


```python
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
```
### 6.3 Use spark cluster in interactive mode(sparklyr)

```R
# Dynamically extract the current username
current_user <- Sys.info()[["user"]]
message(sprintf("Running Spark session for OS User: %s", current_user))

# Construct dynamic local configuration path
casd_conf_path <- file.path(
  "C:", "Users", current_user, "AppData", "Local", 
   "casd-tools", "casd-token-conf", "casd_spark.R"
)

if (file.exists(casd_conf_path)) {
  source(casd_conf_path, encoding = "UTF-8")
} else {
  stop(sprintf("Configuration script not found at expected path: %s", casd_conf_path))
}

library(sparklyr)
library(dplyr)

# Safe connection state tracking
sc <- NULL

# Ensure YARN application containers are cleaned up even if the script throws an error
on.exit({
  if (!is.null(sc) && connection_is_open(sc)) {
    message("Closing Spark connection and releasing YARN resources...")
    casd_spark_disconnect(sc)
  }
}, add = TRUE)

# ==============================================================================
# 1. Cluster Configuration & Network Settings
# ==============================================================================
config <- spark_config()

# YARN Resource Allocation
config$spark.executor.instances <- 2
config$spark.executor.cores     <- 1
config$spark.executor.memory    <- "2g"
config$spark.driver.memory      <- "2g"

# Network & Connectivity
config$spark.driver.bindAddress <- "0.0.0.0"
config$spark.submit.deployMode  <- "client"


# Security Tokens for HDFS and Hive metastore delegation
config$spark.yarn.security.tokens.hdfs.enabled <- "true"
config$spark.yarn.security.tokens.hive.enabled <- "true"

# Establish YARN Connection
sc <- casd_spark_connect(master = "yarn", config = config)

# ==============================================================================
# 2. Read Input File from HDFS
# ==============================================================================
# Build dynamic HDFS paths using the OS username
hdfs_csv_path <- sprintf("hdfs:///users/%s/stats.csv", current_user)

# Register the HDFS CSV file in Spark catalog
raw_tbl <- spark_read_csv(
  sc,
  name         = "raw_population",
  path         = hdfs_csv_path,
  header       = TRUE,
  infer_schema = FALSE, # BEST PRACTICE: Set FALSE on large datasets to avoid a redundant HDFS scan
  columns      = c(age = "double", sex = "string"), # Explicit schema enforcement
  memory       = FALSE, # Keep lazy off-heap until explicitly requested
  overwrite    = TRUE
)

# Debug inspection: Retrieve only top 5 rows across the network
sample_raw <- raw_tbl %>% 
  head(5) %>% 
  collect()

message("--- Raw Data Sample (First 5 Rows) ---")
print(sample_raw)

# ==============================================================================
# 3. Apply Lazy Transformations (Spark SQL Engine Translation)
# ==============================================================================
summary_tbl <- raw_tbl %>%
  # Filter missing or non-positive values
  filter(!is.na(age), age > 0) %>%
  # Aggregate in parallel on Spark worker nodes
  group_by(sex) %>%
  summarise(
    total_count = n(),
    avg_age     = mean(age, na.rm = TRUE),
    .groups     = "drop"
  ) %>%
  arrange(desc(total_count))

# OPTIMIZATION: Prevent the "Small Files Problem" on HDFS
# Condense output partitions to 1 before writing out tiny aggregated tables
summary_tbl_coalesced <- sdf_coalesce(summary_tbl, 1)

# ==============================================================================
# 4. Write Results Back to HDFS
# ==============================================================================
# Dynamic path generation for HDFS output destinations
hdfs_output_parquet <- sprintf("hdfs:///users/%s/tmp/summary_age_by_sex_parquet", current_user)
hdfs_output_csv     <- sprintf("hdfs:///users/%s/tmp/summary_age_by_sex_csv", current_user)

# Write Parquet (Optimal for Spark downstream jobs due to columnar layout & compression)
spark_write_parquet(
  x         = summary_tbl_coalesced,
  path      = hdfs_output_parquet,
  mode      = "overwrite"
)

# Write CSV (For legacy/external downstream consumption)
spark_write_csv(
  x         = summary_tbl_coalesced,
  path      = hdfs_output_csv,
  header    = TRUE,
  mode      = "overwrite"
)

message(sprintf("Successfully written results to HDFS:\n - Parquet: %s\n - CSV: %s", 
                hdfs_output_parquet, hdfs_output_csv))

# ==============================================================================
# 5. Fetch Final Results to R Memory
# ==============================================================================
results <- summary_tbl %>% collect()

message("--- Final Aggregated Results ---")
print(results)
```



