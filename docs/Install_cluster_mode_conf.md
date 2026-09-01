# install_cluster_mode_conf.ps1

PowerShell script for configuring a local Hadoop/Spark client to connect to a **remote HDFS, YARN, and Spark cluster**, including CASD cluster security token management.

## 1. Description

The script copies cluster-specific configuration and token-management files into an existing Spark/Hadoop installation so that local `hdfs`, `yarn`, and `spark` clients can reach a remote cluster.

It does **not** install Spark or Hadoop — run `install_spark.ps1` first so the required binaries and environment 
variables `JAVA_HOME`, `SPARK_HOME`, and `HADOOP_HOME` are set.

The script main functionalists:
1. **Pre-flights** check all expected source config/token files exist.
2. **Validates** `JAVA_HOME`, `SPARK_HOME`, and `HADOOP_HOME` (user scope) point to valid directories.
3. **Copies** custom Hadoop config to `HADOOP_CONF_DIR` (creating the env var if unset).
4. **Copies** custom Spark config to `SPARK_HOME\conf`.
5. **Copies** CASD token management files to the token target directory.
6. **Runs** the token installation script.
7. **(Optional)** Runs `hdfs`/`yarn` cluster reachability checks.

Existing destination files are backed up (with a timestamped `.backup.*` suffix) before being overwritten.

> Windows-only, PowerShell 5.1+ compatible.

## 2. Prerequisites

- A prior `install_spark.ps1` run so user-scope `JAVA_HOME`, `SPARK_HOME`, and `HADOOP_HOME` are set.
- The source configuration files present in the repo (`src/cluster-conf/` and `src/casd-token-conf/`).

## 3. Parameters

| Parameter                | Type   | Default                                         | Description                                                                                        |
|--------------------------|--------|-------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `ClusterConfSrcDir`      | string | `<script-dir>\cluster-conf`                     | Source directory for the Hadoop/Spark config templates.                                            |
| `TokenConfSrcDir`        | string | `<script-dir>\casd-token-conf`                  | Source directory for the CASD token management files.                                              |
| `TokenConfTargetDir`     | string | sibling of `SPARK_HOME` named `casd-token-conf` | Target directory where token files are copied and where `install-tokens.ps1` is invoked.           |
| `UseHadoopCommandChecks` | switch | —                                               | If set, runs `hdfs dfsadmin -report` and `yarn node -list` to check cluster reachability (Step 6). |
| `coreSiteSrc`            | string | `<ClusterConfSrcDir>\core-site.xml`             | Override source path for `core-site.xml`.                                                          |
| `hdfsSiteSrc`            | string | `<ClusterConfSrcDir>\hdfs-site.xml`             | Override source path for `hdfs-site.xml`.                                                          |
| `yarnSiteSrc`            | string | `<ClusterConfSrcDir>\yarn-site.xml`             | Override source path for `yarn-site.xml`.                                                          |
| `sparkDefaultsConfSrc`   | string | `<ClusterConfSrcDir>\spark-defaults.conf`       | Override source path for `spark-defaults.conf`.                                                    |
| `sparkLogConfSrc`        | string | `<ClusterConfSrcDir>\log4j2.properties`         | Override source path for the Spark log config.                                                     |
| `pySparkAdapterSrc`      | string | `<TokenConfSrcDir>\casd-spark.py`               | Override source path for the PySpark adapter.                                                      |
| `sparkLyrAdapterSrc`     | string | `<TokenConfSrcDir>\casd-spark.R`                | Override source path for the sparklyr adapter.                                                     |
| `tokenConvertorSrc`      | string | `<TokenConfSrcDir>\token-convertor.jar`         | Override source path for the token convertor jar.                                                  |
| `installTokenScriptSrc`  | string | `<TokenConfSrcDir>\install-tokens.ps1`          | Override source path for the token install script.                                                 |
| `refreshTokenScriptSrc`  | string | `<TokenConfSrcDir>\refresh-tokens.ps1`          | Override source path for the token refresh script.                                                 |

## 4. Usage

### 4.1 Basic (defaults)

```powershell
# Use the default source dirs in this repo, copy config, and run token install
.\src\install_cluster_mode_conf.ps1
```

### 4.2 With cluster health checks

```powershell
# Also run hdfs/yarn reachability checks after configuration
.\src\install_cluster_mode_conf.ps1 -UseHadoopCommandChecks
```

### 4.3 Custom source / target directories

```powershell
# Point to custom config and token source dirs, and a custom token target dir
.\src\install_cluster_mode_conf.ps1 `
    -ClusterConfSrcDir "C:\path\to\cluster-conf" `
    -TokenConfSrcDir "C:\path\to\token-conf" `
    -TokenConfTargetDir "D:\spark\casd-token-conf" `
    -UseHadoopCommandChecks
```

## 5. Configuration source files location

If user specify the configuration source files location, the user must ensure the configuration files are organized 
in the following way:

- `cluster-conf`: core-site.xml, hdfs-site.xml, yarn-site.xml, spark-defaults.conf, log4j2.properties 
- `casd-token-conf`: install-tokens.ps1, refresh-tokens.ps1, casd-spark.py, casd-spark.R, token-convertor.jar


## 6. Files copied

| Step | File                                                                                               | Destination           |
|------|----------------------------------------------------------------------------------------------------|-----------------------|
| 2    | `core-site.xml`                                                                                    | `$HADOOP_CONF_DIR`    |
| 2    | `hdfs-site.xml`                                                                                    | `$HADOOP_CONF_DIR`    |
| 2    | `yarn-site.xml`                                                                                    | `$HADOOP_CONF_DIR`    |
| 3    | `spark-defaults.conf`                                                                              | `$SPARK_HOME\conf`    |
| 3    | `log4j2.properties`                                                                                | `$SPARK_HOME\conf`    |
| 4    | `install-tokens.ps1`, `refresh-tokens.ps1`, `casd-spark.py`, `casd-spark.R`, `token-convertor.jar` | `$TokenConfTargetDir` |

> `HADOOP_CONF_DIR` defaults to `$HADOOP_HOME\etc\hadoop` and is created as a **user-scope** environment variable if not already set. An existing `HADOOP_CONF_DIR` is validated to be a real directory.

## 7. Workflow

### Step 0 — Pre-flight check
Verifies every expected source configuration and token file exists. Stops immediately if any is missing.

### Step 1 — Detect environment variables
Reads user-scope `SPARK_HOME`, `HADOOP_HOME`, `HADOOP_CONF_DIR`, and `JAVA_HOME`. If any of `JAVA_HOME`/`SPARK_HOME`/`HADOOP_HOME` is missing or not a valid directory, the script throws a clear error telling the user to install Spark/Hadoop/Java first.

### Step 2 — Copy Hadoop configuration
- If `HADOOP_CONF_DIR` is unset, defaults it to `$HADOOP_HOME\etc\hadoop`, creates the user env var, and warns if the directory doesn't exist yet (it will be created).
- If `HADOOP_CONF_DIR` is set, validates it's a real directory.
- Copies `core-site.xml`, `hdfs-site.xml`, and `yarn-site.xml` into it.

### Step 3 — Copy Spark configuration
Copies `spark-defaults.conf` and `log4j2.properties` into `$SPARK_HOME\conf`.

### Step 4 — Copy CASD token management files
Determines the token target directory (default: sibling of `SPARK_HOME` named `casd-token-conf`), creates it if needed, and copies the five token management files into it.

### Step 5 — Run token installation
Invokes `install-tokens.ps1` from the token target directory to set up cluster security token management. Any failure is reported and aborts the run.

### Step 6 — Cluster health checks (optional)
Only runs with `-UseHadoopCommandChecks`. Executes `hdfs dfsadmin -report` and `yarn node -list` and reports whether the cluster is reachable. A warning is shown if either check fails, noting that TCP connectivity may still be OK but Kerberos tickets/winutils may be required.

### Step 7 - Final summary
Prints the copied file locations and the process environment (`JAVA_HOME`, `SPARK_HOME`, `HADOOP_HOME`, `HADOOP_CONF_DIR`) used during the run.
