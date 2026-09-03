# win_spark_installer

The objective of this repo is to develop powershell scripts which help user to install jdk, hadoop and spark 
on their Windows server. If the user's project has a hdfs/spark cluster. He can use the seconde script to install
cluster configuration and security token configuration.

## scripts

This project contains two main powershell scripts:

1. install_spark.ps1 : install jdk, hadoop and spark binary. After this step, user can run spark on local mode.
2. install_cluster_mode_conf.ps1: if the user's project has a hdfs/spark cluster, he needs to run this script to install
              cluster specific configuration for hadoop and spark. And cluster security token configuration for the hdfs, yarn, and spark client.

## Workflow

1. Run `install_spark.ps1` to install jdk, hadoop and spark binary
2. Check if the installation is successes. Run pyspark or sparklyr jobs.
3. Run `install_cluster_mode_conf.ps1`
4. Check hdfs cluster accessibility via `hdfs dfs -ls /`


## Notes

The name of the pyspark and sparklyr adapter must be:
- `casd_spark.py`
- `casd_spark.R`

Because the python module naming convention does not allow `-` in the name