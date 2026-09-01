# Install cluster mode conf

## Script main workflow
1. detect if user environment variables contains `SPARK_HOME` and `HADOOP_HOME`, if not, stop the scripts and 
print error message "user must install spark first", if exist, continue to step 2.
2. copy custom configuration files `core-site.xml`, `hdfs-site.xml`, and `yarn-site.xml` to the directory $HADOOP_HOME/etc/hadoop
3. copy custom configuration file `spark-defaults.conf` to the directory $SPARK_HOME/conf
4. check if the cluster is reachable after the configuration.