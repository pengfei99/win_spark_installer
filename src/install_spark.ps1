<#
.SYNOPSIS
    Multi-User Windows Server - Local Apache Spark Installation & Isolation Script.

.DESCRIPTION
    1. This script scans local zip packages for JDK, Hadoop, and Spark.
    2. Validates Spark installation required dependencies, and offers user a choice to select which Spark version to install.
    3. If user chooses a version which is different from the current Spark version, it cleans previous Spark installations, and
       user environment variables.
    4. After clean, starts a new fresh Spark installation: installs binary, adds user environment variables.

.NOTES
    Expected source zip names:
        jdk-<version>.zip e.g. jdk-17.0.18.zip
        hadoop-<version>.zip e.g. hadoop-3.4.3.zip (the hadoop.zip is provided by DS team, the share/doc has been removed)
        spark-<version>.zip e.g. spark-4.1.3.zip

    The script installs into a managed directory, by default:
        C:\Users\<user>\AppData\Local\installed-spark

    It only removes managed directories under that install root by default.
#>

# Script Configuration
[CmdletBinding()]
param(
    [string]$_toolsSrcDir,
    [string]$_javaSrcDir,
    [string]$_hadoopSrcDir,
    [string]$_sparkSrcDir,
    [string]$InstallRoot,

    # If specified, also removes user JAVA_HOME/HADOOP_HOME even if they do not point under $InstallRoot.
    [switch]$CleanAllRelatedUserVariables,

    # If null or empty, interactive Spark selection is used.
    # If valid, example: 3.5.7 or 4.1.3, skip interactive Spark selection.
    [AllowNull()]
    [AllowEmptyString()]
    [string]$TargetSparkVersion = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------
# Determine default source file paths
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($_toolsSrcDir)) {
    $_toolsSrcDir = Join-Path $PSScriptRoot 'tools'
}

if ([string]::IsNullOrWhiteSpace($_javaSrcDir)) {
    $_javaSrcDir = Join-Path $_toolsSrcDir 'java'
}

if ([string]::IsNullOrWhiteSpace($_hadoopSrcDir)) {
    $_hadoopSrcDir = Join-Path $_toolsSrcDir 'hadoop'
}

if ([string]::IsNullOrWhiteSpace($_sparkSrcDir)) {
    $_sparkSrcDir = Join-Path $_toolsSrcDir 'spark'
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'installed-spark'
}

# ------------------------------------------------------------------
# Dependency rules
# ------------------------------------------------------------------
# Edit this map if your required JDK/Hadoop combinations are different.
#
# HadoopVersionPrefixes uses prefix matching:
#   '3.3' matches 3.3.6
#   '3.4' matches 3.4.3
#
# JavaMajorVersions matches the JDK major version:
#   jdk-11.0.30.zip -> major version 11
#   jdk-17.0.18.zip -> major version 17
#   jdk-21.0.10.zip -> major version 21
# ------------------------------------------------------------------
$SparkDependencyMap = @{
    '3.5.9' = @{ JavaMajorVersions = @('11'); HadoopVersionPrefixes = @('3.3') }
    '4.1.2' = @{ JavaMajorVersions = @('17'); HadoopVersionPrefixes = @('3.4') }
    '4.2.0' = @{ JavaMajorVersions = @('17', '21'); HadoopVersionPrefixes = @('3.5') }

    # Fallback rules
    '3.5' = @{ JavaMajorVersions = @('11'); HadoopVersionPrefixes = @('3.3') }
    '4'   = @{ JavaMajorVersions = @('17'); HadoopVersionPrefixes = @('3.4') }
    '3'   = @{ JavaMajorVersions = @('11', '17'); HadoopVersionPrefixes = @('3.3') }
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
# Get 7-Zip path helper
# ------------------------------------------------------------------
function Get-SevenZipPath {
    $commands = @('7z.exe', '7za.exe')
    foreach ($command in $commands) {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }

    # Fallback paths for 7-Zip
    $possiblePaths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:ChocolateyInstall\bin\7z.exe"
    )
    foreach ($path in $possiblePaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    Write-Err "7-Zip not found. Continuing with fallback extraction methods."

    return $null
}

# ------------------------------------------------------------------
# Version helpers
# ------------------------------------------------------------------
function ConvertTo-ComparableVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return [Version]::new(0, 0, 0, 0) }

    # Strip BOM, leading/trailing whitespace, and non-numeric suffixes (e.g. -SNAPSHOT)
    $cleaned = $Version.Trim().TrimStart([char]0xFEFF) -replace '[^0-9\.].*$', ''
    $parts = @($cleaned -split '\.' | ForEach-Object {
        $parsed = 0
        if ([int]::TryParse($_, [ref]$parsed)) { $parsed } else { 0 }
    })
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
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Prefix)) { return $false }

    $normalizedPath = $Path.TrimEnd([char]'\')
    $normalizedPrefix = $Prefix.TrimEnd([char]'\')

    return (
        $normalizedPath.Equals($normalizedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith("$normalizedPrefix\", [StringComparison]::OrdinalIgnoreCase)
    )
}

# ------------------------------------------------------------------
# Package discovery
# ------------------------------------------------------------------
function Get-ZipPackages {
    param([string]$Path, [string]$Prefix)
    $packages = @()

    if (-not (Test-Path -LiteralPath $Path)) { return $packages }

    $pattern = "^{0}-(?<version>\d+(?:\.\d+)*)\.zip$" -f [regex]::Escape($Prefix)

    Get-ChildItem -LiteralPath $Path -File -Filter "$Prefix-*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match $pattern) {
            $version = $Matches.version
            $parts = $version -split '\.'
            $major = $parts[0]

            # Fixed syntax for PowerShell 5.1 compatibility
            if ($parts.Count -ge 2) {
                $majorMinor = "$( $parts[0] ).$( $parts[1] )"
            } else {
                $majorMinor = $major
            }

            $packages += [PSCustomObject]@{
                Name       = $_.Name
                FullPath   = $_.FullName
                Version    = $version
                Major      = $major
                MajorMinor = $majorMinor
            }
        }
    }

    return @($packages | Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true })
}

function Get-SparkDependencyRule {
    param([string]$SparkVersion)
    $parts = $SparkVersion -split '\.'
    $major = $parts[0]

    if ($parts.Count -ge 2) {
        $majorMinor = "$( $parts[0] ).$( $parts[1] )"
    } else {
        $majorMinor = $major
    }

    foreach ($key in @($SparkVersion, $majorMinor, $major)) {
        if ($SparkDependencyMap.ContainsKey($key)) { return $SparkDependencyMap[$key] }
    }
    return $null
}

function Select-EligibleJava {
    param($JavaPackages, [string[]]$RequiredMajors)
    $eligible = @($JavaPackages | Where-Object { $RequiredMajors -contains $_.Major } | Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true })

    # Fixed 'return if' parsing error
    if ($eligible.Count -eq 0) {
        return $null
    } else {
        return $eligible[0]
    }
}

function Select-EligibleHadoop {
    param($HadoopPackages, [string[]]$RequiredPrefixes)
    $eligible = @($HadoopPackages | Where-Object {
        $pkg = $_
        @($RequiredPrefixes | Where-Object { Test-VersionPrefix -Version $pkg.Version -Prefix $_ }).Count -gt 0
    } | Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true })

    # Fixed 'return if' parsing error
    if ($eligible.Count -eq 0) {
        return $null
    } else {
        return $eligible[0]
    }
}

# ------------------------------------------------------------------
# Interactive helpers
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

function Confirm-Choice {
    param([string]$Message, [string]$Default = 'N')

    if ($Default -eq 'Y') {
        $suffix = '[Y/n]'
    } else {
        $suffix = '[y/N]'
    }

    while ($true) {
        $answer = Read-Host "$Message $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }

        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Warn 'Please answer y or n.'
    }
}

# ------------------------------------------------------------------
# Installed Spark detection
# ------------------------------------------------------------------
function Test-SparkHome {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $submitCmd = Join-Path (Join-Path $Path 'bin') 'spark-submit.cmd'
    $submitSh = Join-Path (Join-Path $Path 'bin') 'spark-submit'
    return (Test-Path -LiteralPath $submitCmd) -or (Test-Path -LiteralPath $submitSh)
}

function Get-InstalledSpark {
    param([string]$InstallRoot)
    $candidates = @()

    if ($env:SPARK_HOME) { $candidates += $env:SPARK_HOME }
    $userSparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
    if ($userSparkHome) { $candidates += $userSparkHome }

    if (Test-Path -LiteralPath $InstallRoot) {
        $candidates += @(Get-ChildItem -LiteralPath $InstallRoot -Directory -Filter 'spark-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }

    $candidates = @($candidates | Select-Object -Unique | Where-Object { $_ })
    $found = @()

    foreach ($candidate in $candidates) {
        if (Test-SparkHome -Path $candidate) {
            $version = $null
            $leaf = Split-Path $candidate -Leaf

            if ($leaf -match '^spark-(?<v>\d+(?:\.\d+)*)') {
                $version = $Matches.v
            } else {
                $versionFile = Join-Path $candidate 'VERSION'
                if (Test-Path -LiteralPath $versionFile) {
                    $version = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
                }
            }

            $found += [PSCustomObject]@{ Path = $candidate; Version = $version }
        }
    }

    if ($found.Count -eq 0) { return $null }
    return @($found | Sort-Object -Property @{ Expression = { if ($_.Version) { ConvertTo-ComparableVersion $_.Version } else { ConvertTo-ComparableVersion '0' } }; Descending = $true })[0]
}

# ------------------------------------------------------------------
# Environment helpers
# ------------------------------------------------------------------
function Backup-UserEnvironment {
    param([string]$InstallRoot)
    $backupDir = Join-Path $InstallRoot 'env-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $fileName = "user-env-{0}-{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupFile = Join-Path $backupDir $fileName

    $lines = [Environment]::GetEnvironmentVariables('User').GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value } | Sort-Object
    $lines | Set-Content -LiteralPath $backupFile -Encoding UTF8
    Write-Info "User environment backed up to: $backupFile"
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    # Start from the current process PATH to preserve any process-injected entries
    # (e.g. shell profile appends, CI runner tool paths).
    $currentEntries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $machineEntries = @($machinePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $userEntries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Combine machine + user as the authoritative source, then add any process-only entries
    $known = @{}
    foreach ($entry in ($machineEntries + $userEntries)) { $known[$entry.TrimEnd([char]'\')] = $true }

    $processOnly = @($currentEntries | Where-Object { -not $known.ContainsKey($_.TrimEnd([char]'\')) })
    $env:Path = ($machineEntries + $userEntries + $processOnly) -join ';'
}

function Set-UserEnvironmentVariable {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Remove-UserEnvironmentVariable {
    param([string]$Name)
    try {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    } catch {
        Write-Warn "Could not remove environment variable '$Name': $($_.Exception.Message)"
    }
}

function Add-UserPathVariable {
    param([string[]]$Paths)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    if ($userPath) {
        $entries = @($userPath -split ';' | Where-Object { $_ })
    } else {
        $entries = @()
    }

    $normalizedNewPaths = @($Paths | ForEach-Object { $_.TrimEnd([char]'\') })
    $entries = @($entries | Where-Object { $normalizedNewPaths -notcontains $_.TrimEnd([char]'\') })
    $entries = @($normalizedNewPaths + $entries)

    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    Refresh-ProcessPath
}

function Remove-PathVariablePrefix {
    param([string]$Prefix)
    try {
        if ([string]::IsNullOrWhiteSpace($Prefix)) { return }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ([string]::IsNullOrWhiteSpace($userPath)) { return }

        $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $kept = @($entries | Where-Object { -not (Test-PathPrefix -Path $_ -Prefix $Prefix) })
        $newPath = ($kept -join ';')

        if ($newPath -ne $userPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    } catch {
        Write-Warn "Could not remove PATH entries by prefix: $($_.Exception.Message)"
    }
}

function Remove-PathVariableExact {
    param([string[]]$ExactPaths)
    try {
        if ($null -eq $ExactPaths -or @($ExactPaths).Count -eq 0) { return }

        $normalizedExact = @()
        foreach ($path in $ExactPaths) {
            if (-not [string]::IsNullOrWhiteSpace($path)) { $normalizedExact += $path.TrimEnd([char]'\') }
        }
        if ($normalizedExact.Count -eq 0) { return }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ([string]::IsNullOrWhiteSpace($userPath)) { return }

        $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $kept = @($entries | Where-Object { $normalizedExact -notcontains $_.TrimEnd([char]'\') })
        $newPath = ($kept -join ';')

        if ($newPath -ne $userPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    } catch {
        Write-Warn "Could not remove exact PATH entries: $($_.Exception.Message)"
    }
}

function Remove-ManagedEnvironmentVariables {
    param([string]$InstallRoot, [switch]$CleanAll)
    try {
        $sparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
        if ([string]::IsNullOrWhiteSpace($sparkHome)) {
            Write-Info 'User SPARK_HOME is not set. Skipping SPARK_HOME removal.'
        } else {
            Remove-UserEnvironmentVariable -Name 'SPARK_HOME'
            Write-Info 'Removed user SPARK_HOME.'
        }

        $hadoopConfDir = [Environment]::GetEnvironmentVariable('HADOOP_CONF_DIR', 'User')
        if (-not [string]::IsNullOrWhiteSpace($hadoopConfDir)) {
            if ($CleanAll -or (Test-PathPrefix -Path $hadoopConfDir -Prefix $InstallRoot)) {
                Remove-UserEnvironmentVariable -Name 'HADOOP_CONF_DIR'
                Write-Info 'Removed user HADOOP_CONF_DIR.'
            }
        }

        foreach ($name in @('JAVA_HOME', 'HADOOP_HOME')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'User')
            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Info "User $name is not set. Skipping removal."
                continue
            }
            if ($CleanAll -or (Test-PathPrefix -Path $value -Prefix $InstallRoot)) {
                Remove-UserEnvironmentVariable -Name $name
                Write-Info "Removed user $name."
            }
        }
    } catch {
        Write-Warn "Could not clean managed environment variables: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# Cleanup helpers
# ------------------------------------------------------------------
function Remove-ManagedInstallations {
    param([string]$InstallRoot)
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return }

    $managedDirs = @(Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(spark|jdk|hadoop)-' })

    foreach ($dir in $managedDirs) {
        Write-Info "Removing managed installation directory: $($dir.FullName)"
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            Write-Warn "Could not delete '$($dir.FullName)'. A file is likely open in another process."
            Write-Warn "Detailed Error: $($_.Exception.Message)"
        } catch {
            Write-Err "An unexpected error occurred while deleting $($dir.FullName): $($_.Exception.Message)"
        }
    }

    # Also clean up leftover .tmp_* staging directories from crashed runs.
    $tmpDirs = @(Get-ChildItem -LiteralPath $InstallRoot -Directory -Filter '.tmp_*' -ErrorAction SilentlyContinue)
    foreach ($tmpDir in $tmpDirs) {
        Write-Info "Removing leftover temp directory: $($tmpDir.FullName)"
        try {
            Remove-Item -LiteralPath $tmpDir.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warn "Could not delete '$($tmpDir.FullName)': $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------
# Installation helper (unzip the source file to the target folder)
# ------------------------------------------------------------------
function Expand-ZipToManagedFolder {
    param([string]$ZipPath, [string]$DestinationRoot, [string]$TargetFolderName)

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    # Use a short temp directory under the install root.
    # This avoids long %TEMP% paths and makes cleanup easier.
    $tempDirName = ".tmp_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tempDir = Join-Path $DestinationRoot $tempDirName
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $extracted = $false

        # 1) Try built-in tar.exe
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if ($tar) {
            Write-Info "Attempting extraction with tar.exe..."
            & $tar.Source -xf $ZipPath -C $tempDir 2>$null

            if ($LASTEXITCODE -eq 0 -and @(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0) {
                $extracted = $true
                Write-Ok "Extraction succeeded using tar.exe."
            } else {
                Write-Warn "tar.exe did not extract successfully. Trying next method."
                Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # 2) Try 7-Zip if available
        if (-not $extracted) {
            $sevenZip = Get-SevenZipPath
            if ($sevenZip) {
                Write-Info "Attempting extraction with 7-Zip: $sevenZip"
                & $sevenZip x -y "-o$tempDir" $ZipPath 2>$null

                if ($LASTEXITCODE -eq 0 -and @(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0) {
                    $extracted = $true
                    Write-Ok "Extraction succeeded using 7-Zip."
                } else {
                    Write-Warn "7-Zip did not extract successfully. Trying next method."
                    Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 3) Try .NET ZipArchive
        #    This manually skips directory-only entries, which helps with
        #    zip files that contain empty folder entries.
        # --------------------------------------------------------------
        if (-not $extracted) {
            try {
                Write-Info "Attempting extraction with .NET ZipArchive."
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

                try {
                    foreach ($entry in $zip.Entries) {
                        # Sanitize path: remove leading slashes and normalize to Windows backslashes
                        $relativePath = $entry.FullName -replace '^[/\\]+', '' -replace '/', '\'
                        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }

                        # Protection against directory traversal
                        if ($relativePath -match '\.\.') {
                            Write-Warn "Skipping potentially unsafe path: $($entry.FullName)"
                            continue
                        }

                        $targetPath = Join-Path $tempDir $relativePath
                        $isDirectory = [string]::IsNullOrEmpty($entry.Name) -or $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')

                        if ($isDirectory) {
                            if (-not (Test-Path -LiteralPath $targetPath)) {
                                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                            }
                        } else {
                            $parent = Split-Path $targetPath -Parent
                            if (-not (Test-Path -LiteralPath $parent)) {
                                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                            }
                            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
                        }
                    }

                    if (@(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0) {
                        $extracted = $true
                        Write-Ok "Extraction succeeded using .NET ZipArchive."
                    } else {
                        Write-Warn ".NET ZipArchive did not extract any files. Trying next method."
                        Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } finally {
                    if ($zip) { $zip.Dispose() }
                }
            } catch {
                Write-Warn ".NET ZipArchive extraction failed: $($_.Exception.Message). Trying next method."
                Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # 4) Last resort: Expand-Archive
        if (-not $extracted) {
            Write-Info "Attempting extraction with Expand-Archive as last resort."
            try {
                Expand-Archive -LiteralPath $ZipPath -DestinationPath $tempDir -Force -ErrorAction Stop
                if (@(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0) {
                    $extracted = $true
                    Write-Ok "Extraction succeeded using Expand-Archive."
                } else {
                    throw "Expand-Archive completed but the destination folder is empty."
                }
            } catch {
                throw "All extraction methods failed. Last resort (Expand-Archive) error: $($_.Exception.Message)"
            }
        }

        # Normalize extracted folder layout
        $items = @(Get-ChildItem -LiteralPath $tempDir -Force)
        if ($items.Count -eq 0) { throw "The archive '$ZipPath' appears to be completely empty." }

        $sourceDir = $tempDir # Default fallback
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
            $sourceDir = $items[0].FullName
        } else {
            $binFolders = @(Get-ChildItem -LiteralPath $tempDir -Filter 'bin' -Directory -Recurse -Depth 2 -Force)
            if ($binFolders.Count -eq 1) {
                $sourceDir = Split-Path $binFolders[0].FullName -Parent
            } elseif ($binFolders.Count -gt 1) {
                # Try to pick the bin folder containing expected executables based on package type.
                $expectedExe = $null
                if ($TargetFolderName -match '^jdk-')     { $expectedExe = 'java.exe' }
                elseif ($TargetFolderName -match '^hadoop-') { $expectedExe = 'hadoop.cmd' }
                elseif ($TargetFolderName -match '^spark-')  { $expectedExe = 'spark-submit.cmd' }

                $bestBin = $null
                if ($expectedExe) {
                    foreach ($binDir in $binFolders) {
                        if (Test-Path -LiteralPath (Join-Path $binDir.FullName $expectedExe)) {
                            $bestBin = $binDir
                            break
                        }
                    }
                }
                if (-not $bestBin) { $bestBin = $binFolders[0] }
                $sourceDir = Split-Path $bestBin.FullName -Parent
            }
        }

        $targetPath = Join-Path $DestinationRoot $TargetFolderName
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
        }

        Move-Item -LiteralPath $sourceDir -Destination $targetPath -Force
        Write-Info "Successfully extracted and moved to: $targetPath"
        return $targetPath
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------------
# Main script
# ------------------------------------------------------------------
Write-Step 'Step 1: Detect local source packages'

Write-Info "Java source directory   : $_javaSrcDir"
Write-Info "Hadoop source directory : $_hadoopSrcDir"
Write-Info "Spark source directory  : $_sparkSrcDir"
Write-Info "Managed install root    : $InstallRoot"

$javaPackages   = @(Get-ZipPackages -Path $_javaSrcDir   -Prefix 'jdk')
$hadoopPackages = @(Get-ZipPackages -Path $_hadoopSrcDir -Prefix 'hadoop')
$sparkPackages  = @(Get-ZipPackages -Path $_sparkSrcDir  -Prefix 'spark')

Write-Host ''
Write-Info ("JDK packages found: {0}" -f $javaPackages.Count)
$javaPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

Write-Info ("Hadoop packages found: {0}" -f $hadoopPackages.Count)
$hadoopPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

Write-Info ("Spark packages found: {0}" -f $sparkPackages.Count)
$sparkPackages | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name) }

if ($sparkPackages.Count -eq 0) {
    Write-Err "No Spark zip packages detected in '$_sparkSrcDir'."
    Write-Err 'Expected file name format: spark-x.x.x.zip'
    exit 1
}

# ------------------------------------------------------------------
# Step 2: Select Spark version
# ------------------------------------------------------------------
Write-Step 'Step 2: Select Spark version'

$selectedSpark = $null
$targetVersionPattern = '^\d+(\.\d+){0,3}$'

if (-not [string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
    $TargetSparkVersion = $TargetSparkVersion.Trim()

    if ($TargetSparkVersion -notmatch $targetVersionPattern) {
        Write-Err "Invalid -TargetSparkVersion '$TargetSparkVersion'."
        Write-Err 'Expected version format: 3.5.7, 4.1.3, 3.5, 4.1, etc.'
        exit 1
    }

    Write-Info "Target Spark version supplied by parameter: $TargetSparkVersion"
    # Prefer exact match, otherwise resolve a prefix (e.g. '4' or '3.5') to the highest matching package.
    $selectedSpark = @($sparkPackages | Where-Object { $_.Version -eq $TargetSparkVersion }) | Select-Object -First 1
    if (-not $selectedSpark) {
        $selectedSpark = @($sparkPackages | Where-Object { Test-VersionPrefix -Version $_.Version -Prefix $TargetSparkVersion } | Sort-Object -Property @{ Expression = { ConvertTo-ComparableVersion $_.Version }; Descending = $true }) | Select-Object -First 1
    }

    if (-not $selectedSpark) {
        Write-Err "Spark version '$TargetSparkVersion' was not found in '$_sparkSrcDir'."
        Write-Err 'Available detected Spark versions:'
        $sparkPackages | ForEach-Object { Write-Host "  - $( $_.Version )" -ForegroundColor Red }
        exit 1
    }
    Write-Info "Automatically selected Spark version: $( $selectedSpark.Version )"
} else {
    $selectedSpark = Select-SparkPackage -SparkPackages $sparkPackages
    if (-not $selectedSpark) {
        Write-Info 'No Spark version selected. Exiting.'
        exit 0
    }
}

Write-Info ("Selected Spark version: {0}" -f $selectedSpark.Version)

$dependencyRule = Get-SparkDependencyRule -SparkVersion $selectedSpark.Version
if (-not $dependencyRule) {
    Write-Err ("No dependency rule found for Spark {0}." -f $selectedSpark.Version)
    Write-Err 'Edit $SparkDependencyMap in this script to add it.'
    exit 1
}

$selectedJava = Select-EligibleJava -JavaPackages $javaPackages -RequiredMajors $dependencyRule.JavaMajorVersions
$selectedHadoop = Select-EligibleHadoop -HadoopPackages $hadoopPackages -RequiredPrefixes $dependencyRule.HadoopVersionPrefixes

$missing = @()
if (-not $selectedJava) {
    $missing += ('Required JDK major version(s) {0} not found in {1}' -f ($dependencyRule.JavaMajorVersions -join ', '), $_javaSrcDir)
}
if (-not $selectedHadoop) {
    $missing += ('Required Hadoop version prefix(es) {0} not found in {1}' -f ($dependencyRule.HadoopVersionPrefixes -join ', '), $_hadoopSrcDir)
}

if ($missing.Count -gt 0) {
    Write-Err ("Missing required packages for Spark {0}:" -f $selectedSpark.Version)
    foreach ($message in $missing) { Write-Host "  - $message" -ForegroundColor Red }
    exit 1
}

Write-Info ("Selected JDK    : {0} ({1})" -f $selectedJava.Version, $selectedJava.Name)
Write-Info ("Selected Hadoop : {0} ({1})" -f $selectedHadoop.Version, $selectedHadoop.Name)

# ------------------------------------------------------------------
# Step 3: Detect existing Spark installation
# ------------------------------------------------------------------
Write-Step 'Step 3: Check existing Spark installation'
$installedSpark = Get-InstalledSpark -InstallRoot $InstallRoot

if ($installedSpark) {
    Write-Info "Existing Spark path    : $( $installedSpark.Path )"
    Write-Info "Existing Spark version : $( $installedSpark.Version )"

    if (-not [string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
        if ($installedSpark.Version -eq $selectedSpark.Version) {
            Write-Info "Spark $( $selectedSpark.Version ) is already installed. Proceeding with reinstall (headless mode)."
        } else {
            Write-Info "Replacing Spark $( $installedSpark.Version ) with $( $selectedSpark.Version ) (headless mode)."
        }
    } else {
        if ($installedSpark.Version -eq $selectedSpark.Version) {
            $reinstall = Confirm-Choice -Message "Spark $( $selectedSpark.Version ) is already installed. Do you want to reinstall it?" -Default 'N'
            if (-not $reinstall) { Write-Info 'Reinstallation cancelled. No changes were made.'; exit 0 }
        } else {
            $replace = Confirm-Choice -Message "Installed Spark version is '$( $installedSpark.Version )', selected version is '$( $selectedSpark.Version )'. Replace existing installation?" -Default 'Y'
            if (-not $replace) { Write-Info 'Installation cancelled. No changes were made.'; exit 0 }
        }
    }
} else {
    Write-Info 'No existing Spark installation was detected in the managed install root.'
    if ([string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
        $continue = Confirm-Choice -Message "Install Spark $( $selectedSpark.Version ) now?" -Default 'Y'
        if (-not $continue) { Write-Info 'Installation cancelled.'; exit 0 }
    }
}

# Capture old user environment values before cleaning.
$oldJavaHome     = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
$oldHadoopHome   = [Environment]::GetEnvironmentVariable('HADOOP_HOME', 'User')
$oldHadoopConfDir = [Environment]::GetEnvironmentVariable('HADOOP_CONF_DIR', 'User')
$oldSparkHome    = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')

# Initialize variables to avoid StrictMode errors in the catch block if an exception occurs before they are assigned.
$javaHome = $null
$hadoopHome = $null
$sparkHome = $null

try {
    # ------------------------------------------------------------------
    # Step 4a: Clean previous installation and user environment
    # ------------------------------------------------------------------
    Write-Step 'Step 4a: Remove previous installation and clean user environment'
    Backup-UserEnvironment -InstallRoot $InstallRoot

    if ($installedSpark -and $installedSpark.Path -and (Test-Path -LiteralPath $installedSpark.Path)) {
        if (Test-PathPrefix -Path $installedSpark.Path -Prefix $InstallRoot) {
            Write-Info "Removing existing managed Spark directory: $( $installedSpark.Path )"
            Remove-Item -LiteralPath $installedSpark.Path -Recurse -Force
        } else {
            Write-Warn "Existing Spark directory is outside the managed install root: $( $installedSpark.Path )"
            if (Confirm-Choice -Message 'Remove this existing Spark directory too?' -Default 'N') {
                try {
                    Remove-Item -LiteralPath $installedSpark.Path -Recurse -Force
                    Write-Info "Removed external Spark directory: $( $installedSpark.Path )"
                } catch {
                    Write-Warn "Could not remove external Spark directory: $($_.Exception.Message)"
                }
            }
        }
    }

    foreach ($oldDir in @($oldJavaHome, $oldHadoopHome)) {
        if ($oldDir -and (Test-PathPrefix -Path $oldDir -Prefix $InstallRoot)) {
            Write-Info "Removing old managed dependency directory: $oldDir"
            Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove any remaining managed spark/jdk/hadoop directories.
    Remove-ManagedInstallations -InstallRoot $InstallRoot
    Remove-ManagedEnvironmentVariables -InstallRoot $InstallRoot -CleanAll:$CleanAllRelatedUserVariables
    Remove-PathVariablePrefix -Prefix $InstallRoot

    # Build exact path removals cleanly without overwriting the array.
    # Only remove %VAR%\bin literals when the variable is managed (points under $InstallRoot) or -CleanAllRelatedUserVariables is set.
    $exactPathRemovals = @()

    if ($CleanAllRelatedUserVariables) {
        $exactPathRemovals += '%JAVA_HOME%\bin', '%HADOOP_HOME%\bin', '%SPARK_HOME%\bin'
        if (-not [string]::IsNullOrWhiteSpace($oldSparkHome)) { $exactPathRemovals += Join-Path $oldSparkHome 'bin' }
        if (-not [string]::IsNullOrWhiteSpace($oldJavaHome)) { $exactPathRemovals += Join-Path $oldJavaHome 'bin' }
        if (-not [string]::IsNullOrWhiteSpace($oldHadoopHome)) { $exactPathRemovals += Join-Path $oldHadoopHome 'bin' }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($oldSparkHome) -and (Test-PathPrefix -Path $oldSparkHome -Prefix $InstallRoot)) {
            $exactPathRemovals += '%SPARK_HOME%\bin'
            $exactPathRemovals += Join-Path $oldSparkHome 'bin'
        }
        if (-not [string]::IsNullOrWhiteSpace($oldJavaHome) -and (Test-PathPrefix -Path $oldJavaHome -Prefix $InstallRoot)) {
            $exactPathRemovals += '%JAVA_HOME%\bin'
            $exactPathRemovals += Join-Path $oldJavaHome 'bin'
        }
        if (-not [string]::IsNullOrWhiteSpace($oldHadoopHome) -and (Test-PathPrefix -Path $oldHadoopHome -Prefix $InstallRoot)) {
            $exactPathRemovals += '%HADOOP_HOME%\bin'
            $exactPathRemovals += Join-Path $oldHadoopHome 'bin'
        }
    }

    # Final filter: remove null/empty values before calling Remove-PathVariableExact.
    $exactPathRemovals = @($exactPathRemovals | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    try {
        Remove-PathVariableExact -ExactPaths $exactPathRemovals
    } catch {
        Write-Warn "Could not clean exact user PATH entries: $($_.Exception.Message)"
    }

    Refresh-ProcessPath
    Write-Ok 'Previous managed installation and related user environment cleaned.'

    # ------------------------------------------------------------------
    # Step 4b: Install selected Spark, JDK, and Hadoop
    # ------------------------------------------------------------------
    Write-Step 'Step 4b: Install selected Spark version and dependencies'

    $javaHome = Expand-ZipToManagedFolder -ZipPath $selectedJava.FullPath -DestinationRoot $InstallRoot -TargetFolderName ("jdk-{0}" -f $selectedJava.Version)
    $hadoopHome = Expand-ZipToManagedFolder -ZipPath $selectedHadoop.FullPath -DestinationRoot $InstallRoot -TargetFolderName ("hadoop-{0}" -f $selectedHadoop.Version)
    $sparkHome = Expand-ZipToManagedFolder -ZipPath $selectedSpark.FullPath -DestinationRoot $InstallRoot -TargetFolderName ("spark-{0}" -f $selectedSpark.Version)

    $javaExe = Join-Path (Join-Path $javaHome 'bin') 'java.exe'
    if (-not (Test-Path -LiteralPath $javaExe)) {
        Write-Warn "java.exe was not found under '$javaHome'. The JDK zip layout may be unexpected."
    }

    $sparkSubmitCmd = Join-Path (Join-Path $sparkHome 'bin') 'spark-submit.cmd'
    $sparkSubmitSh = Join-Path (Join-Path $sparkHome 'bin') 'spark-submit'
    if (-not ((Test-Path -LiteralPath $sparkSubmitCmd) -or (Test-Path -LiteralPath $sparkSubmitSh))) {
        throw "spark-submit was not found under '$sparkHome'. The Spark zip layout may be unexpected."
    }

    # ------------------------------------------------------------------
    # Step 4c: Set user environment variables
    # ------------------------------------------------------------------
    Write-Step 'Step 4c: Configure user environment variables'

    # set hadoop conf dir for spark cluster mode
    $hadoopConfDir = Join-Path $hadoopHome 'etc\hadoop'
    if (-not (Test-Path -LiteralPath $hadoopConfDir)) {
        throw "HADOOP_CONF_DIR '$hadoopConfDir' does not exist. The Hadoop zip layout may be unexpected."
    }

    Set-UserEnvironmentVariable -Name 'JAVA_HOME'       -Value $javaHome
    Set-UserEnvironmentVariable -Name 'HADOOP_HOME'     -Value $hadoopHome
    Set-UserEnvironmentVariable -Name 'HADOOP_CONF_DIR' -Value $hadoopConfDir
    Set-UserEnvironmentVariable -Name 'SPARK_HOME'      -Value $sparkHome

    Add-UserPathVariable -Paths @(
        "$javaHome\bin",
        "$hadoopHome\bin",
        "$sparkHome\bin"
    )

    Write-Ok 'Installation completed successfully.'

    Write-Host ''
    Write-Host 'Installed locations:' -ForegroundColor Cyan
    Write-Host "  JAVA_HOME   = $javaHome"
    Write-Host "  HADOOP_HOME = $hadoopHome"
    Write-Host "  SPARK_HOME  = $sparkHome"

    Write-Host ''
    Write-Host 'User environment variables were updated.' -ForegroundColor Yellow
    Write-Host 'Open a new PowerShell window before using spark-submit, spark-shell, or pyspark.' -ForegroundColor Yellow

} catch {
    Write-Err ("Installation failed: {0}" -f $_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-Err $_.ScriptStackTrace }

    # Rollback: restore old environment variables if they were set
    Write-Warn 'Attempting rollback of environment variables...'
    try {
        if (-not [string]::IsNullOrWhiteSpace($oldJavaHome)) {
            Set-UserEnvironmentVariable -Name 'JAVA_HOME' -Value $oldJavaHome
        }
        if (-not [string]::IsNullOrWhiteSpace($oldHadoopHome)) {
            Set-UserEnvironmentVariable -Name 'HADOOP_HOME' -Value $oldHadoopHome
        }
        if (-not [string]::IsNullOrWhiteSpace($oldHadoopConfDir)) {
            Set-UserEnvironmentVariable -Name 'HADOOP_CONF_DIR' -Value $oldHadoopConfDir
        }
        if (-not [string]::IsNullOrWhiteSpace($oldSparkHome)) {
            Set-UserEnvironmentVariable -Name 'SPARK_HOME' -Value $oldSparkHome
        }
        Refresh-ProcessPath
        Write-Info 'Environment variables restored from pre-installation snapshot.'
    } catch {
        Write-Warn "Could not restore environment variables: $($_.Exception.Message)"
    }

    # Clean up partially-extracted directories that may have been created
    foreach ($partialDir in @($javaHome, $hadoopHome, $sparkHome)) {
        if ($partialDir -and (Test-Path -LiteralPath $partialDir)) {
            try {
                Remove-Item -LiteralPath $partialDir -Recurse -Force -ErrorAction Stop
                Write-Info "Cleaned up partially-extracted directory: $partialDir"
            } catch {
                Write-Warn "Could not clean up '$partialDir': $($_.Exception.Message)"
            }
        }
    }

    exit 1
}