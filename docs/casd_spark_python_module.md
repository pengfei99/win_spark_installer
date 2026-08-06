# CASD spark python module

Why we need this module? Hadoop authentication tokens are automatically revoked when a spark job is finished.
So we need to generate a new for each new spark session.

## Workflow of the script
1. Read configuration from Windows Registry: Reads values from `HKCU\Software\CASD\Hadoop`.
     Expected values include things like:
     - ToolsPath 
     - SparkHome 
     - HadoopConf 
     - StagingDir 
     - DriverPort
2. Generate a Hadoop token: 
    - Runs a PowerShell script: `<ToolsPath>\refresh-tokens.ps1`
    - Writes a token file into the OS temp directory. 
    - Sets the `HADOOP_TOKEN_FILE_LOCATION` with the generated token file path.
3. Create a SparkSession 
     - Configures Spark for YARN. 
     - Sets security credential providers off. 
     - Sets staging directory. 
     - Sets driver and block manager ports.
4. Provide a context manager: `spark_session()` creates a Spark session and ensures:
     - spark.stop() is called.
     - Token files are cleaned up. (even though the token is not valid anymore, the file is still there if no clean up)