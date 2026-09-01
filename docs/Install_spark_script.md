# install_spark.ps1

PowerShell script for installing Apache Spark, JDK, and Hadoop binaries on a Windows server, with per-user isolation.

It is **Windows-only**, PowerShell 5.1+ compatible, and writes **user-scope** environment variables, so a **new
PowerShell window is required** after installation.

## 1. Description

The script main functionalities:

1. **Scans** a configured directory for local source zip packages (`jdk-<version>.zip`, `hadoop-<version>.zip`,
   `spark-<version>.zip`).
2. **Selects** an Apache Spark version — either interactively from the discovered packages, or automatically via
   `-TargetSparkVersion`.
3. **Validates** that the required JDK and Hadoop packages for the chosen Spark version are present (see
   `$SparkDependencyMap`).
4. **Cleans** any previous managed installation and its user-scope environment variables.
5. **Installs** the JDK, Hadoop, and Spark into a managed installation root and sets per-user environment variables.

> Run `install_cluster_mode_conf.ps1` afterward to configure cluster mode and security tokens.

## 2. Parameters

| Parameter                      | Type   | Default                             | Description                                                                                                                               |
|--------------------------------|--------|-------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| `_toolsSrcDir`                 | string | `<script-dir>\tools`                | Root directory containing the `java/`, `hadoop/`, and `spark/` subdirectories.                                                            |
| `_javaSrcDir`                  | string | `<tools>\java`                      | Directory scanning for `jdk-<version>.zip` packages.                                                                                      |
| `_hadoopSrcDir`                | string | `<tools>\hadoop`                    | Directory scanning for `hadoop-<version>.zip` packages.                                                                                   |
| `_sparkSrcDir`                 | string | `<tools>\spark`                     | Directory scanning for `spark-<version>.zip` packages.                                                                                    |
| `InstallRoot`                  | string | `$env:LOCALAPPDATA\installed-spark` | Managed install root where JDK/Hadoop/Spark are extracted. Only directories under this root are removed by default.                       |
| `CleanAllRelatedUserVariables` | switch | —                                   | Also remove user `JAVA_HOME`/`HADOOP_HOME`/`HADOOP_CONF_DIR` even if they point **outside** `$InstallRoot`.                               |
| `TargetSparkVersion`           | string | `$null`                             | If provided (e.g. `4.1.2`, `3.5`, `4`), skip interactive selection and make the run headless. When `$null`, interactive prompts are used. |

> **Headless note:** If a Spark installation already exists, `-TargetSparkVersion` proceeds automatically (reinstall or
> replace) without prompting. Omit it to keep full interactive behavior.

## 3. Usage

### 3.1 Interactive (default)

```powershell
# Discover packages under the default <script-dir>\tools and prompt for a Spark version
.\src\install_spark.ps1
```

### 3.2 Automatic / headless (CI, scheduled tasks)

```powershell
# Install a specific Spark version without interactive prompts
.\src\install_spark.ps1 -TargetSparkVersion 4.1.2

# Use a version prefix (resolves to the highest matching package)
.\src\install_spark.ps1 -TargetSparkVersion 3.5

# Install from a custom tools directory
.\src\install_spark.ps1 -_toolsSrcDir "C:\Users\pliu\Documents\tools" -TargetSparkVersion 4.1.2

# Install into a custom root and clean ALL related user variables (even external ones)
.\src\install_spark.ps1 -InstallRoot "D:\installed-spark" -CleanAllRelatedUserVariables -TargetSparkVersion 4.1.2
```

## 4. Source packages layout

Packages must be named exactly and placed under the source directories:

```
tools/
  java/    jdk-11.0.30.zip, jdk-17.0.18.zip, jdk-21.0.10.zip
  hadoop/  hadoop-3.3.6.zip, hadoop-3.4.3.zip
  spark/   spark-3.5.7.zip, spark-4.1.2.zip
```

## 5. Workflow

### Step 1 — Detect local source packages

Scans `_javaSrcDir`, `_hadoopSrcDir`, `_sparkSrcDir` for packages matching the strict naming convention. Fails with an
error if no Spark packages are found.

### Step 2 — Select Spark version

- If `-TargetSparkVersion` is given, it's validated and matched (exact match, or prefix match to the highest eligible
  package). Stops if no package matches.
- Otherwise, the script presents an interactive numbered list of detected Spark versions.
- The matching dependency rule is fetched from `$SparkDependencyMap`, which maps each Spark version to the required JDK
  major version(s) and Hadoop version prefix(es).
- Missing required JDK/Hadoop packages abort the run with a clear error listing the gaps.

### Step 3 — Check existing Spark installation

Detects any previously installed Spark (from `SPARK_HOME`, user env, or the install root) and its version.

- **Headless (`-TargetSparkVersion`):** proceeds automatically — reinstalls the same version or replaces a different
  one.
- **Interactive:** prompts for confirm / replace / reinstall; declining exits cleanly.

### Step 4 — Clean and re-install

**4a. Clean the previous installation and user environment:**

- Backs up the full user environment to `<InstallRoot>\env-backups\user-env-<timestamp>-<id>.txt`.
- Removes old managed `spark-*`/`jdk-*`/`hadoop-*` directories under the install root (and the external Spark dir if
  confirmed / `CleanAll`).
- Removes user `JAVA_HOME`, `HADOOP_HOME`, `HADOOP_CONF_DIR`, `SPARK_HOME`, and related `PATH` entries (gated by
  `InstallRoot` / `CleanAllRelatedUserVariables`).

**4b. Install binaries:** extracts JDK, Hadoop, and Spark into `<InstallRoot>\jdk-<ver>`, `<InstallRoot>\hadoop-<ver>`,
`<InstallRoot>\spark-<ver>`. Extraction tries, in order: `tar.exe` → 7-Zip → .NET ZipArchive → `Expand-Archive`.

**4c. Configure environment:** sets user-scope `JAVA_HOME`, `HADOOP_HOME`, `HADOOP_CONF_DIR` (`<hadoop>\etc\hadoop`),
`SPARK_HOME`, and prepends each `<home>\bin` to user `PATH`.

## 6. Error handling / rollback

If installation fails after cleaning, the script restores the previously captured `JAVA_HOME`, `HADOOP_HOME`,
`HADOOP_CONF_DIR`, and `SPARK_HOME` values
and removes any partially-extracted directories.

## 7. Post-install

Open a **new PowerShell window** before running `spark-submit`, `spark-shell`, or `pyspark` so the updated user
environment variables take effect.


## 8. Appendix A. spark dependencies rules

Spark has strict dependencies rules. For example, spark 4.1.x requires a jdk 17 and hadoop 3.4.3

### A.1 Spark 4.1.x 

- JDK 17
- hadoop 3.4.3 

| Component  | Recommended Version | Compatibility Note                                                     |
|------------|---------------------|------------------------------------------------------------------------|
| JDK (Java) | Java 17 LTS         | Required. Spark 4.x officially dropped support for Java 8 and Java 11. |
| Hadoop     | Apache Hadoop 3.4.x | Spark 4.x distributions are pre-built targeting Hadoop 3.4+.           |
| Scala      | Scala 2.13          | Built-in (Scala 2.12 dropped in Spark 4.0).                            |

> We know that JDK 21 LTS works also, we choose 17 for better compatibility with hadoop 3.4.x.

### A.2 Spark 3.5.x

- JDK 11
- hadoop 3.3.6
- 
| Component  | Recommended Version | Compatibility Note                                                     |
|------------|---------------------|------------------------------------------------------------------------|
| JDK (Java) | Java 11 LTS         | Required. Spark 4.x officially dropped support for Java 8 and Java 11. |
| Hadoop     | Apache Hadoop 3.3.x | Spark 3.x distributions are pre-built targeting Hadoop 3.3.x.          |
| Scala      | Scala 2.12          | Built-in (Scala 2.12 dropped in Spark 4.0).                            |




