# win_spark_installer

This objective of this project is to develop a powershell script which help user to install spark on their Windows server.

## scripts

This project contains 5 powershell scripts:
1. detect_existing_tools.ps1 : checks if user already installed spark and dependencies before
2. check_prerequisites.ps1 : checks if the spark binary and related dependencies exist
3. clean_legacy.ps1 : clean existing binary and config
4. install_spark.ps1 : install spark and its dependencies
5. post_installation_check.ps1: check if the binaries is working(e.g. java -version, spark-submit --version, etc.) 
6. cluster_config.ps1: if user need to use this spark in mode cluster, need to add cluster specific config (e.g. )

## Workflow

1. determine current situation
2. based on the found source| generate a list of target spark which user can install. For example, if we find spark 4.1, jdk 21 and hadoop 3.4.3
    then we can propose to install spark 4.1


### 1. determine current situation

Check available jdk, hadoop, spark source in a configured directory path such as `C:\Users\pliu\Documents\tools\java`, 
There are multiple jdk versions exist: 
- jdk 11: `C:\Users\pliu\Documents\tools\java\jdk-11.0.30.zip`
- jdk 17: `C:\Users\pliu\Documents\tools\java\jdk-17.0.18.zip`
- jdk 21: `C:\Users\pliu\Documents\tools\java\jdk-21.0.10.zip`

For spark, the path will be `C:\Users\pliu\Documents\tools\spark`
- spark 3.5.9: `C:\Users\pliu\Documents\tools\spark\spark-3.5.9.zip`
- spark 4.1.2: `C:\Users\pliu\Documents\tools\spark\spark-4.1.2.zip`
- spark 4.2.0: `C:\Users\pliu\Documents\tools\spark\spark-4.2.0.zip`
if detected, proposed the possible installation options.
If user want to install a version of spark, check existing installed jdk, hadoop and spark version. If user selected version 
and existing version are matched, do nothing.
If not match, remove installed version and install the user selected version.

## Appendix 

Spark 4.1.x 

| Component     | Recommended Version            | Compatibility Note                                                                                                                     |
|---------------|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| JDK (Java)    | Java 17 LTS or Java 21 LTS     | Required. Spark 4.x officially dropped support for Java 8 and Java 11. Java 17 or 21 (Eclipse Temurin or Amazon Corretto) is required. |
| Hadoop Client | Apache Hadoop 3.4.x (or 3.5.x) | Spark 4.x distributions are pre-built targeting Hadoop 3.4+.                                                                           |
| Scala         | Scala 2.13                     | Built-in (Scala 2.12 dropped in Spark 4.0).                                                                                            |


```text
[ PHASE 1: DETECTION ]
       │
       ├──► current situation: Check User Environment Scope (HKCU\Environment)
       │      ├── JAVA_HOME ──► Validate bin\java.exe (Java 17+ check)
       │      ├── HADOOP_HOME ──► Validate bin\winutils.exe
       │      └── SPARK_HOME ──► Validate bin\spark-submit.cmd
       │
       └──► check available source:
       
       │
[ PHASE 2: PREREQUISITE VALIDATION ]
       │
       ├──► Verify presence of offline staging archives (.zip / .tgz)
       ├──► Perform optional SHA-256 hash integrity validation
       └──► Block installation if Java version < 17 (Spark 4.x requirement)
       │
[ PHASE 3: STACK PROVISIONING & SECURITY HARDENING ]
       │
       ├──► Unpack JDK & Spark to space-free directories
       ├──► Provision Hadoop native Windows binaries (winutils.exe / hadoop.dll)
       ├──► Pre-create C:\tmp\hive with user Modify ACLs (Required for local Driver execution)
       ├──► Lock down installation root with NTFS ACLs (Admins/SYSTEM: Full; Users: Read/Execute)
       └──► Export User-scoped Environment Variables (HKCU) & prepend bin to PATH
       │
[ PHASE 4: VERIFICATION & CLUSTER CONNECTIVITY ]
       │
       ├──► Test JVM execution (& $JAVA_HOME\bin\java.exe -version)
       ├──► Validate spark-submit.cmd resolution
       └──► Perform test submission to remote YARN or Spark Standalone cluster
```