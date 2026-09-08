# Dynamically extract the current username
current_user <- Sys.info()[["user"]]
message(sprintf("Running Spark session for OS User: %s", current_user))

# Construct CASD sparklyr wrapper path
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
  infer_schema = TRUE, # BEST PRACTICE: Set FALSE on large datasets to avoid a redundant HDFS scan
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

# close the spark session and free the resources
casd_spark_disconnect(sc)