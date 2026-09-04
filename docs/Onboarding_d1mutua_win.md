# # CASD spark/hdfs cluster onboarding

This tutorial aims to help you to be familiar on how to use spark/hdfs cluster inside bulle D1MUTUA.

We will follow the below steps in this tutorial.

- understand the general architecture of the cluster
- check web interface access of the cluster
- check hdfs client of the cluster
- check spark client of the cluster

## 1. Architecture of the cluster

The below figure shows the general architecture of the cluster

![architecture.png](./imgs/drees_cluster_archi_v2.png "width=70%")

- The `TS-D1MUTUA`: is the main server(Windows) which you connect to via the `SD-BOX`.
- The `d1mutua-m01, d1mutua-w01/w02/w03`: are the servers which form the spark/hdfs cluster. The end users can not access 
    them directly, but through spark/hdfs client which are installed/configured on `TS-D1MUTUA`.

## 2. Check web interface access of the cluster

This step happens inside the `TS-D1MUTUA` server (Windows).

You can visit the following url by using the `Firefox` web browser.

- [hdfs web interface](https://d1mutua-m01.casd.fr:50470/explorer.html) : is the web interface which allows users to view directories and data in the hdfs cluster.
- [spark web interface](https://d1mutua-m01.casd.fr:8090/cluster) : is the web interface which allows users to view spark jobs and available resources of the cluster. 

> There is a shortcut created in `Bureau`->`Raccourcis`->`Cluster`. You only need to double-click on it. A `Firefox` web browser
> will be opened automatically.
>
> The first connection may take few seconds, because of the kerberos ticket and user groups checking.
> You may also need to accept the certificat if you see warnings.
  
## 3. Install Spark, HDFS client

To facilitate the installation of Spark and HDFS client, CASD has developed an installation script. 

> After this step, you only have a standard spark, hdfs client which works on local mode. To connect to the cluster,
> and submit jobs, you need to follow the instructions of step 4.
> If you encounter any error in this step. copy the error message and send to `datascience@casd.eu`
## 4. Configure Spark, HDFS client for cluster access


If everything works well, you can close the powershell terminal now

> If you encounter any error in this step. copy the error message and send to `datascience@casd.eu`

## 5. Check the hdfs client access

Open a new `powershell` terminal, and run the below command


```shell
# check the hdfs file system
hdfs dfs -ls /

# check user home folder, replace your_user_name by your current D1MUTUA user name.
hdfs dfs -ls /users/your_user_name

# for example, for /users/D1MUTUA_P_LIU0000, the expected output for user D1MUTUA_P_LIU0000
-rw-------+  3 D1MUTUA_P_LIU0000 hadoop         76 2026-03-06 11:18 /users/D1MUTUA_P_LIU0000/stats.csv
drwx------+  - D1MUTUA_P_LIU0000 hadoop          0 2026-03-10 17:16 /users/D1MUTUA_P_LIU0000/tmp
```

You can also try to access the project folder

```shell
# check the projects folder
hdfs dfs -ls /projects

# try to access a project 
hdfs dfs -ls /projects/BCL_EEC
```

### 5.1 transfer data from local file system to hdfs cluster

As `spark` is a framework for distributed computing, the data must be also distributed. That's why `spark` can't use 
data from the local file system of `TS-D1MUTUA` server. As a result, we must transfer data from `local file system` 
to `hdfs cluster`

Use the same `powershell` terminal of section 5. 

```shell
# go to public folder of `TS-D1MUTUA` server
cd C:\Users\Public\Documents\demo

# check data in the local file system
ls data

# you should see stats.csv in the output.

# now upload data  from `local file system` to `hdfs cluster`
hdfs dfs -put stats.csv /users/$USER/

# check the data in hdfs
hdfs dfs -ls /users/$USER
```

## 6. Check the spark client access

First check if you have spark installed in your environment. Use the same terminal of section 4.1.

```shell
# check current spark runtime version
spark-submit --version

# you should see the below output
Welcome to
      ____              __
     / __/__  ___ _____/ /__
    _\ \/ _ \/ _ `/ __/  '_/
   /___/ .__/\_,_/_/ /_/\_\   version 3.5.7
      /_/
                        
Using Scala version 2.12.18, OpenJDK 64-Bit Server VM, 11.0.30
Branch HEAD
Compiled by user runner on 2025-09-17T20:37:30Z
Revision ed00d046951a7ecda6429accd3b9c5b2dc792b65
Url https://github.com/apache/spark
Type --help for more information.

```

### 6.1 Create and submit a spark job

> Go to your document folder and create a file called `my_job.py`, then put the below code in it

```python
from pyspark.sql import SparkSession

def main():
    # Create Spark session
    spark = SparkSession.builder \
        .appName("my_spark_job") \
        .getOrCreate()

    # For a basic test, create a small DataFrame
    df = spark.createDataFrame([
        ("Alice", 25),
        ("Bob", 30),
        ("Charlie", 35)
    ], ["name", "age"])

    df.show()

    # Just for validation: print row count
    print(f"Total rows: {df.count()}")

    spark.stop()

if __name__ == "__main__":
    main()
```

Open a `powershell terminal`, submit the job to the cluster with the below command

```shell
cd "$HOME\Documents"

spark-submit --deploy-mode cluster --master yarn my_job.py

```

> You can notice that we have configured the spark client in mode cluster, and master is yarn. So nothing runs inside 
> `TS-D1MUTUA` server. As a result, you don't need to activate python environment and pyspark
> You can check the status of your job via [yarn web UI](https://d1mutua-m01.casd.fr:8090/cluster).


### 6.2 Use spark cluster in interactive mode(pySpark)

We have seen how to submit jobs to the cluster. For exploring data, you may want to run your spark job interactively(client mode). 
In this mode the `spark driver` runs on `TS-D1MUTUA` server. So we need to install a `python virtual environment and pyspark`

In this step, we need an `anaconda terminal`. Goto `Raccourci`-> `Python`, click on `Anaconda python 11`, you should see
a popup `anaconda terminal`. Now run the below command

```shell
# check your python version
python3 -V

# create a virtual env
conda create -n 

# activate the python venv
source spark_venv/bin/activate

# check installed libs
pip list

# install pyspark, the pyspark version must match the spark version in the cluster
pip install pyspark==3.5.7

# install jupyterlab
pip install jupyterlab
```

To facilitate the usage of jupyterlab, CASD has developed a launcher to avoid port conflict between users. 
To start a jupyterlab, you can run

```shell
run_jupyterlab

# expected output
INFO: Using port: 8888
INFO: JupyterLab server runs with URL: http://d1mutua-client:8888/lab?token=79b0a30a9a2fc6adae67...482d4a77ea70d
INFO: To stop the JupyterLab, use ctrl+C or close the terminal.
```

You need to copy the jupyterlab url and open it with a browser in `TS-D1MUTUA`.

### 6.3 Use spark cluster in interactive mode(sparklyr)



