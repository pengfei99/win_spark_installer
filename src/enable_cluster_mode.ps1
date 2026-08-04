<#
.SYNOPSIS
    Configures Hadoop and Spark for cluster mode and checks cluster reachability.

.DESCRIPTION
    This script:
      1. Checks user environment variables SPARK_HOME and HADOOP_HOME.
      2. Copies custom Hadoop config files to HADOOP_HOME\etc\hadoop.
      3. Copies custom Spark config file to SPARK_HOME\conf.
      4. Checks whether the cluster endpoints are reachable.

    Expected custom config files by default:
      core-site.xml
      hdfs-site.xml
      yarn-site.xml
      spark-defaults.conf

.NOTES
    This script only reads user environment variables.
    It does not install Spark or Hadoop.
#>

[CmdletBinding()]
param(
    # Directory containing your custom configuration files.
    [string]$ConfigSourceDir = 'C:\Users\pliu\Documents\git\win_spark_installer\clusters',

    # Individual source files. If empty, they default to files under ConfigSourceDir.
    [string]$CoreSiteXmlSource,
    [string]$HdfsSiteXmlSource,
    [string]$YarnSiteXmlSource,
    [string]$SparkDefaultsConfSource,
    [string]$SparkPyConfSource,
    [string]$SparkRConfSource,

    # Optionally run hdfs/yarn command checks after TCP checks.
    [switch]$UseHadoopCommandChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Default source file paths
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($CoreSiteXmlSource)) {
    $CoreSiteXmlSource = Join-Path $ConfigSourceDir 'core-site.xml'
}

if ([string]::IsNullOrWhiteSpace($HdfsSiteXmlSource)) {
    $HdfsSiteXmlSource = Join-Path $ConfigSourceDir 'hdfs-site.xml'
}

if ([string]::IsNullOrWhiteSpace($YarnSiteXmlSource)) {
    $YarnSiteXmlSource = Join-Path $ConfigSourceDir 'yarn-site.xml'
}

if ([string]::IsNullOrWhiteSpace($SparkDefaultsConfSource)) {
    $SparkDefaultsConfSource = Join-Path $ConfigSourceDir 'spark-defaults.conf'
}

if ([string]::IsNullOrWhiteSpace($SparkPyConfSource)) {
    $SparkPyConfSource = Join-Path $ConfigSourceDir 'casd_spark.py'
}

if ([string]::IsNullOrWhiteSpace($SparkRConfSource)) {
    $SparkRConfSource = Join-Path $ConfigSourceDir 'casd_spark.R'
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
# Config copy helper
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

    Write-Info "Running: $CommandPath $($CommandArgs -join ' ')"

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
        Write-Warn "$Description failed: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------------
# Main script
# ------------------------------------------------------------------
try {
    # --------------------------------------------------------------
    # Step 1: Detect SPARK_HOME and HADOOP_HOME
    # --------------------------------------------------------------
    Write-Step 'Step 1: Detect user SPARK_HOME and HADOOP_HOME'

    $sparkHome  = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
    $hadoopHome = [Environment]::GetEnvironmentVariable('HADOOP_HOME', 'User')

    if ([string]::IsNullOrWhiteSpace($sparkHome) -or [string]::IsNullOrWhiteSpace($hadoopHome)) {
        Write-Err 'user must install spark first'

        if ([string]::IsNullOrWhiteSpace($sparkHome)) {
            Write-Err 'Missing user environment variable: SPARK_HOME'
        }

        if ([string]::IsNullOrWhiteSpace($hadoopHome)) {
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

    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
        $env:JAVA_HOME = $javaHome
        Write-Info "Using JAVA_HOME from user environment: $javaHome"
    }

    # --------------------------------------------------------------
    # Step 2: Copy Hadoop configuration files
    # --------------------------------------------------------------
    Write-Step 'Step 2: Copy Hadoop configuration files'

    $hadoopConfDir = Join-Path $hadoopHome 'etc\hadoop'

    Write-Info "Hadoop configuration directory: $hadoopConfDir"

    $coreSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $CoreSiteXmlSource `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'core-site.xml'

    $hdfsSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $HdfsSiteXmlSource `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'hdfs-site.xml'

    $yarnSiteTarget = Copy-ClusterConfigFile `
        -SourceFile $YarnSiteXmlSource `
        -DestinationDir $hadoopConfDir `
        -DestinationFileName 'yarn-site.xml'

    # Useful for Hadoop/YARN commands in the current process.
    $env:HADOOP_CONF_DIR = $hadoopConfDir
    $env:YARN_CONF_DIR = $hadoopConfDir

    # --------------------------------------------------------------
    # Step 3: Copy Spark configuration file
    # --------------------------------------------------------------
    Write-Step 'Step 3: Copy Spark configuration file'

    $sparkConfDir = Join-Path $sparkHome 'conf'

    Write-Info "Spark configuration directory: $sparkConfDir"

    $sparkDefaultsTarget = Copy-ClusterConfigFile `
        -SourceFile $SparkDefaultsConfSource `
        -DestinationDir $sparkConfDir `
        -DestinationFileName 'spark-defaults.conf'

    # --------------------------------------------------------------
    # Step 4: copy CASD python and r cluste mode scripts
    # --------------------------------------------------------------
    Write-Step 'Step 4: copy CASD python and r cluste mode scripts'

    $sparkPyTarget = Copy-ClusterConfigFile `
        -SourceFile $SparkPyConfSource `
        -DestinationDir $sparkConfDir `
        -DestinationFileName 'casd_spark.py'

    $sparkRTarget = Copy-ClusterConfigFile `
        -SourceFile $SparkRConfSource `
        -DestinationDir $sparkConfDir `
        -DestinationFileName 'casd_spark.R'

    # ----------------------------------------------------------
    # step 5: Hadoop command checks
    # ----------------------------------------------------------
    if ($UseHadoopCommandChecks) {
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
    Write-Host 'Copied configuration files:' -ForegroundColor Cyan
    Write-Host "  core-site.xml       = $coreSiteTarget"
    Write-Host "  hdfs-site.xml       = $hdfsSiteTarget"
    Write-Host "  yarn-site.xml       = $yarnSiteTarget"
    Write-Host "  spark-defaults.conf = $sparkDefaultsTarget"
    Write-Host "  casd_spark.py = $sparkPyTarget"
    Write-Host "  casd_spark.R = $sparkRTarget"

    Write-Host ''
    Write-Host 'Process environment used by this script:' -ForegroundColor Cyan
    Write-Host "  SPARK_HOME      = $env:SPARK_HOME"
    Write-Host "  HADOOP_HOME     = $env:HADOOP_HOME"
    Write-Host "  HADOOP_CONF_DIR = $env:HADOOP_CONF_DIR"
    Write-Host "  YARN_CONF_DIR   = $env:YARN_CONF_DIR"

    Write-Host ''
    Write-Ok 'Hadoop and Spark cluster configuration setup finished successfully.'
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}