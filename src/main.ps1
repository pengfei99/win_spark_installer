<#
.SYNOPSIS
    Local Apache Spark installation script for Windows.

.DESCRIPTION
    This script scans local zip packages for JDK, Hadoop, and Spark.
    It asks the user which Spark version to install, validates required
    JDK/Hadoop zip packages, removes a previous managed installation,
    cleans user environment variables, installs the selected Spark version
    and dependencies, then configures user environment variables.

.NOTES
    Expected source zip names:
        jdk-<version>.zip
        hadoop-<version>.zip
        spark-<version>.zip

    The script installs into a managed directory, by default:
        C:\Users\pliu\Documents\tools\installed

    It only removes managed directories under that install root by default.
#>

# Script Configuration
[CmdletBinding()]
param(
    [string]$_javaSrcDir = 'C:\Users\pliu\Documents\tools\java',
    [string]$_hadoopSrcDir = 'C:\Users\pliu\Documents\tools\hadoop',
    [string]$_sparkSrcDir = 'C:\Users\pliu\Documents\tools\spark',
    [string]$InstallRoot = 'C:\Users\pliu\Documents\tools\installed',

    # If specified, also removes user JAVA_HOME/HADOOP_HOME even if they
    # do not point under $InstallRoot.
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
    '3.5.9' = @{
        JavaMajorVersions = @('11'); HadoopVersionPrefixes = @('3.3')
    }
    '4.1.2' = @{
        JavaMajorVersions = @('17'); HadoopVersionPrefixes = @('3.4')
    }
    '4.2.0' = @{
        JavaMajorVersions = @('17', '21'); HadoopVersionPrefixes = @('3.5')
    }

    # Fallback rules
    '3.5' = @{
        JavaMajorVersions = @('11'); HadoopVersionPrefixes = @('3.3')
    }
    '4' = @{
        JavaMajorVersions = @('17'); HadoopVersionPrefixes = @('3.4')
    }
    '3' = @{
        JavaMajorVersions = @('11', '17'); HadoopVersionPrefixes = @('3.3')
    }
}

# ------------------------------------------------------------------
# Console helpers
# ------------------------------------------------------------------
function Write-Info
{
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok
{
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn
{
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err
{
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Step
{
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Magenta
}
# ------------------------------------------------------------------
# get 7zip path helpers
# ------------------------------------------------------------------
function Get-SevenZipPath
{
    $commands = @('7z.exe', '7za.exe')

    foreach ($command in $commands)
    {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        if ($found)
        {
            return $found.Source
        }
    }

    Write-Err "This script requires 7z.exe to unzip the source files."

    return $null
}

# ------------------------------------------------------------------
# Version helpers
# ------------------------------------------------------------------
function ConvertTo-ComparableVersion
{
    param([string]$Version)

    if ( [string]::IsNullOrWhiteSpace($Version))
    {
        return [Version]::new(0, 0, 0, 0)
    }

    $parts = @($Version -split '\.' | ForEach-Object {
        [int]$_
    })

    if ($parts.Count -gt 4)
    {
        $parts = $parts[0..3]
    }

    while ($parts.Count -lt 4)
    {
        $parts += 0
    }

    return [Version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Test-VersionPrefix
{
    param(
        [string]$Version,
        [string]$Prefix
    )

    return ($Version -eq $Prefix) -or ($Version.StartsWith("$Prefix."))
}

function Test-PathPrefix
{
    param(
        [string]$Path,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Prefix))
    {
        return $false
    }

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
function Get-ZipPackages
{
    param(
        [string]$Path,
        [string]$Prefix
    )

    $packages = @()

    if (-not (Test-Path -LiteralPath $Path))
    {
        return $packages
    }

    $pattern = "^{0}-(?<version>\d+(?:\.\d+)*)\.zip$" -f [regex]::Escape($Prefix)

    Get-ChildItem -LiteralPath $Path -File -Filter "$Prefix-*.zip" -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Name -match $pattern)
                {
                    $version = $Matches.version
                    $parts = $version -split '\.'

                    $major = $parts[0]
                    $majorMinor = if ($parts.Count -ge 2)
                    {
                        "$( $parts[0] ).$( $parts[1] )"
                    }
                    else
                    {
                        $major
                    }

                    $packages += [PSCustomObject]@{
                        Name = $_.Name
                        FullPath = $_.FullName
                        Version = $version
                        Major = $major
                        MajorMinor = $majorMinor
                    }
                }
            }

    return @(
    $packages | Sort-Object -Property @{
        Expression = {
            ConvertTo-ComparableVersion $_.Version
        }
        Descending = $true
    }
    )
}

function Get-SparkDependencyRule
{
    param([string]$SparkVersion)

    $parts = $SparkVersion -split '\.'
    $major = $parts[0]

    $majorMinor = if ($parts.Count -ge 2)
    {
        "$( $parts[0] ).$( $parts[1] )"
    }
    else
    {
        $major
    }

    foreach ($key in @($SparkVersion, $majorMinor, $major))
    {
        if ( $SparkDependencyMap.ContainsKey($key))
        {
            return $SparkDependencyMap[$key]
        }
    }

    return $null
}

function Select-EligibleJava
{
    param(
        $JavaPackages,
        [string[]]$RequiredMajors
    )

    $eligible = @(
    $JavaPackages |
            Where-Object {
                $RequiredMajors -contains $_.Major
            } |
            Sort-Object -Property @{
                Expression = {
                    ConvertTo-ComparableVersion $_.Version
                }
                Descending = $true
            }
    )

    if ($eligible.Count -eq 0)
    {
        return $null
    }

    # Choose highest eligible version.
    return $eligible[0]
}

function Select-EligibleHadoop
{
    param(
        $HadoopPackages,
        [string[]]$RequiredPrefixes
    )

    $eligible = @(
    $HadoopPackages |
            Where-Object {
                $pkg = $_
                @($RequiredPrefixes | Where-Object {
                    Test-VersionPrefix -Version $pkg.Version -Prefix $_
                }).Count -gt 0
            } |
            Sort-Object -Property @{
                Expression = {
                    ConvertTo-ComparableVersion $_.Version
                }
                Descending = $true
            }
    )

    if ($eligible.Count -eq 0)
    {
        return $null
    }

    # Choose highest eligible version.
    return $eligible[0]
}

# ------------------------------------------------------------------
# Interactive helpers
# ------------------------------------------------------------------
function Select-SparkPackage
{
    param($SparkPackages)

    $packages = @($SparkPackages)

    Write-Host "`nAvailable Spark versions:" -ForegroundColor Cyan

    for ($i = 0; $i -lt $packages.Count; $i++) {
        Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $packages[$i].Version, $packages[$i].Name)
    }

    Write-Host '  [0] Exit'

    while ($true)
    {
        $choice = Read-Host 'Select a Spark version to install'

        if ($choice -eq '0')
        {
            return $null
        }

        $index = 0

        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $packages.Count)
        {
            return $packages[$index - 1]
        }

        Write-Warn 'Invalid selection. Enter a number from the list.'
    }
}

function Confirm-Choice
{
    param(
        [string]$Message,
        [string]$Default = 'N'
    )

    $suffix = if ($Default -eq 'Y')
    {
        '[Y/n]'
    }
    else
    {
        '[y/N]'
    }

    while ($true)
    {
        $answer = Read-Host "$Message $suffix"

        if ( [string]::IsNullOrWhiteSpace($answer))
        {
            $answer = $Default
        }

        if ($answer -match '^(y|yes)$')
        {
            return $true
        }

        if ($answer -match '^(n|no)$')
        {
            return $false
        }

        Write-Warn 'Please answer y or n.'
    }
}

# ------------------------------------------------------------------
# Installed Spark detection
# ------------------------------------------------------------------
function Test-SparkHome
{
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path))
    {
        return $false
    }

    $submitCmd = Join-Path (Join-Path $Path 'bin') 'spark-submit.cmd'
    $submitSh = Join-Path (Join-Path $Path 'bin') 'spark-submit'

    return (
    (Test-Path -LiteralPath $submitCmd) -or
            (Test-Path -LiteralPath $submitSh)
    )
}

function Get-InstalledSpark
{
    param([string]$InstallRoot)

    $candidates = @()

    if ($env:SPARK_HOME)
    {
        $candidates += $env:SPARK_HOME
    }

    $userSparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')
    if ($userSparkHome)
    {
        $candidates += $userSparkHome
    }

    if (Test-Path -LiteralPath $InstallRoot)
    {
        $candidates += @(
        Get-ChildItem -LiteralPath $InstallRoot -Directory -Filter 'spark-*' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        )
    }

    $candidates = @($candidates | Select-Object -Unique | Where-Object {
        $_
    })
    $found = @()

    foreach ($candidate in $candidates)
    {
        if (Test-SparkHome -Path $candidate)
        {
            $version = $null
            $leaf = Split-Path $candidate -Leaf

            if ($leaf -match '^spark-(?<v>\d+(?:\.\d+)*)')
            {
                $version = $Matches.v
            }
            else
            {
                $versionFile = Join-Path $candidate 'VERSION'
                if (Test-Path -LiteralPath $versionFile)
                {
                    $version = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
                }
            }

            $found += [PSCustomObject]@{
                Path = $candidate
                Version = $version
            }
        }
    }

    if ($found.Count -eq 0)
    {
        return $null
    }

    return @(
    $found | Sort-Object -Property @{
        Expression = {
            if ($_.Version)
            {
                ConvertTo-ComparableVersion $_.Version
            }
            else
            {
                ConvertTo-ComparableVersion '0'
            }
        }
        Descending = $true
    }
    )[0]
}

# ------------------------------------------------------------------
# Environment helpers
# ------------------------------------------------------------------
function Backup-UserEnvironment
{
    param([string]$InstallRoot)

    $backupDir = Join-Path $InstallRoot 'env-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $fileName = "user-env-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $backupFile = Join-Path $backupDir $fileName

    $lines = [Environment]::GetEnvironmentVariables('User').GetEnumerator() |
            ForEach-Object {
                "{0}={1}" -f $_.Key, $_.Value
            } |
            Sort-Object

    $lines | Set-Content -LiteralPath $backupFile -Encoding UTF8

    Write-Info "User environment backed up to: $backupFile"
}

function Refresh-ProcessPath
{
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $all = @()

    if ($machinePath)
    {
        $all += @($machinePath -split ';' | Where-Object {
            $_
        })
    }

    if ($userPath)
    {
        $all += @($userPath -split ';' | Where-Object {
            $_
        })
    }

    $env:Path = ($all -join ';')
}

function Set-UserEnvironmentVariable
{
    param(
        [string]$Name,
        [string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Remove-UserEnvironmentVariable
{
    param([string]$Name)

    try
    {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
    catch
    {
        Write-Warn "Could not remove environment variable '$Name': $( $_.Exception.Message )"
    }
}

function Add-UserPathVariable
{
    param([string[]]$Paths)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $entries = @()
    if ($userPath)
    {
        $entries = @($userPath -split ';' | Where-Object {
            $_
        })
    }

    $normalizedNewPaths = @($Paths | ForEach-Object {
        $_.TrimEnd([char]'\')
    })

    # Remove duplicates first.
    $entries = @(
    $entries | Where-Object {
        $normalizedNewPaths -notcontains $_.TrimEnd([char]'\')
    }
    )

    # Prepend new paths so the newly installed JDK/Hadoop/Spark take priority
    # in the user PATH.
    $entries = @($normalizedNewPaths + $entries)

    $newPath = ($entries -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')

    Refresh-ProcessPath
}

function Remove-PathVariablePrefix
{
    param([string]$Prefix)

    try
    {
        if ( [string]::IsNullOrWhiteSpace($Prefix))
        {
            return
        }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

        if ( [string]::IsNullOrWhiteSpace($userPath))
        {
            return
        }

        $entries = @(
        $userPath -split ';' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
        )

        $kept = @(
        $entries | Where-Object {
            -not (Test-PathPrefix -Path $_ -Prefix $Prefix)
        }
        )

        $newPath = ($kept -join ';')

        if ($newPath -ne $userPath)
        {
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        }
    }
    catch
    {
        Write-Warn "Could not remove PATH entries by prefix: $( $_.Exception.Message )"
    }
}

function Remove-PathVariableExact
{
    param([string[]]$ExactPaths)

    try
    {
        if ($null -eq $ExactPaths -or @($ExactPaths).Count -eq 0)
        {
            return
        }

        $normalizedExact = @()

        foreach ($path in $ExactPaths)
        {
            if (-not [string]::IsNullOrWhiteSpace($path))
            {
                $normalizedExact += $path.TrimEnd([char]'\')
            }
        }

        if ($normalizedExact.Count -eq 0)
        {
            return
        }

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

        if ( [string]::IsNullOrWhiteSpace($userPath))
        {
            return
        }

        $entries = @(
        $userPath -split ';' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
        )

        $kept = @(
        $entries | Where-Object {
            $entry = $_.TrimEnd([char]'\')
            $normalizedExact -notcontains $entry
        }
        )

        $newPath = ($kept -join ';')

        if ($newPath -ne $userPath)
        {
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        }
    }
    catch
    {
        Write-Warn "Could not remove exact PATH entries: $( $_.Exception.Message )"
    }
}

function Remove-ManagedEnvironmentVariables
{
    param(
        [string]$InstallRoot,
        [switch]$CleanAll
    )

    try
    {
        $sparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')

        if ( [string]::IsNullOrWhiteSpace($sparkHome))
        {
            Write-Info 'User SPARK_HOME is not set. Skipping SPARK_HOME removal.'
        }
        else
        {
            Remove-UserEnvironmentVariable -Name 'SPARK_HOME'
            Write-Info 'Removed user SPARK_HOME.'
        }

        foreach ($name in @('JAVA_HOME', 'HADOOP_HOME'))
        {
            $value = [Environment]::GetEnvironmentVariable($name, 'User')

            if ( [string]::IsNullOrWhiteSpace($value))
            {
                Write-Info "User $name is not set. Skipping removal."
                continue
            }

            if ($CleanAll -or (Test-PathPrefix -Path $value -Prefix $InstallRoot))
            {
                Remove-UserEnvironmentVariable -Name $name
                Write-Info "Removed user $name."
            }
        }
    }
    catch
    {
        Write-Warn "Could not clean managed environment variables: $( $_.Exception.Message )"
    }
}

# ------------------------------------------------------------------
# Cleanup helpers
# ------------------------------------------------------------------
function Remove-ManagedInstallations
{
    param([string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $InstallRoot))
    {
        return
    }

    $managedDirs = @(
    Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^(spark|jdk|hadoop)-'
            }
    )

    foreach ($dir in $managedDirs)
    {
        Write-Info "Removing managed installation directory: $( $dir.FullName )"
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
    }
}

# ------------------------------------------------------------------
# Installation helper (unzip the source file to the target folder)
# ------------------------------------------------------------------
function Expand-ZipToManagedFolder
{
    param(
        [string]$ZipPath,
        [string]$DestinationRoot,
        [string]$TargetFolderName
    )

    if (-not (Test-Path -LiteralPath $DestinationRoot))
    {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    # Use a short temp directory under the install root.
    # This avoids long %TEMP% paths and makes cleanup easier.
    $tempDir = Join-Path $DestinationRoot (".tmp_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try
    {
        $extracted = $false

        $separatorChar = [System.IO.Path]::DirectorySeparatorChar
        $separator = [string]$separatorChar

        # --------------------------------------------------------------
        # 1) Try built-in tar.exe
        # --------------------------------------------------------------
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue

        if ($tar)
        {
            Write-Info "Extracting with tar.exe: $( $tar.Source )"

            & $tar.Source -xf $ZipPath -C $tempDir

            if ($LASTEXITCODE -eq 0 -and @(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0)
            {
                $extracted = $true
                Write-Ok 'Extraction succeeded using tar.exe.'
            }
            else
            {
                Write-Warn 'tar.exe did not extract successfully. Trying next extraction method.'

                Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # --------------------------------------------------------------
        # 2) Try 7-Zip if available
        # --------------------------------------------------------------
        if (-not $extracted)
        {
            $sevenZip = Get-SevenZipPath

            if ($sevenZip)
            {
                Write-Info "Extracting with 7-Zip: $sevenZip"

                & $sevenZip x -y "-o$tempDir" $ZipPath

                if ($LASTEXITCODE -eq 0 -and @(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0)
                {
                    $extracted = $true
                    Write-Ok 'Extraction succeeded using 7-Zip.'
                }
                else
                {
                    Write-Warn '7-Zip did not extract successfully. Trying next extraction method.'

                    Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # --------------------------------------------------------------
        # 3) Try .NET ZipArchive
        #    This manually skips directory-only entries, which helps with
        #    zip files that contain empty folder entries.
        # --------------------------------------------------------------
        if (-not $extracted)
        {
            try
            {
                Write-Info 'Extracting with .NET ZipArchive.'

                Add-Type -AssemblyName System.IO.Compression.FileSystem

                $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

                try
                {
                    foreach ($entry in $zip.Entries)
                    {
                        $relativePath = $entry.FullName.Replace('/', $separator)

                        if ( [string]::IsNullOrWhiteSpace($relativePath))
                        {
                            continue
                        }

                        # Basic protection against unexpected parent-path entries.
                        if ($relativePath -match '\.\.')
                        {
                            continue
                        }

                        $targetPath = Join-Path $tempDir $relativePath
                        $targetPath = $targetPath.TrimEnd($separatorChar)

                        $isDirectory = [string]::IsNullOrEmpty($entry.Name) -or
                                $entry.FullName.EndsWith('/') -or
                                $entry.FullName.EndsWith($separator)

                        if ($isDirectory)
                        {
                            if (-not [string]::IsNullOrWhiteSpace($targetPath))
                            {
                                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                            }
                        }
                        else
                        {
                            $parent = Split-Path $targetPath -Parent

                            if (-not (Test-Path -LiteralPath $parent))
                            {
                                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                            }

                            [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                                    $entry,
                                    $targetPath,
                                    $true
                            )
                        }
                    }

                    if (@(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0)
                    {
                        $extracted = $true
                        Write-Ok 'Extraction succeeded using .NET ZipArchive.'
                    }
                }
                finally
                {
                    if ($zip)
                    {
                        $zip.Dispose()
                    }
                }

                if (-not $extracted)
                {
                    Write-Warn '.NET ZipArchive did not extract any files. Trying next extraction method.'

                    Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            catch
            {
                Write-Warn ".NET ZipArchive extraction failed: $( $_.Exception.Message ). Trying next extraction method."

                Get-ChildItem -LiteralPath $tempDir -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # --------------------------------------------------------------
        # 4) Last resort: Expand-Archive
        # --------------------------------------------------------------
        if (-not $extracted)
        {
            Write-Info 'Extracting with Expand-Archive as last resort.'

            Expand-Archive -LiteralPath $ZipPath -DestinationPath $tempDir -Force

            if (@(Get-ChildItem -LiteralPath $tempDir -Force).Count -gt 0)
            {
                $extracted = $true
                Write-Ok 'Extraction succeeded using Expand-Archive.'
            }
            else
            {
                throw 'Expand-Archive did not extract any files.'
            }
        }

        # --------------------------------------------------------------
        # Normalize extracted folder layout
        # --------------------------------------------------------------
        $items = @(Get-ChildItem -LiteralPath $tempDir -Force)
        $sourceDir = $null

        if ($items.Count -eq 1 -and $items[0].PSIsContainer)
        {
            $sourceDir = $items[0].FullName
        }
        elseif (Test-Path -LiteralPath (Join-Path $tempDir 'bin'))
        {
            $sourceDir = $tempDir
        }
        else
        {
            $withBin = @(
            $items | Where-Object {
                $_.PSIsContainer -and
                        (Test-Path -LiteralPath (Join-Path $_.FullName 'bin'))
            }
            )

            if ($withBin.Count -ge 1)
            {
                $sourceDir = $withBin[0].FullName
            }
            else
            {
                $sourceDir = $tempDir
            }
        }

        $targetPath = Join-Path $DestinationRoot $TargetFolderName

        if (Test-Path -LiteralPath $targetPath)
        {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
        }

        Move-Item -LiteralPath $sourceDir -Destination $targetPath -Force

        return $targetPath
    }
    finally
    {
        if (Test-Path -LiteralPath $tempDir)
        {
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

$javaPackages = @(Get-ZipPackages -Path $_javaSrcDir   -Prefix 'jdk')
$hadoopPackages = @(Get-ZipPackages -Path $_hadoopSrcDir -Prefix 'hadoop')
$sparkPackages = @(Get-ZipPackages -Path $_sparkSrcDir  -Prefix 'spark')

Write-Host ''
Write-Info ("JDK packages found: {0}" -f $javaPackages.Count)
$javaPackages | ForEach-Object {
    Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name)
}

Write-Info ("Hadoop packages found: {0}" -f $hadoopPackages.Count)
$hadoopPackages | ForEach-Object {
    Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name)
}

Write-Info ("Spark packages found: {0}" -f $sparkPackages.Count)
$sparkPackages | ForEach-Object {
    Write-Host ("  - {0} ({1})" -f $_.Version, $_.Name)
}

if ($sparkPackages.Count -eq 0)
{
    Write-Err "No Spark zip packages detected in '$_sparkSrcDir'."
    Write-Err 'Expected file name format: spark-x.x.x.zip'
    exit 1
}

# ------------------------------------------------------------------
# Step 2: Select Spark version
# ------------------------------------------------------------------
Write-Step 'Step 2: Select Spark version'

$selectedSpark = $null
$targetVersionPattern = '^\d+(\.\d+){1,3}$'

if (-not [string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
    $TargetSparkVersion = $TargetSparkVersion.Trim()

    if ($TargetSparkVersion -notmatch $targetVersionPattern) {
        Write-Err "Invalid -TargetSparkVersion '$TargetSparkVersion'."
        Write-Err 'Expected version format: 3.5.7, 4.1.3, 3.5, 4.1, etc.'
        exit 1
    }

    Write-Info "Target Spark version supplied by parameter: $TargetSparkVersion"

    $selectedSpark = @(
        $sparkPackages | Where-Object { $_.Version -eq $TargetSparkVersion }
    ) | Select-Object -First 1

    if (-not $selectedSpark) {
        Write-Err "Spark version '$TargetSparkVersion' was not found in '$SparkSourceDir'."
        Write-Err 'Available detected Spark versions:'

        $sparkPackages | ForEach-Object {
            Write-Host "  - $($_.Version)" -ForegroundColor Red
        }

        exit 1
    }

    Write-Info "Automatically selected Spark version: $($selectedSpark.Version)"
}
else {
    $selectedSpark = Select-SparkPackage -SparkPackages $sparkPackages

    if (-not $selectedSpark) {
        Write-Info 'No Spark version selected. Exiting.'
        exit 0
    }
}

Write-Info ("Selected Spark version: {0}" -f $selectedSpark.Version)

$dependencyRule = Get-SparkDependencyRule -SparkVersion $selectedSpark.Version

if (-not $dependencyRule)
{
    Write-Err ("No dependency rule found for Spark {0}." -f $selectedSpark.Version)
    Write-Err 'Edit $SparkDependencyMap in this script to add it.'
    exit 1
}

$selectedJava = Select-EligibleJava `
    -JavaPackages $javaPackages `
    -RequiredMajors $dependencyRule.JavaMajorVersions

$selectedHadoop = Select-EligibleHadoop `
    -HadoopPackages $hadoopPackages `
    -RequiredPrefixes $dependencyRule.HadoopVersionPrefixes

$missing = @()

if (-not $selectedJava)
{
    $missing += ('Required JDK major version(s) {0} not found in {1}' -f
    ($dependencyRule.JavaMajorVersions -join ', '),
    $_javaSrcDir
    )
}

if (-not $selectedHadoop)
{
    $missing += ('Required Hadoop version prefix(es) {0} not found in {1}' -f
    ($dependencyRule.HadoopVersionPrefixes -join ', '),
    $_hadoopSrcDir
    )
}

if ($missing.Count -gt 0)
{
    Write-Err ("Missing required packages for Spark {0}:" -f $selectedSpark.Version)

    foreach ($message in $missing)
    {
        Write-Host "  - $message" -ForegroundColor Red
    }

    exit 1
}

Write-Info ("Selected JDK    : {0} ({1})" -f $selectedJava.Version, $selectedJava.Name)
Write-Info ("Selected Hadoop : {0} ({1})" -f $selectedHadoop.Version, $selectedHadoop.Name)

# ------------------------------------------------------------------
# Step 3: Detect existing Spark installation
# ------------------------------------------------------------------
Write-Step 'Step 3: Check existing Spark installation'

$installedSpark = Get-InstalledSpark -InstallRoot $InstallRoot

if ($installedSpark)
{
    Write-Info "Existing Spark path    : $( $installedSpark.Path )"
    Write-Info "Existing Spark version : $( $installedSpark.Version )"

    if ($installedSpark.Version -eq $selectedSpark.Version)
    {
        $reinstall = Confirm-Choice `
            -Message "Spark $( $selectedSpark.Version ) is already installed. Do you want to reinstall it?" `
            -Default 'N'

        if (-not $reinstall)
        {
            Write-Info 'Reinstallation cancelled. No changes were made.'
            exit 0
        }
    }
    else
    {
        $replace = Confirm-Choice `
            -Message "Installed Spark version is '$( $installedSpark.Version )', selected version is '$( $selectedSpark.Version )'. Replace existing installation?" `
            -Default 'Y'

        if (-not $replace)
        {
            Write-Info 'Installation cancelled. No changes were made.'
            exit 0
        }
    }
} else {
    Write-Info 'No existing Spark installation was detected in the managed install root.'

    if (-not [string]::IsNullOrWhiteSpace($TargetSparkVersion)) {
        Write-Info 'Target Spark version was supplied. Continuing installation without interactive confirmation.'
    }
    else {
        $continue = Confirm-Choice `
            -Message "Install Spark $($selectedSpark.Version) now?" `
            -Default 'Y'

        if (-not $continue) {
            Write-Info 'Installation cancelled.'
            exit 0
        }
    }
}

# Capture old user environment values before cleaning.
$oldJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
$oldHadoopHome = [Environment]::GetEnvironmentVariable('HADOOP_HOME', 'User')
$oldSparkHome = [Environment]::GetEnvironmentVariable('SPARK_HOME', 'User')

try
{
    # ------------------------------------------------------------------
    # Step 4a: Clean previous installation and user environment
    # ------------------------------------------------------------------
    Write-Step 'Step 4a: Remove previous installation and clean user environment'

    Backup-UserEnvironment -InstallRoot $InstallRoot

    # Remove the detected existing Spark directory if it is managed.
    if ($installedSpark -and $installedSpark.Path -and (Test-Path -LiteralPath $installedSpark.Path))
    {
        if (Test-PathPrefix -Path $installedSpark.Path -Prefix $InstallRoot)
        {
            Write-Info "Removing existing managed Spark directory: $( $installedSpark.Path )"
            Remove-Item -LiteralPath $installedSpark.Path -Recurse -Force
        }
        else
        {
            Write-Warn "Existing Spark directory is outside the managed install root: $( $installedSpark.Path )"

            $removeExternal = Confirm-Choice `
                -Message 'Remove this existing Spark directory too?' `
                -Default 'N'

            if ($removeExternal)
            {
                try
                {
                    Remove-Item -LiteralPath $installedSpark.Path -Recurse -Force
                    Write-Info "Removed external Spark directory: $( $installedSpark.Path )"
                }
                catch
                {
                    Write-Warn ("Could not remove external Spark directory: {0}" -f $_.Exception.Message)
                }
            }
        }
    }

    # Remove old dependency directories if they are under managed InstallRoot.
    foreach ($oldDir in @($oldJavaHome, $oldHadoopHome))
    {
        if ($oldDir -and (Test-PathPrefix -Path $oldDir -Prefix $InstallRoot))
        {
            Write-Info "Removing old managed dependency directory: $oldDir"
            Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove any remaining managed spark/jdk/hadoop directories.
    Remove-ManagedInstallations -InstallRoot $InstallRoot

    # Remove environment variables.
    Remove-ManagedEnvironmentVariables `
        -InstallRoot $InstallRoot `
        -CleanAll:$CleanAllRelatedUserVariables

    # Remove PATH entries under managed install root.
    Remove-PathVariablePrefix -Prefix $InstallRoot

    # Also remove common variable-based PATH entries and old bin entries.
    $exactPathRemovals = @(
        '%JAVA_HOME%\bin',
        '%HADOOP_HOME%\bin',
        '%SPARK_HOME%\bin'
    )

    if ($oldSparkHome)
    {
        $exactPathRemovals += (Join-Path $oldSparkHome 'bin')
    }

    if ($CleanAllRelatedUserVariables)
    {
        if ($oldJavaHome)
        {
            $exactPathRemovals += (Join-Path $oldJavaHome 'bin')
        }

        if ($oldHadoopHome)
        {
            $exactPathRemovals += (Join-Path $oldHadoopHome 'bin')
        }
    }
    else
    {
        if ($oldJavaHome -and (Test-PathPrefix -Path $oldJavaHome -Prefix $InstallRoot))
        {
            $exactPathRemovals += (Join-Path $oldJavaHome 'bin')
        }

        if ($oldHadoopHome -and (Test-PathPrefix -Path $oldHadoopHome -Prefix $InstallRoot))
        {
            $exactPathRemovals += (Join-Path $oldHadoopHome 'bin')
        }
    }

    $exactPathRemovals = @(
        '%JAVA_HOME%\bin',
        '%HADOOP_HOME%\bin',
        '%SPARK_HOME%\bin'
    )

    # Only add old SPARK_HOME bin path if SPARK_HOME actually existed.
    if (-not [string]::IsNullOrWhiteSpace($oldSparkHome))
    {
        try
        {
            $sparkBin = Join-Path $oldSparkHome 'bin'

            if (-not [string]::IsNullOrWhiteSpace($sparkBin))
            {
                $exactPathRemovals += $sparkBin
            }
        }
        catch
        {
            Write-Warn "Could not build old SPARK_HOME bin path: $( $_.Exception.Message )"
        }
    }

    if ($CleanAllRelatedUserVariables)
    {
        if (-not [string]::IsNullOrWhiteSpace($oldJavaHome))
        {
            try
            {
                $javaBin = Join-Path $oldJavaHome 'bin'

                if (-not [string]::IsNullOrWhiteSpace($javaBin))
                {
                    $exactPathRemovals += $javaBin
                }
            }
            catch
            {
                Write-Warn "Could not build old JAVA_HOME bin path: $( $_.Exception.Message )"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($oldHadoopHome))
        {
            try
            {
                $hadoopBin = Join-Path $oldHadoopHome 'bin'

                if (-not [string]::IsNullOrWhiteSpace($hadoopBin))
                {
                    $exactPathRemovals += $hadoopBin
                }
            }
            catch
            {
                Write-Warn "Could not build old HADOOP_HOME bin path: $( $_.Exception.Message )"
            }
        }
    }
    else
    {
        if (-not [string]::IsNullOrWhiteSpace($oldJavaHome) -and
                (Test-PathPrefix -Path $oldJavaHome -Prefix $InstallRoot))
        {
            try
            {
                $javaBin = Join-Path $oldJavaHome 'bin'

                if (-not [string]::IsNullOrWhiteSpace($javaBin))
                {
                    $exactPathRemovals += $javaBin
                }
            }
            catch
            {
                Write-Warn "Could not build old JAVA_HOME bin path: $( $_.Exception.Message )"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($oldHadoopHome) -and
                (Test-PathPrefix -Path $oldHadoopHome -Prefix $InstallRoot))
        {
            try
            {
                $hadoopBin = Join-Path $oldHadoopHome 'bin'

                if (-not [string]::IsNullOrWhiteSpace($hadoopBin))
                {
                    $exactPathRemovals += $hadoopBin
                }
            }
            catch
            {
                Write-Warn "Could not build old HADOOP_HOME bin path: $( $_.Exception.Message )"
            }
        }
    }

    # Final filter: remove null/empty values before calling Remove-PathVariableExact.
    $exactPathRemovals = @(
    $exactPathRemovals | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }
    )

    try
    {
        Remove-PathVariableExact -ExactEntries $exactPathRemovals
    }
    catch
    {
        Write-Warn "Could not clean exact user PATH entries: $( $_.Exception.Message )"
    }

    Refresh-ProcessPath

    Write-Ok 'Previous managed installation and related user environment cleaned.'

    # ------------------------------------------------------------------
    # Step 4b: Install selected Spark, JDK, and Hadoop
    # ------------------------------------------------------------------
    Write-Step 'Step 4b: Install selected Spark version and dependencies'

    $javaHome = Expand-ZipToManagedFolder `
        -ZipPath $selectedJava.FullPath `
        -DestinationRoot $InstallRoot `
        -TargetFolderName ("jdk-{0}" -f $selectedJava.Version)

    $hadoopHome = Expand-ZipToManagedFolder `
        -ZipPath $selectedHadoop.FullPath `
        -DestinationRoot $InstallRoot `
        -TargetFolderName ("hadoop-{0}" -f $selectedHadoop.Version)

    $sparkHome = Expand-ZipToManagedFolder `
        -ZipPath $selectedSpark.FullPath `
        -DestinationRoot $InstallRoot `
        -TargetFolderName ("spark-{0}" -f $selectedSpark.Version)

    # Basic sanity checks.
    $javaExe = Join-Path (Join-Path $javaHome 'bin') 'java.exe'
    if (-not (Test-Path -LiteralPath $javaExe))
    {
        Write-Warn "java.exe was not found under '$javaHome'. The JDK zip layout may be unexpected."
    }

    $sparkSubmitCmd = Join-Path (Join-Path $sparkHome 'bin') 'spark-submit.cmd'
    $sparkSubmitSh = Join-Path (Join-Path $sparkHome 'bin') 'spark-submit'

    if (-not ((Test-Path -LiteralPath $sparkSubmitCmd) -or (Test-Path -LiteralPath $sparkSubmitSh)))
    {
        throw "spark-submit was not found under '$sparkHome'. The Spark zip layout may be unexpected."
    }

    # ------------------------------------------------------------------
    # Step 4c: Set user environment variables
    # ------------------------------------------------------------------
    Write-Step 'Step 4c: Configure user environment variables'

    Set-UserEnvironmentVariable -Name 'JAVA_HOME'   -Value $javaHome
    Set-UserEnvironmentVariable -Name 'HADOOP_HOME' -Value $hadoopHome
    Set-UserEnvironmentVariable -Name 'SPARK_HOME'  -Value $sparkHome

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
}
catch
{
    Write-Err ("Installation failed: {0}" -f $_.Exception.Message)

    if ($_.ScriptStackTrace)
    {
        Write-Err $_.ScriptStackTrace
    }

    exit 1
}