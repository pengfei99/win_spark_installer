<#
.SYNOPSIS
    This script installs the required Hadoop and Spark configuration files so the HDFS, YARN, and Spark client
    can connect to a remote HDFS, Spark, YARN cluster. It also installs the required files for Hadoop cluster
    authentication token management.

.DESCRIPTION
    This script follows the below steps:
      0. Pre-flight check: Verifies all expected source configuration files exist. If any file is missing,
         it stops immediately and shows an error message.
      1. Checks user environment variables HADOOP_HOME, SPARK_HOME, and JAVA_HOME. If they exist, continues to step 2.
         If not, stops and asks the user to install Spark, Hadoop, and Java first.
      2. Checks if HADOOP_CONF_DIR environment variable exists. If it does, copies custom Hadoop config files
         there. If not, creates the environment variable HADOOP_CONF_DIR with value $HADOOP_HOME\etc\hadoop,
         then copies custom Hadoop config files to it.
      3. Copies custom Spark configuration files to SPARK_HOME\conf.
      4. Copies CASD cluster token manager configuration files to $TokenConfTargetDir.
      5. Runs the install-tokens.ps1 script located in $TokenConfTargetDir.
      6. (Optional) Checks whether the cluster endpoints are reachable via Hadoop commands.

    Expected Hadoop config files:
     - core-site.xml
     - hdfs-site.xml
     - yarn-site.xml
    Expected Spark config files:
     - spark-defaults.conf
     - log4j2.properties
    Expected token management files (inside casd-token-conf folder):
     - install-tokens.ps1
     - refresh-tokens.ps1
     - casd-spark.py
     - casd-spark.R
     - token-convertor.jar

.NOTES
    This script only copies custom configuration files to Hadoop and Spark folders.
    It does not install Spark or Hadoop.
#>

[CmdletBinding()]
param(
    # Directory containing your cluster configuration source files.
    [string]$ClusterConfSrcDir,

    # Directory containing your token manager configuration source files.
    [string]$TokenConfSrcDir,

    # Target Directory containing your token manager configuration files.
    [string]$TokenConfTargetDir,

    # Optionally run hdfs/yarn command checks.
    [switch]$UseHadoopCommandChecks,

    # Optional overrides for specific source file paths.
    # Declared here to prevent Set-StrictMode -Version Latest errors.
    [string]$coreSiteSrc,
    [string]$hdfsSiteSrc,
    [string]$yarnSiteSrc,
    [string]$sparkDefaultsConfSrc,
    [string]$sparkLogConfSrc,
    [string]$pySparkAdapterSrc,
    [string]$sparkLyrAdapterSrc,
    [string]$tokenConvertorSrc,
    [string]$installTokenScriptSrc,
    [string]$refreshTokenScriptSrc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Default token manager conf file names
# ------------------------------------------------------------------
$tokenConfDirName = 'casd-token-conf'
$pySparkAdapterName = "casd-spark.py"
$sparkLyrAdapterName = "casd-spark.R"
$tokenConvertorName = "token-convertor.jar"
$installTokenScriptName = "install-tokens.ps1"
$refreshTokenScriptName = "refresh-tokens.ps1"

# ------------------------------------------------------------------
# Default cluster conf source file paths
# ------------------------------------------------------------------
$clusterConfDirName = 'cluster-conf'

if ([string]::IsNullOrWhiteSpace($ClusterConfSrcDir)) {
    $ClusterConfSrcDir = Join-Path $PSScriptRoot $clusterConfDirName
}

if ([string]::IsNullOrWhiteSpace($coreSiteSrc)) {
    $coreSiteSrc = Join-Path $ClusterConfSrcDir 'core-site.xml'
}

if ([string]::IsNullOrWhiteSpace($hdfsSiteSrc)) {
    $hdfsSiteSrc = Join-Path $ClusterConfSrcDir 'hdfs-site.xml'
}

if ([string]::IsNullOrWhiteSpace($yarnSiteSrc)) {
    $yarnSiteSrc = Join-Path $ClusterConfSrcDir 'yarn-site.xml'
}

if ([string]::IsNullOrWhiteSpace($sparkDefaultsConfSrc)) {
    $sparkDefaultsConfSrc = Join-Path $ClusterConfSrcDir 'spark-defaults.conf'
}

if ([string]::IsNullOrWhiteSpace($sparkLogConfSrc)) {
    $sparkLogConfSrc = Join-Path $ClusterConfSrcDir 'log4j2.properties'
}

# ------------------------------------------------------------------
# Default token manager conf source file paths
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TokenConfSrcDir)) {
    $TokenConfSrcDir = Join-Path $PSScriptRoot $tokenConfDirName
}

if ([string]::IsNullOrWhiteSpace($pySparkAdapterSrc)) {
    $pySparkAdapterSrc = Join-Path $TokenConfSrcDir $pySparkAdapterName
}

if ([string]::IsNullOrWhiteSpace($sparkLyrAdapterSrc)) {
    $sparkLyrAdapterSrc = Join-Path $TokenConfSrcDir $sparkLyrAdapterName
}

if ([string]::IsNullOrWhiteSpace($tokenConvertorSrc)) {
    $tokenConvertorSrc = Join-Path $TokenConfSrcDir $tokenConvertorName
}

if ([string]::IsNullOrWhiteSpace($installTokenScriptSrc)) {
    $installTokenScriptSrc = Join-Path $TokenConfSrcDir $installTokenScriptName
}

if ([string]::IsNullOrWhiteSpace($refreshTokenScriptSrc)) {
    $refreshTokenScriptSrc = Join-Path $TokenConfSrcDir $refreshTokenScriptName
}


# ------------------------------------------------------------------
# Console helpers
# ------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Magenta
}

# ------------------------------------------------------------------
# Config file copy helper
# ------------------------------------------------------------------
function Copy-ConfigFile {
    param(
        [string]$SourceFile,
        [string]$DestinationDir,
        [string]$DestinationFileName
    )

    if ([string]::IsNullOrWhiteSpace($SourceFile)) {
        throw 'Configuration source file path is empty.'
    }

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        throw "Required configuration file not found: '$SourceFile'"
    }

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        Write-Info "Creating directory: $DestinationDir"
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $destinationFile = Join-Path $DestinationDir $DestinationFileName

    # If source and destination are the same file, do nothing.
    try {
        $sourceResolved = (Get-Item -LiteralPath $SourceFile -ErrorAction Stop).FullName
        if ((Test-Path -LiteralPath $destinationFile) -and
                ((Get-Item -LiteralPath $destinationFile -ErrorAction Stop).FullName -eq $sourceResolved)) {
            Write-Info "Source and destination are the same file: $destinationFile"
            return $destinationFile
        }
    }
    catch {
        # Ignore resolution issues and continue.
    }

    # Backup existing destination file.
    if (Test-Path -LiteralPath $destinationFile) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $backupFile = "{0}.backup.{1}" -f $destinationFile, $timestamp

        Write-Info "Backing up existing file: $destinationFile"
        Copy-Item -LiteralPath $destinationFile -Destination $backupFile -Force
        Write-Info "Backup created: $backupFile"
    }

    Copy-Item -LiteralPath $SourceFile -Destination $destinationFile -Force
    Write-Ok "Copied '$SourceFile' to '$destinationFile'"

    return $destinationFile
}

# ------------------------------------------------------------------
# Config folder copy helper (Reserved for future use)
# ------------------------------------------------------------------
function Copy-CustomConfFolder {
    param(
        [string]$SourceDir,
        [string]$DestinationDir
    )

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "Custom configuration folder not found: '$SourceDir'"
    }

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        Write-Info "Creating directory: $DestinationDir"
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force)

    if ($files.Count -eq 0) {
        Write-Warn "Custom configuration folder is empty: '$SourceDir'"
        return @()
    }

    $sourceRoot = $SourceDir.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $copiedFiles = @()

    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart($separator)
        $targetFile = Join-Path $DestinationDir $relativePath
        $targetDir = Split-Path $targetFile -Parent

        if (-not (Test-Path -LiteralPath $targetDir)) {
            Write-Info "Creating directory: $targetDir"
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        if (Test-Path -LiteralPath $targetFile) {
            $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
            $backupFile = "{0}.backup.{1}" -f $targetFile, $timestamp

            Write-Info "Backing up existing file: $targetFile"
            Copy-Item -LiteralPath $targetFile -Destination $backupFile -Force
            Write-Info "Backup created: $backupFile"
        }

        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force
        Write-Ok "Copied '$($file.Name)' to '$targetFile'"

        $copiedFiles += $targetFile
    }

    return $copiedFiles
}

# ------------------------------------------------------------------
# Optional Hadoop command check helper
# ------------------------------------------------------------------
function Test-HadoopCommand {
    param(
        [string]$CommandPath,
        [string[]]$CommandArgs,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $CommandPath -PathType Leaf)) {
        Write-Warn "Command not found: '$CommandPath'. Skipping $Description."
        return $false
    }

    Write-Info "Running: $CommandPath $( $CommandArgs -join ' ' )"

    try {
        & $CommandPath @CommandArgs | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$Description succeeded."
            return $true
        }
        else {
            Write-Warn "$Description failed with exit code $LASTEXITCODE."
            return $false
        }
    }
    catch {
        Write-Warn "$Description failed: $( $_.Exception.Message )"
        return $false
    }
}

# ------------------------------------------------------------------
# Main script
# ------------------------------------------------------------------
try {
    # --------------------------------------------------------------
    # Step 0: Pre-flight check for all source configuration files
    # --------------------------------------------------------------
    Write-Step 'Step 0: Pre-flight check for source configuration files'

    $requiredSources = @(
        @{ Path = $coreSiteSrc; Name = 'core-site.xml' },
        @{ Path = $hdfsSiteSrc; Name = 'hdfs-site.xml' },
        @{ Path = $yarnSiteSrc; Name = 'yarn-site.xml' },
        @{ Path = $sparkDefaultsConfSrc; Name = 'spark-defaults.conf' },
        @{ Path = $sparkLogConfSrc; Name = 'log4j2.properties' },
        @{ Path = $pySparkAdapterSrc; Name = $pySparkAdapterName },
        @{ Path = $sparkLyrAdapterSrc; Name = $sparkLyrAdapterName },
        @{ Path = $tokenConvertorSrc; Name = $tokenConvertorName },
        @{ Path = $installTokenScriptSrc; Name = $installTokenScriptName },
        @{ Path = $refreshTokenScriptSrc; Name = $refreshTokenScriptName }
    )

    foreach ($item in $requiredSources) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            throw "Required source configuration not found: '$($item.Path)' ($($item.Name)). Please ensure all expected source configuration files exist before running this script."
        }
    }

    # --------------------------------------------------------------
    # Step 1: Detect SPARK_HOME and HADOOP_HOME
    # --------------------------------------------------------------
    Write-Step 'Step 1: Detect SPARK_HOME, HADOOP_HOME, and JAVA_HOME environment variables in user scope.'

    $sparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
    $hadoopHome = [Environment]::GetEnvironmentVariable('HADOOP_HOME', 'User')
    $hadoopConfDir = [Environment]::GetEnvironmentVariable('HADOOP_CONF_DIR', 'User')
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')

    if ([string]::IsNullOrWhiteSpace($sparkHome) -or [string]::IsNullOrWhiteSpace($hadoopHome) -or [string]::IsNullOrWhiteSpace($javaHome)) {
        $errorMsg = "Missing required environment variables. You must install Spark, Hadoop, and Java first."
        if ([string]::IsNullOrWhiteSpace($javaHome)) { $errorMsg += "`n  - Missing user environment variable: JAVA_HOME" }
        if ([string]::IsNullOrWhiteSpace($sparkHome)) { $errorMsg += "`n  - Missing user environment variable: SPARK_HOME" }
        if ([string]::IsNullOrWhiteSpace($hadoopHome)) { $errorMsg += "`n  - Missing user environment variable: HADOOP_HOME" }
        throw $errorMsg
    }

    if (-not (Test-Path -LiteralPath $javaHome -PathType Container)) {
        throw "JAVA_HOME exists but is not a valid directory: '$javaHome'"
    }

    if (-not (Test-Path -LiteralPath $sparkHome -PathType Container)) {
        throw "SPARK_HOME exists but is not a valid directory: '$sparkHome'"
    }

    if (-not (Test-Path -LiteralPath $hadoopHome -PathType Container)) {
        throw "HADOOP_HOME exists but is not a valid directory: '$hadoopHome'"
    }

    Write-Ok "JAVA_HOME   = $javaHome"
    Write-Ok "SPARK_HOME  = $sparkHome"
    Write-Ok "HADOOP_HOME = $hadoopHome"

    # Make these available in the current process.
    $env:JAVA_HOME = $javaHome
    $env:SPARK_HOME = $sparkHome
    $env:HADOOP_HOME = $hadoopHome

    # --------------------------------------------------------------
    # Step 2: Copy Hadoop configuration files
    # --------------------------------------------------------------
    Write-Step 'Step 2: Copy Hadoop configuration files'

    # Check if HADOOP_CONF_DIR already exists, otherwise use HADOOP_HOME to create it
    if ([string]::IsNullOrWhiteSpace($hadoopConfDir)) {
        $hadoopConfDir = Join-Path $hadoopHome 'etc\hadoop'
        Write-Info "HADOOP_CONF_DIR not set. Defaulting to: $hadoopConfDir"
        [Environment]::SetEnvironmentVariable('HADOOP_CONF_DIR', $hadoopConfDir, 'User')
        Write-Info "Created user environment variable: HADOOP_CONF_DIR = $hadoopConfDir"
    }
    else {
        Write-Info "Using existing HADOOP_CONF_DIR: $hadoopConfDir"
    }

    $coreSiteTarget = Copy-ConfigFile -SourceFile $coreSiteSrc -DestinationDir $hadoopConfDir -DestinationFileName 'core-site.xml'
    $hdfsSiteTarget = Copy-ConfigFile -SourceFile $hdfsSiteSrc -DestinationDir $hadoopConfDir -DestinationFileName 'hdfs-site.xml'
    $yarnSiteTarget = Copy-ConfigFile -SourceFile $yarnSiteSrc -DestinationDir $hadoopConfDir -DestinationFileName 'yarn-site.xml'

    # Useful for Hadoop/YARN commands in the current process.
    $env:HADOOP_CONF_DIR = $hadoopConfDir

    # --------------------------------------------------------------
    # Step 3: Copy Spark configuration files
    # --------------------------------------------------------------
    Write-Step 'Step 3: Copy Spark configuration files'

    $sparkConfDir = Join-Path $sparkHome 'conf'
    Write-Info "Spark configuration directory: $sparkConfDir"

    $sparkDefaultsTarget = Copy-ConfigFile -SourceFile $sparkDefaultsConfSrc -DestinationDir $sparkConfDir -DestinationFileName 'spark-defaults.conf'
    $sparkLogTarget = Copy-ConfigFile -SourceFile $sparkLogConfSrc -DestinationDir $sparkConfDir -DestinationFileName 'log4j2.properties'

    # --------------------------------------------------------------
    # Step 4: Copy CASD cluster token management files
    # --------------------------------------------------------------
    Write-Step 'Step 4: Copy CASD cluster token management files'

    if ([string]::IsNullOrWhiteSpace($TokenConfTargetDir)) {
        $installationDir = (Get-Item $sparkHome).Parent.FullName
        $TokenConfTargetDir = Join-Path $installationDir $tokenConfDirName
    }

    if (Test-Path -Path $TokenConfTargetDir -PathType Container) {
        Write-Info "Using existing cluster token manager configuration directory: $TokenConfTargetDir"
    }
    else {
        Write-Info "The cluster token manager configuration directory does not exist. Creating it now: $TokenConfTargetDir"
        New-Item -ItemType Directory -Path $TokenConfTargetDir -Force | Out-Null
    }

    $pySparkAdapterTarget = Copy-ConfigFile -SourceFile $pySparkAdapterSrc -DestinationDir $TokenConfTargetDir -DestinationFileName $pySparkAdapterName
    $sparkLyrAdapterTarget = Copy-ConfigFile -SourceFile $sparkLyrAdapterSrc -DestinationDir $TokenConfTargetDir -DestinationFileName $sparkLyrAdapterName
    $tokenConvertorTarget = Copy-ConfigFile -SourceFile $tokenConvertorSrc -DestinationDir $TokenConfTargetDir -DestinationFileName $tokenConvertorName
    $installTokenScriptTarget = Copy-ConfigFile -SourceFile $installTokenScriptSrc -DestinationDir $TokenConfTargetDir -DestinationFileName $installTokenScriptName
    $refreshTokenScriptTarget = Copy-ConfigFile -SourceFile $refreshTokenScriptSrc -DestinationDir $TokenConfTargetDir -DestinationFileName $refreshTokenScriptName

    # --------------------------------------------------------------
    # Step 5: Run install-tokens.ps1 script in the $TokenConfTargetDir
    # --------------------------------------------------------------
    Write-Step 'Step 5: Run install-tokens.ps1 script'

    try {
        Write-Info "Executing token installation script: $installTokenScriptTarget"
        & $installTokenScriptTarget
        Write-Ok "install-tokens.ps1 executed successfully."
    }
    catch {
        Write-Warn "Failed to execute install-tokens.ps1: $($_.Exception.Message)"
        # Uncomment the line below if you want the entire setup to fail when token installation fails
        # throw "Token installation failed."
    }

    # --------------------------------------------------------------
    # Step 6: Hadoop command checks
    # --------------------------------------------------------------
    if ($UseHadoopCommandChecks) {
        Write-Step 'Step 6: Optional Hadoop command checks'

        $hdfsCmd = Join-Path $hadoopHome 'bin\hdfs.cmd'
        $yarnCmd = Join-Path $hadoopHome 'bin\yarn.cmd'

        $hdfsOk = Test-HadoopCommand -CommandPath $hdfsCmd -CommandArgs @('dfsadmin', '-report') -Description 'hdfs dfsadmin -report'
        $yarnOk = Test-HadoopCommand -CommandPath $yarnCmd -CommandArgs @('node', '-list') -Description 'yarn node -list'

        if (-not $hdfsOk -or -not $yarnOk) {
            Write-Warn 'One or more Hadoop command checks failed.'
            Write-Warn 'TCP connectivity may still be OK, but Hadoop commands may require JAVA_HOME, HADOOP_CONF_DIR, Kerberos tickets, or winutils.'
        }
        else {
            Write-Ok 'Hadoop command checks succeeded.'
        }
    }

    # --------------------------------------------------------------
    # Final summary
    # --------------------------------------------------------------
    Write-Step 'Setup completed'

    Write-Host ''
    Write-Host 'Copied cluster configuration files:' -ForegroundColor Cyan
    Write-Host ("  {0,-22} = {1}" -f 'core-site.xml', $coreSiteTarget)
    Write-Host ("  {0,-22} = {1}" -f 'hdfs-site.xml', $hdfsSiteTarget)
    Write-Host ("  {0,-22} = {1}" -f 'yarn-site.xml', $yarnSiteTarget)
    Write-Host ("  {0,-22} = {1}" -f 'spark-defaults.conf', $sparkDefaultsTarget)
    Write-Host ("  {0,-22} = {1}" -f 'log4j2.properties', $sparkLogTarget)

    Write-Host ''
    Write-Host 'Copied token manager configuration files:' -ForegroundColor Cyan
    Write-Host ("  {0,-22} = {1}" -f $tokenConvertorName, $tokenConvertorTarget)
    Write-Host ("  {0,-22} = {1}" -f $installTokenScriptName, $installTokenScriptTarget)
    Write-Host ("  {0,-22} = {1}" -f $refreshTokenScriptName, $refreshTokenScriptTarget)
    Write-Host ("  {0,-22} = {1}" -f $pySparkAdapterName, $pySparkAdapterTarget)
    Write-Host ("  {0,-22} = {1}" -f $sparkLyrAdapterName, $sparkLyrAdapterTarget)

    Write-Host ''
    Write-Host 'Process environment used by this script:' -ForegroundColor Cyan
    Write-Host "  SPARK_HOME      = $env:SPARK_HOME"
    Write-Host "  HADOOP_HOME     = $env:HADOOP_HOME"
    Write-Host "  HADOOP_CONF_DIR = $env:HADOOP_CONF_DIR"

    Write-Host ''
    Write-Ok 'Hadoop and Spark cluster configuration setup finished successfully.'
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}