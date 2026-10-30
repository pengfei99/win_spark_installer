# Check the below step in Production 

## Step1: Check all configuration files in cluster-conf

The config file list:
- cluster-versions.txt
- core-site.xml
- hdfs-site.xml
- log4j2.properties
- yarn-site.xml
- spark-defaults.conf

Inside these conf files, you need to check all cluster related values: `fqdm of the namenode`, `ip:port`, `kreberos principal`

## Step2: Adapt the install_spark.ps1 to the project

1. you need to check the value of `$_toolsSrcDir`, where it points to the root path of jdk, hadoop, spark. It should be 
`S:\...` by default. 
2.  If you want the user to install a specific version without interface, you can run `.\install_spark.ps1 -TargetSparkVersion 4.1.3`
or if you use the shortcut, add the option `-TargetSparkVersion 4.1.3` in the shortcut.
3. The 5th step of the installation is to run the script `install_cluster_mode_conf.ps1`, you can skip this step with
option `-SkipClusterConf`
4. You can combine the two options together `-TargetSparkVersion 4.1.3 -SkipClusterConf`

> The default target installation path is `C:\Users\pliu\AppData\Local\casd-tools`, don't recommend to change it.

## Step3. Adapt the install_cluster_mode_conf.ps1

1. You need to check the value of `$ClusterConfSrcDir`, which contains the hadoop, spark conf for connecting to the cluster. The default
 value is the `current workdir of the script\cluster-conf`, as this value is specific to a project, don't recommend to put it in `S:\`. 
2. You need to check the value of `TokenConfSrcDir`, which contains the source scripts and wrapper to manage the cluster access token. The
default value is `current workdir of the script\casd-token-conf`, it can be put in `S:`
3. You need to check the value of `$TokenConfTargetDir`, which contains the target path of the user. We don't recommend to
change this value.


## Step4. Adapt the install-tokens.ps1

1. It reads the general cluster conf values from the registry key: `HKLM:\Software\CASD\hdp-cluster`, you need to 
           adapt the value if the project does not use the default value 
2. It writes the user specific conf to the registry key($userRegPath): `HKCU:\Software\CASD\Hadoop`. We don't recommand to 
      change this value, but if you change it, you need to update the same value in `refresh-tokens.ps1`, `casd_spark.py`, and `casd_spark.R`.

## Step5. Adapt the refresh-tokens.ps1

It reads all the cluster conf values from the user registry key($REG): `HKCU:\Software\CASD\Hadoop`, if you change the value of 
`$userRegPath` in `install-tokens.ps1`. You need to adapt the value of `$REG` in `refresh-tokens.ps1`

## Step5. Create a shortcut

If you want to generate a shortcut for the `install_spark.ps1`, check the launcher dir. Run the `create_shortcut.ps1` 
script.

