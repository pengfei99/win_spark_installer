# The cluster conf 

This folder contains the minimum required configuration files which allows the spark client to connect to the remote
spark cluster.

For each project(i.e. spark cluster), these configuration files need to be reviewed and adapted. 

**Never use the default version of the configuration file, double-check before prod**

## Hadoop conf files

The `core-site.xml`, `hdfs-site.xml` and `yarn-site.xml` are the hadoop configuration files

You need to review the name node fqdn.

## Spark conf files

The `spark-defaults.conf` and `log4j2.properties` 

## install_cluster_mode_conf.ps1

The `cluster-versions.txt` is a file to store cluster hadoop, spark version, when end user run the script, it checks 
if the client spark version matches the cluster version.

