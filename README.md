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

1. Locate jdk, spark, hadoop binaries source
2. based on the found source| generate a list of target spark which user can install. For example, if we find spark 4.1, jdk 21 and hadoop 3.4.3
    then we can propose to install spark 4.1

## Appendix 

Spark 4.1.x 

| Component     | Recommended Version            | Compatibility Note                                                                                                                     |
|---------------|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| JDK (Java)    | Java 17 LTS or Java 21 LTS     | Required. Spark 4.x officially dropped support for Java 8 and Java 11. Java 17 or 21 (Eclipse Temurin or Amazon Corretto) is required. |
| Hadoop Client | Apache Hadoop 3.4.x (or 3.5.x) | Spark 4.x distributions are pre-built targeting Hadoop 3.4+.                                                                           |
| Scala         | Scala 2.13                     | Built-in (Scala 2.12 dropped in Spark 4.0).                                                                                            |