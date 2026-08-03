# Log

[string]$_currentUser = $env:USERNAME
[string]$_currentDate = Get-Date -UFormat "%d-%m-%Y"
[string]$_currentTime = Get-Date -Format "HH-mm"
[string]$_destinationLog = "C:\Users\" + $_currentUser + "\AppData\Local\spark\"

if (-not (Test-Path $_destinationLog -PathType Container))
{
    mkdir $_destinationLog
    Write-Output -InputObject ("Information: the folder " + $_destinationLog + "was created successfully")
}

[string] $logPath = $_destinationLog + "\" + $_currentDate + "\" + $_currentTime + ".txt"
Start-Transcript -Path $logPath

#CONF

    # Java

#$_sourceJava = "S:\Java\jdk-11.0.2\*"
[string]$_sourceJava = (Get-ChildItem "S:\spark\jdk\prod").FullName
[string]$_destinationJava = "C:\Users\" + $_currentUser + "\AppData\Local\java\"

    # Hadoop

#$_sourceHadoop = "S:\Hadoop\hadoop-3.3.6\*"
[string]$_sourceHadoop = (Get-ChildItem "S:\hadoop\prod").FullName
[string]$_destinationHadoop = "C:\Users\" + $_currentUser + "\AppData\Local\hadoop\"

    # Spark

[string]$_sourceSpark = (Get-ChildItem "S:\spark\spark\prod").FullName
[string]$_destinationSpark = "C:\Users\" + $_currentUser + "\AppData\Local\spark\"

    # Winutils

[string]$_sourceWinutils = (Get-ChildItem "S:\spark\winutils\prod").FullName
[string]$_destinationWinutils = $_destinationHadoop + ($_sourceHadoop.Split("\")[-1] -replace (".zip","")) +"\bin"


# INSTALLATION

# Installer Java :

Write-Output -InputObject "Information: starting to install Java"

if (-not (Test-Path $_destinationJava -PathType Container))
{
    mkdir $_destinationJava
}

if(Test-Path -Path $_sourceJava)
{
    Copy-Item $_sourceJava -Destination $_destinationJava -Recurse -force
    Write-Output -InputObject "Information : Java installed succesfully "
}

Else
{
    Write-Warning -Message "Error : Java cannot be installed. Contact CASD."
}

# Installer Hadoop :

Write-Output -InputObject "Information: starting to install Hadoop"

if (-not (Test-Path $_destinationHadoop -PathType Container))
{
    mkdir $_destinationHadoop
}

# Permet de ne pas copier les documentations
$exclude = @("*.css","*.gif","*.html", "*.jpg", "*.png")

if(Test-Path -Path $_sourceHadoop)
{
    Copy-Item -Path $_sourceHadoop -Destination $_destinationHadoop -Recurse -force
    [String]$_HadoopZipFile = $_destinationHadoop + $_sourceHadoop.Split("\")[-1]
    ."C:\Program Files\7-Zip\7z.exe" x $_HadoopZipFile $_ "-o$($_destinationHadoop) -y"

    Write-Output -InputObject "Information: Hadoop Installed succesfully "
}

Else
{
    Write-Warning -Message "Error : Error installing hadooop. Contact CASD "
}

# Installer Spark dans le dossier AppData\Local :

Write-Output -InputObject "Information: starting to install Spark"

if (-not (Test-Path $_destinationSpark -PathType Container))
{
    mkdir $_destinationSpark
}

try
{
    tar -xzf $_sourceSpark -C $_destinationSpark 2>&1 | %{ "$_" }
    Write-Output -InputObject "Information: Spark installed with success"
}
catch
{
    Write-Warning -Message "Error: Installing Spark failed. Contact CASD"
}

# Installer les winutils dans l'install de Hadoop :

Write-Output -InputObject "Information: starting to install Winutils to ensure Windows compatibility"

try
{
    Copy-Item -Path $_sourceWinutils -Destination $_destinationWinutils -force
    Write-Output -InputObject "Information: Winutils installed successfully"
}
catch
{
    Write-Warning -Message "Error : The winutils original files in S: could not be found "
}

# Définir les variables d'environnement :

Write-Output -InputObject "Information : The environment variables are about to be setup for your account"

[string]$_pathToAdd = $_destinationSpark + $_sourceSpark.Split("\")[-1].Replace(".tgz","")+ "\bin"
[string]$_pathToAdd2 = $_destinationWinutils

[string]$_oldPath = [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)

[string[]]$_FoldersInPath=$_oldPath.Split(";")
[string]$_NewPath=""

ForEach ($_Folder in $_FoldersInPath)
{
    #Evite les duplications des variables d'environnement dans le PATH si l'utilisateur joue le script plusieurs fois

    if ((-not ($_Folder.toLower() -Like "*spark*")) -and (-not ($_Folder.toLower() -Like "*hadoop*")) -and ($_Folder -ne ""))
    {
        $_newpath+=$_Folder+";"
    }

}
$_newPath += $_pathtoAdd
$_newPath += ";" + $_pathtoAdd2

[String]$_SparkHome = $_destinationSpark + $_sourceSpark.Split("\")[-1].Replace(".tgz","")
[String]$_HadoopHome = $_destinationHadoop + ($_sourceHadoop.Split("\")[-1] -replace (".zip",""))
[String]$_JavaHome =  $_destinationJava + ($_sourceJava.Split("\")[-1])

[Environment]::SetEnvironmentVariable("SPARK_HOME", $_SparkHome  , [System.EnvironmentVariableTarget]::User)
[String]$_Message= "Information : SPARK_HOME is now set to " + $_SparkHome
Write-Output -InputObject $_Message

[Environment]::SetEnvironmentVariable("HADOOP_HOME", $_HadoopHome , [System.EnvironmentVariableTarget]::User)
[String]$_Message="Information : HADOOP_HOME is now set to " + $_HadoopHome
Write-Output -InputObject $_Message

[Environment]::SetEnvironmentVariable("JAVA_HOME",$_JavaHome , [System.EnvironmentVariableTarget]::User)
[String]$_Message="Information : JAVA_HOME is now set to " + $_JavaHome
Write-Output -InputObject $_Message

[Environment]::SetEnvironmentVariable("Path", $_newPath, [System.EnvironmentVariableTarget]::User)
[String]$_Message="Information : Path is now set to " + $_newPath
Write-Output -InputObject $_Message
Read-Host "This script will end when you press enter"

Stop-Transcript