<#
.SYNOPSIS
    Multi-User Windows Server - Local Apache Spark Installation & Isolation Script.

.DESCRIPTION
    Scans local zip packages for JDK, Hadoop, and Spark.
    Validates required dependencies, cleans previous user-level installations,
    extracts binaries to space-free managed directories, and configures isolated
    User environment variables ([EnvironmentVariableTarget]::User).

.NOTES
    Expected source zip names:
        jdk-<version>.zip
        hadoop-<version>.zip
        spark-<version>.zip

    Default managed root:
        $HOME\Tools\Installed
#>

[CmdletBinding()]
param(
    [string]$_javaSrcDir   = "$HOME\Tools\java",
    [string]$_hadoopSrcDir = "$HOME\Tools\hadoop",
    [string]$_sparkSrcDir  = "$HOME\Tools\spark",
    [string]$InstallRoot   = "$HOME\Tools\installed",

    # If specified, also removes user JAVA_HOME/HADOOP_HOME even if they
    # do not point under $InstallRoot.
    [switch]$CleanAllRelatedUserVariables,

    # If null or empty, interactive Spark selection is used.
    # If valid, example: 3.5.9 or 4.1.2, skip interactive Spark selection.
    [AllowNull()]
    [AllowEmptyString()]
    [string]$TargetSparkVersion = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Dependency Map (Spark -> Java / Hadoop)
# ------------------------------------------------------------------
$SparkDependencyMap = @{
    '3.5.9' = @{ JavaMajorVersions = @('11');      HadoopVersionPrefixes = @('3.3') }
    '4.1.2' = @{ JavaMajorVersions = @('17');      HadoopVersionPrefixes = @('3.4') }
    '4.2.0' = @{ JavaMajorVersions = @('17', '21'); HadoopVersionPrefixes = @('3.5') }

    # Fallback Rules
    '3.5'   = @{ JavaMajorVersions = @('11');      HadoopVersionPrefixes = @('3.3') }
    '4'     = @{ JavaMajorVersions = @('17');      HadoopVersionPrefixes = @('3.4') }
    '3'     = @{ JavaMajorVersions = @('11', '17'); HadoopVersionPrefixes = @('3.3') }
}

# ------------------------------------------------------------------
# Console Logging Helpers
# ------------------------------------------------------------------
function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Magenta }

# ------------------------------------------------------------------
# Version Helpers
# ------------------------------------------------------------------
function ConvertTo-ComparableVersion {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return [Version]::new(0, 0, 0, 0)
    }

    $parts = @($Version -split '\.' | ForEach-Object { [int]$_ })

    if ($parts.Count -gt 4) { $parts = $parts[0..3] }
    while ($parts.Count -lt 4) { $parts += 0 }

    return [Version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Test-VersionPrefix {
    param([string]$Version, [string]$Prefix)
    return ($Version -eq $Prefix) -or ($Version.StartsWith("$Prefix."))
}

function Test-PathPrefix {
    param([string]$Path, [string]$Prefix)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        return $false
    }

    $normalizedPath   = $Path.TrimEnd('\')
    $normalizedPrefix = $Prefix.TrimEnd('\')

    return (
        $normalizedPath.Equals($normalizedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith("$normalizedPrefix\", [StringComparison]::OrdinalIgnoreCase)
    )
}

# ------------------------------------------------------------------
# Package Discovery
# ------------------------------------------------------------------
function Get-ZipPackages {
    param([string]$Path, [string]$Prefix)

    $packages = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $packages }

    $pattern = "^{0}-(?<version>\d+(?:\.\d+)*)\.zip$" -f [regex]::Escape($Prefix)

    Get-ChildItem -LiteralPath $Path -File -Filter "$Prefix-*.zip" -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match $pattern) {
                $version = $Matches.version
                $parts   = $version -split '\.'
                $major   = $parts[0]
                $majorMinor = if ($parts.Count -ge 2) { "$($parts[0]).$($parts[1])" } else { $major }

                $packages += [PSCustomObject]@{
                    Name       = $_.Name
                    FullPath   = $_.FullName
                    Version    = $version
                    Major      = $major
                    MajorMinor = $majorMinor
                }
            }
        }

    return @(
        $packages | Sort-Object -Property @{
            Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true
        }
    )
}

function Get-SparkDependencyRule {
    param([string]$SparkVersion)

    $parts = $SparkVersion -split '\.'
    $major = $parts[0]
    $majorMinor = if ($parts.Count -ge 2) { "$($parts[0]).$($parts[1])" } else { $major }

    foreach ($key in @($SparkVersion, $majorMinor, $major)) {
        if ($SparkDependencyMap.ContainsKey($key)) {
            return $SparkDependencyMap[$key]
        }
    }
    return $null
}

function Select-EligibleJava {
    param($JavaPackages, [string[]]$RequiredMajors)

    $eligible = @(
        $JavaPackages |
            Where-Object { $RequiredMajors -contains $_.Major } |
            Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true }
    )

    if ($eligible.Count -eq 0) { return $null }
    return $eligible[0]
}

function Select-EligibleHadoop {
    param($HadoopPackages, [string[]]$RequiredPrefixes)

    $eligible = @(
        $HadoopPackages |
            Where-Object {
                $pkg = $_
                @($RequiredPrefixes | Where-Object { Test-VersionPrefix -Version $pkg.Version -Prefix $_ }).Count -gt 0
            } |
            Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true }
    )

    if ($eligible.Count -eq 0) { return $null }
    return $eligible[0]
}

# ------------------------------------------------------------------
# Interactive Helpers
# ------------------------------------------------------------------
function Select-SparkPackage {
    param($SparkPackages)

    $packages = @($SparkPackages)
    Write-Host "`nAvailable Spark versions:" -ForegroundColor Cyan

    for ($i = 0; $i -lt $packages.Count; $i++) {
        Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $packages[$i].Version, $packages[$i].Name)
    }
    Write-Host '  [0] Exit'

    while ($true) {
        $choice = Read-Host 'Select a Spark version to install'
        if ($choice -eq '0') { return $null }

        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $packages.Count) {
            return $packages[$index - 1]
        }
        Write-Warn 'Invalid selection. Enter a number from the list.'
    }
}

# ------------------------------------------------------------------
# Environment Helpers
# ------------------------------------------------------------------
function Backup-UserEnvironment {
    param([string]$InstallRoot)

    $backupDir = Join-Path $InstallRoot 'env-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $fileName  = "user-env-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $backupFile = Join-Path $backupDir $fileName

    $lines = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::User).GetEnumerator() |
        ForEach-Object { "{0}={1}" -f $_.Key, $_.Value } | Sort-Object

    $lines | Set-Content -LiteralPath $backupFile -Encoding UTF8
    Write-Info "User environment backed up to: $backupFile"
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $userPath    = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)

    $all = @()
    if ($machinePath) { $all += @($machinePath -split ';' | Where-Object { $_ }) }
    if ($userPath)    { $all += @($userPath -split ';' | Where-Object { $_ }) }

    $env:Path = ($all -join ';')
}

function Set-UserEnvironmentVariable {
    param([string]$Name, [string]$Value)

    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::Process)
}

function Remove-UserEnvironmentVariable {
    param([string]$Name)

    try {
        [Environment]::SetEnvironmentVariable($Name, $null, [EnvironmentVariableTarget]::User)
        [Environment]::SetEnvironmentVariable($Name, $null, [EnvironmentVariableTarget]::Process)
    }
    catch {
        Write-Warn "Could not remove environment variable '$Name': $($_.Exception.Message)"
    }
}

function Add-UserPathVariable {
    param([string[]]$Paths)

    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $entries  = @()
    if ($userPath) { $entries = @($userPath -split ';' | Where-Object { $_ }) }

    $normalizedNewPaths = @($Paths | ForEach-Object { $_.TrimEnd('\') })

    # Remove duplicates
    $entries = @($entries | Where-Object { $normalizedNewPaths -notcontains $_.TrimEnd('\') })

    # Prepend new paths
    $entries = @($normalizedNewPaths + $entries)

    $newPath = ($entries -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::User)

    Refresh-ProcessPath
}

function Remove-ManagedEnvironmentVariables {
    param([string]$InstallRoot, [switch]$CleanAll)

    try {
        $sparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', [EnvironmentVariableTarget]::User)

        if ([string]::IsNullOrWhiteSpace($sparkHome)) {
            Write-Info 'User SPARK_HOME is not set. Skipping SPARK_HOME removal.'
        }
        else {
            Remove-UserEnvironmentVariable -Name 'SPARK_HOME'
            Write-Info 'Removed user SPARK_HOME.'
        }

        foreach ($name in @('JAVA_HOME', 'HADOOP_HOME')) {
            $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::User)

            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Info "User $name is not set. Skipping removal."
                continue
            }

            if ($CleanAll -or (Test-PathPrefix -Path $value -Prefix $InstallRoot)) {
                Remove-UserEnvironmentVariable -Name $name
                Write-Info "Removed user $name."
            }
        }
    }
    catch {
        Write-Warn "Could not clean managed environment variables: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# Extraction Helper
# ------------------------------------------------------------------
function Expand-ZipToManagedFolder {
    param(
        [string]$ZipPath,
        [string]$DestinationRoot,
        [string]$TargetFolderName
    )

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    $tempDir = Join-Path $DestinationRoot (".tmp_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Write-Info "Extracting archive: $(Split-Path $ZipPath -Leaf)"
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $tempDir -Force

        $items = @(Get-ChildItem -LiteralPath $tempDir -Force)
        $sourceDir = $null

        if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
            $sourceDir = $items[0].FullName
        }
        elseif (Test-Path -LiteralPath (Join-Path $tempDir 'bin')) {
            $sourceDir = $tempDir
        }
        else {
            $withBin = @($items | Where-Object { $_.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $_.FullName 'bin')) })
            $sourceDir = if ($withBin.Count -ge 1) { $withBin[0].FullName } else { $tempDir }
        }

        $targetPath = Join-Path $DestinationRoot $TargetFolderName
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
        }

        Move-Item -LiteralPath $sourceDir -Destination $targetPath -Force
        return $targetPath
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==================================================================
# MAIN EXECUTION PIPELINE
# ==================================================================

Write-Step 'Step 1: Detect local source packages'

Write-Info "Current User             : $env:USERNAME"
Write-Info "Java source directory   : $_javaSrcDir"
Write-Info "Hadoop source directory : $_hadoopSrcDir"
Write-Info "Spark source directory  : $_sparkSrcDir"
Write-Info "Managed install root    : $InstallRoot"

$javaPackages   = @(Get-ZipPackages -Path $_javaSrcDir   -Prefix 'jdk')
$hadoopPackages = @(Get-ZipPackages -Path $_hadoopSrcDir -Prefix 'hadoop')
$sparkPackages  = @(Get-ZipPackages -Path $_sparkSrcDir  -Prefix 'spark')

Write-Host ''
Write-Info ("JDK packages found    : {0}" -f $javaPackages.Count)
$javaPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

Write-Info ("Hadoop packages found : {0}" -f $hadoopPackages.Count)
$hadoopPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

Write-Info ("Spark packages found  : {0}" -f $sparkPackages.Count)
$sparkPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

if ($sparkPackages.Count -eq 0) {
    Write-Err "No Spark zip packages detected in '$_sparkSrcDir'."
    Write-Err 'Expected file name format: spark-x.x.x.zip'
    exit 1
}

Write-Step 'Step 2: Select Spark version and validate dependencies'

$selectedSpark = $null
$targetVersionPattern = '^\d+(\.\d+){1,3}$'

if (-not [string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
    $TargetSparkVersion = $TargetSparkVersion.Trim()

    if ($TargetSparkVersion -notmatch $targetVersionPattern) {
        Write-Err "Invalid -TargetSparkVersion '$TargetSparkVersion'."
        exit 1
    }

    $selectedSpark = @($sparkPackages | Where-Object { $_.Version -eq $TargetSparkVersion }) | Select-Object -First 1

    if (-not $selectedSpark) {
        Write-Err "Spark version '$TargetSparkVersion' was not found in '$_sparkSrcDir'."
        exit 1
    }
}
else {
    $selectedSpark = Select-SparkPackage -SparkPackages $sparkPackages
    if (-not $selectedSpark) {
        Write-Info 'No Spark version selected. Exiting.'
        exit 0
    }
}

Write-Info ("Selected Spark version : {0}" -f $selectedSpark.Version)

$dependencyRule = Get-SparkDependencyRule -SparkVersion $selectedSpark.Version
if (-not $dependencyRule) {
    Write-Err ("No dependency rule found for Spark {0}. Update `$SparkDependencyMap." -f $selectedSpark.Version)
    exit 1
}

$selectedJava   = Select-EligibleJava   -JavaPackages $javaPackages     -RequiredMajors $dependencyRule.JavaMajorVersions
$selectedHadoop = Select-EligibleHadoop -HadoopPackages $hadoopPackages -RequiredPrefixes $dependencyRule.HadoopVersionPrefixes

if (-not $selectedJava -or -not $selectedHadoop) {
    Write-Err "Dependency validation failed for Spark $($selectedSpark.Version):"
    if (-not $selectedJava)   { Write-Err "  - Missing JDK Major Version: $($dependencyRule.JavaMajorVersions -join ', ')" }
    if (-not $selectedHadoop) { Write-Err "  - Missing Hadoop Version Prefix: $($dependencyRule.HadoopVersionPrefixes -join ', ')" }
    exit 1
}

Write-Ok ("Matched JDK    : {0} ({1})" -f $selectedJava.Version, $selectedJava.Name)
Write-Ok ("Matched Hadoop : {0} ({1})" -f $selectedHadoop.Version, $selectedHadoop.Name)

Write-Step 'Step 3: Cleanup previous managed user installations'

Backup-UserEnvironment -InstallRoot $InstallRoot
Remove-ManagedEnvironmentVariables -InstallRoot $InstallRoot -CleanAll:$CleanAllRelatedUserVariables

Write-Step 'Step 4: Unpack binaries into managed root'

$javaInstallDir   = Expand-ZipToManagedFolder -ZipPath $selectedJava.FullPath   -DestinationRoot $InstallRoot -TargetFolderName "jdk-$($selectedJava.Version)"
$hadoopInstallDir = Expand-ZipToManagedFolder -ZipPath $selectedHadoop.FullPath -DestinationRoot $InstallRoot -TargetFolderName "hadoop-$($selectedHadoop.Version)"
$sparkInstallDir  = Expand-ZipToManagedFolder -ZipPath $selectedSpark.FullPath  -DestinationRoot $InstallRoot -TargetFolderName "spark-$($selectedSpark.Version)"

# Security & Execution Check: Validate Hadoop winutils.exe
$winutilsPath = Join-Path $hadoopInstallDir "bin\winutils.exe"
if (-not (Test-Path -LiteralPath $winutilsPath)) {
    Write-Warn "Hadoop winutils.exe missing at '$winutilsPath'."
    Write-Warn "Spark local operations on Windows require winutils.exe in %HADOOP_HOME%\bin."
}

Write-Step 'Step 5: Configure User environment scope'

Set-UserEnvironmentVariable -Name 'JAVA_HOME'   -Value $javaInstallDir
Set-UserEnvironmentVariable -Name 'HADOOP_HOME' -Value $hadoopInstallDir
Set-UserEnvironmentVariable -Name 'SPARK_HOME'  -Value $sparkInstallDir

$binPathsToAdd = @(
    (Join-Path $javaInstallDir 'bin'),
    (Join-Path $hadoopInstallDir 'bin'),
    (Join-Path $sparkInstallDir 'bin')
)
Add-UserPathVariable -Paths $binPathsToAdd

# Pre-create Hive local scratch directory with Modify permissions for driver execution
$hiveTmpPath = "C:\tmp\hive"
if (-not (Test-Path $hiveTmpPath)) {
    New-Item -Path $hiveTmpPath -ItemType Directory -Force | Out-Null
}

Write-Step 'Installation Complete'
Write-Ok "Spark $($selectedSpark.Version) installed successfully for user $env:USERNAME."
Write-Ok "JAVA_HOME   = $javaInstallDir"
Write-Ok "HADOOP_HOME = $hadoopInstallDir"
Write-Ok "SPARK_HOME  = $sparkInstallDir"