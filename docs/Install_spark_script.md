# Install spark script description

## 1. determine current situation

1. Check available jdk, hadoop, spark source in a configured directory path:

For jdk, the path will be `C:\Users\pliu\Documents\tools\java`, 
There are multiple jdk versions exist: 
- jdk 11: `C:\Users\pliu\Documents\tools\java\jdk-11.0.30.zip`
- jdk 17: `C:\Users\pliu\Documents\tools\java\jdk-17.0.18.zip`
- jdk 21: `C:\Users\pliu\Documents\tools\java\jdk-21.0.10.zip`

For spark, the path will be `C:\Users\pliu\Documents\tools\spark`
- spark 3.5.7: `C:\Users\pliu\Documents\tools\spark\spark-3.5.7.zip`
- spark 4.1.2: `C:\Users\pliu\Documents\tools\spark\spark-4.1.2.zip`

For hadoop, the path will be `C:\Users\pliu\Documents\tools\hadoop`
- hadoop 3.3.6: `C:\Users\pliu\Documents\tools\hadoop\hadoop-3.3.6.zip`
- hadoop 3.4.3: `C:\Users\pliu\Documents\tools\hadoop\hadoop-3.4.3.zip`

2. if spark-x.x.x.zip is detected, propose each spark version as a choice of possible installation option.
If user want to install a version of spark, check if the required jdk, hadoop source exist or not, if existed, continue
the installation, if not, show error message, missing required packages.

3. check if a spark is already installed and the installed spark version. If the user selected spark version 
and the existing version are matched, ask user to confirm if user wants to do a reinstallation. If user choose yes, then
start the installation process, if user choose no, do nothing.
4. start the installation process, remove installed spark version and it's dependencies. clean user environment variable.
install the user selected spark version.


## Appendix A. spark dependencies


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
| Component  | Recommended Version | Compatibility Note                                                    |
|------------|---------------------|-----------------------------------------------------------------------|
| JDK (Java) | Java 11 LTS         | Required. Spark 4.x officially dropped support for Java 8 and Java 11. |
| Hadoop     | Apache Hadoop 3.3.x | Spark 3.x distributions are pre-built targeting Hadoop 3.3.x.         |
| Scala      | Scala 2.12          | Built-in (Scala 2.12 dropped in Spark 4.0).                           |