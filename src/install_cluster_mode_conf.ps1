<#
.SYNOPSIS
    This script installs the required Hadoop and Spark configuration files so the HDFS, YARN, and Spark client
    can connect to a remote HDFS, Spark, YARN cluster. It also installs the required files for Hadoop cluster
    authentication token management.

.DESCRIPTION
    This script follows the below steps:
      0. Pre-flight check: Verifies all expected source configuration files exist. If any file is missing,
         it stops immediately and shows an error message.
      1. Checks user/machine environment variables HADOOP_HOME and SPARK_HOME. If they exist, continues to step 2.
         If not, stops and asks the user to run `install_spark.ps1`.
      2. Checks if HADOOP_CONF_DIR environment variable exists. If it does, copies custom Hadoop config files
         there. If not, creates the environment variable HADOOP_CONF_DIR with value HADOOP_HOME\etc\hadoop,
         then copies custom Hadoop config files to it.
      3. Copies custom Spark configuration files to SPARK_HOME\conf.
      4. Copies CASD cluster mode scripts and token management files to SPARK_HOME\conf\casd.
      5. (Optional) Checks whether the cluster endpoints are reachable via Hadoop commands.

    Expected Hadoop config files:
     - core-site.xml
     - hdfs-site.xml
     - yarn-site.xml
    Expected Spark config files:
     - spark-defaults.conf
     - log4j2.properties
    Expected token management files (inside casd-token-manager folder):
     - install-tokens.ps1
     - refresh-token.ps1
     - casd_spark.py
     - casd_spark.R
     - make-creds-file-1.0.0-SNAPSHOT.jar

.NOTES
    This script only copies custom configuration files to Hadoop and Spark folders.
    It does not install Spark or Hadoop.
#>

[CmdletBinding()]
param(
    # Directory containing your cluster configuration files.
    [string]$ClusterConfSrcDir,
    # Directory containing your token manager configuration files.
    [string]$TokenConfSrcDir,


# Optionally run hdfs/yarn command checks after TCP checks.
    [switch]$UseHadoopCommandChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Default cluster conf source file paths
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ClusterConfSrcDir)) {
    $ClusterConfSrcDir = Join-Path $PSScriptRoot 'cluster-conf'
}

if ([string]::IsNullOrWhiteSpace($TokenConfSrcDir)) {
    $TokenConfSrcDir = Join-Path $PSScriptRoot 'casd-token-conf'
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
# Default cluster conf source file paths
# ------------------------------------------------------------------

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
function Copy-ClusterConfigFile {
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
# Config folder copy helper
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
        @{ Path = $SparkCasdConfSource; Name = 'CASD configuration folder' }
    )

    foreach ($item in $requiredSources) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            Write-Err "Required source configuration not found: '$($item.Path)' ($($item.Name))"
            Write-Err "Please ensure all expected source configuration files exist before running this script."
            exit 1
        }
    }

    # Optional: Warn if specific token files mentioned in docs are missing from the CASD folder
    $expectedTokenFiles = @('install-tokens.ps1', 'refresh-token.ps1', 'casd_spark.py', 'casd_spark.R', 'make-creds-file-1.0.0-SNAPSHOT.jar')
    $missingTokenFiles = @()
    foreach ($tokenFile in $expectedTokenFiles) {
        $tokenPath = Join-Path $SparkCasdConfSource $tokenFile
        if (-not (Test-Path -LiteralPath $tokenPath)) {
            $missingTokenFiles += $tokenFile
        }
    }

    if ($missingTokenFiles.Count -gt 0) {
        Write-Warn "The following expected token management files are missing from '$SparkCasdConfSource':"
        foreach ($missing in $missingTokenFiles) { Write-Warn "  - $missing" }
        Write-Warn "Script will continue, but token management may not work correctly."
    } else {
        Write-Ok "All required source configuration and token files found."
    }

    # --------------------------------------------------------------
    # Step 1: Detect SPARK_HOME and HADOOP_HOME
    # --------------------------------------------------------------
    Write-Step 'Step 1: Detect SPARK_HOME and HADOOP_HOME environment variables in user scope.'

    $sparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
    $hadoopHome = [Environment]::GetEnvironmentVariable('HADOOP_HOME', 'User')
    $hadoopConfDir = [Environment]::GetEnvironmentVariable('HADOOP_CONF_DIR', 'User')
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')

    if ([string]::IsNullOrWhiteSpace($sparkHome) -or [string]::IsNullOrWhiteSpace($hadoopHome) -or [string]::IsNullOrWhiteSpace($javaHome))
    {
        Write-Err 'We have detect some problems in your spark, hadoop installation. You must install spark and hadoop first'

        if ( [string]::IsNullOrWhiteSpace($javaHome))
        {
            Write-Err 'Missing user environment variable: JAVA_HOME'
        }

        if ( [string]::IsNullOrWhiteSpace($sparkHome))
        {
            Write-Err 'Missing user environment variable: SPARK_HOME'
        }

        if ( [string]::IsNullOrWhiteSpace($hadoopHome))
        {
            Write-Err 'Missing user environment variable: HADOOP_HOME'
        }

        exit 1
    }

    if (-not (Test-Path -LiteralPath $sparkHome -PathType Container)) {
        Write-Err "SPARK_HOME exists but is not a valid directory: '$sparkHome'"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $hadoopHome -PathType Container)) {
        Write-Err "HADOOP_HOME exists but is not a valid directory: '$hadoopHome'"
        exit 1
    }

    Write-Ok "SPARK_HOME  = $sparkHome"
    Write-Ok "HADOOP_HOME = $hadoopHome"

    # Make these available in the current process.
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

    $coreSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $coreSiteSrc `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'core-site.xml'

    $hdfsSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $hdfsSiteSrc `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'hdfs-site.xml'

    $yarnSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $yarnSiteSrc `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'yarn-site.xml'

    # Useful for Hadoop/YARN commands in the current process.
    $env:HADOOP_CONF_DIR = $hadoopConfDir

    # --------------------------------------------------------------
    # Step 3: Copy Spark configuration file
    # --------------------------------------------------------------
    Write-Step 'Step 3: Copy Spark configuration files'

    $sparkConfDir = Join-Path $sparkHome 'conf'

    Write-Info "Spark configuration directory: $sparkConfDir"

    $sparkDefaultsTarget = Copy-ClusterConfigFile `
        -SourceFile $sparkDefaultsConfSrc `
        -DestinationDir $sparkConfDir `
        -DestinationFileName 'spark-defaults.conf'

    # --------------------------------------------------------------
    # Step 4: copy CASD cluster token management files
    # --------------------------------------------------------------
    Write-Step 'Step 4: copy CASD cluster token management files'

    if (-not (Test-Path -LiteralPath $sparkConfDir))
    {
        New-Item -ItemType Directory -Path $sparkConfDir -Force | Out-Null
    }

    Copy-Item -Path $SparkCasdConfSource -Destination $sparkConfDir -Recurse -Force
    $sparkCasdTarget = Join-Path $sparkConfDir $sparkCasdDirName

    # ----------------------------------------------------------
    # step 5: Hadoop command checks
    # ----------------------------------------------------------
    if ($UseHadoopCommandChecks)
    {
        Write-Step 'Optional Hadoop command checks'

        $hdfsCmd = Join-Path $hadoopHome 'bin\hdfs.cmd'
        $yarnCmd = Join-Path $hadoopHome 'bin\yarn.cmd'

        $hdfsOk = Test-HadoopCommand `
            -CommandPath $hdfsCmd `
            -CommandArgs @('dfsadmin', '-report') `
            -Description 'hdfs dfsadmin -report'

        $yarnOk = Test-HadoopCommand `
            -CommandPath $yarnCmd `
            -CommandArgs @('node', '-list') `
            -Description 'yarn node -list'

        if (-not $hdfsOk -or -not $yarnOk)
        {
            Write-Warn 'One or more Hadoop command checks failed.'
            Write-Warn 'TCP connectivity may still be OK, but Hadoop commands may require JAVA_HOME, HADOOP_CONF_DIR, Kerberos tickets, or winutils.'
        }
        else
        {
            Write-Ok 'Hadoop command checks succeeded.'
        }
    }


    # --------------------------------------------------------------
    # Final summary
    # --------------------------------------------------------------
    Write-Step 'Setup completed'

    Write-Host ''
    Write-Host 'Copied configuration files:' -ForegroundColor Cyan
    Write-Host "  core-site.xml       = $coreSiteTarget"
    Write-Host "  hdfs-site.xml       = $hdfsSiteTarget"
    Write-Host "  yarn-site.xml       = $yarnSiteTarget"
    Write-Host "  spark-defaults.conf = $sparkDefaultsTarget"
    Write-Host "  casd_custom_conf = $sparkCasdTarget"


    Write-Host ''
    Write-Host 'Process environment used by this script:' -ForegroundColor Cyan
    Write-Host "  SPARK_HOME      = $env:SPARK_HOME"
    Write-Host "  HADOOP_HOME     = $env:HADOOP_HOME"
    Write-Host "  HADOOP_CONF_DIR = $env:HADOOP_CONF_DIR"

    Write-Host ''
    Write-Ok 'Hadoop and Spark cluster configuration setup finished successfully.'
}
catch
{
    Write-Err $_.Exception.Message
    exit 1
}