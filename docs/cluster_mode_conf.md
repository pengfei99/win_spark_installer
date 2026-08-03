# Cluster mode config

To use spark as client to connect to a remote spark cluster, we need to modify the below config:
- %SPARK_HOME%\conf\spark-defaults.conf (spark conf)
- %SPARK_HOME%\conf\spark-env.cmd ()
- %HADOOP_HOME%\etc\hadoop\core-site.xml (hdfs conf)
- %HADOOP_HOME%\etc\hadoop\yarn-site.xml (yarn conf)


## spark-defaults.conf

```ini
# ===================================================================
# 1. CLUSTER CONNECTION
# ===================================================================
# Point to your Standalone Master, YARN, or Spark Connect server
# Standalone: spark://master-hostname:7077
# YARN mode:  yarn
# Spark Connect (Spark 4.x recommended): sc://master-hostname:15002
spark.master                     yarn

# Deploy Mode: Use 'client' so the driver runs on this Windows gateway
spark.submit.deployMode          client

# ===================================================================
# 2. NETWORK & DRIVER BINDING (CRITICAL FOR WINDOWS CLIENTS)
# ===================================================================
# Tell remote worker nodes how to reach back to this Windows Server Driver
spark.driver.host                windows-server-fqdn.domain.com
spark.driver.port                7001
spark.blockManager.port          7002

# ===================================================================
# 3. RESOURCE ALLOCATION PER CLIENT SESSION
# ===================================================================
# Prevent a single user session from hogging memory or cluster cores
spark.driver.memory              2g
spark.executor.memory            4g
spark.executor.cores             2

# ===================================================================
# 4. EVENT LOGGING & HISTORY SERVER INTEGRATION
# ===================================================================
# Write application logs to shared HDFS/S3 storage so History Server can render them
spark.eventLog.enabled           true
spark.eventLog.dir               hdfs://namenode:8020/var/log/spark/apps

# ===================================================================
# 5. SPARK CONNECT SETUP (Spark 4.x Standard)
# ===================================================================
# If users connect via Jupyter/PySpark notebooks using Spark Connect
# spark.remote                   sc://master-hostname:15002
```


## Spark-env.cmd

In `%SPARK_HOME%\conf\spark-env.cmd`, set up environment defaults for local client executions:

```cmd
@echo off
rem Define Local JDK and Hadoop references
set JAVA_HOME=C:\BigData\Java
set HADOOP_HOME=C:\BigData\hadoop
set SPARK_CONF_DIR=C:\BigData\spark\conf

rem Cross-Platform Classpath adjustment for Windows Clients submitting to Linux Clusters
set SPARK_DIST_CLASSPATH=%HADOOP_HOME%\etc\hadoop;%HADOOP_HOME%\share\hadoop\common\*;&HADOOP_HOME%\share\hadoop\common\lib\*
```


## core-site.xml

When Spark client applications read or write to remote HDFS storage, Spark uses Hadoop's native configuration 
files to resolve `Namenode addresses and security contexts`.

Below is an example of `core-site.xml`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <!-- Point Windows Spark Client to the Remote HDFS NameNode -->
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://namenode-hostname:8020</value>
    </property>

    <!-- Cross-Platform File Path Resolution (CRITICAL FOR WINDOWS TO LINUX CLUSTERS) -->
    <property>
        <name>hadoop.util.hash.type</name>
        <value>MURMUR_HASH</value>
    </property>

    <property>
        <name>hadoop.security.authentication</name>
        <value>kerberos</value>
    </property>
</configuration>
```

## yarn-site.xml

To make Spark YARN-aware on Windows, update your configuration files under `%HADOOP_HOME%\etc\hadoop\yarn-site.xml`.

Below is an example of `%HADOOP_HOME%\etc\hadoop\yarn-site.xml`

> Your Windows gateway must know where the YARN ResourceManager lives and how to resolve NodeManagers.
```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <!-- Point to remote YARN ResourceManager -->
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>yarn-rm-hostname.domain.com</value>
    </property>

    <!-- Address for YARN ResourceManager Application Submission -->
    <property>
        <name>yarn.resourcemanager.address</name>
        <value>yarn-rm-hostname.domain.com:8032</value>
    </property>

    <!-- Cross-platform classpath handling (Crucial for Windows Client -> Linux YARN) -->
    <property>
        <name>yarn.application.classpath</name>
        <value>$HADOOP_CONF_DIR,$HADOOP_COMMON_HOME/*,$HADOOP_COMMON_HOME/lib/*,$HADOOP_HDFS_HOME/*,$HADOOP_HDFS_HOME/lib/*,$HADOOP_YARN_HOME/*,$HADOOP_YARN_HOME/lib/*</value>
    </property>
</configuration>
```