<#
.SYNOPSIS
    Configures the local PowerShell environment for secure Hadoop/Spark delegation token management.

.DESCRIPTION
    This script sets up the necessary registry keys, directories, and PowerShell profile wrappers
    to automatically manage Hadoop/YARN/Spark delegation tokens in multi-user environments.

    It ensures that:
    1. A fresh session token is acquired when a new PowerShell console opens.
    2. The session token is revoked when the console closes (acting like a Kerberos logout).
    3. Commands like `hdfs` and `yarn` can use the session token natively.
    4. Commands like `spark-submit` are wrapped to temporarily inject an ephemeral, job-specific
       token, protecting the main session token from being accidentally exposed or reused by
       cluster nodes.

.PARAMETER NameNodeWeb
    The WebHDFS URL of the NameNode (e.g., https://deb13-spark1.casdds.casd:50470).
.PARAMETER RmWeb
    The ResourceManager Web UI URL (e.g., https://deb13-spark1.casdds.casd:8090).
.PARAMETER ServiceIp
    The IP address of the primary service node.
.PARAMETER ServiceFqdn
    The Fully Qualified Domain Name (FQDN) of the primary service node.
.PARAMETER Renewer
    The principal authorized to renew delegation tokens (default: "hdfs").
.PARAMETER HdfsRpcPort
    The RPC port for HDFS (default: 9000).
.PARAMETER RmRpcPort
    The RPC port for YARN ResourceManager (default: 8032).
.PARAMETER StagingDir
    The HDFS staging directory for Spark jobs.
.PARAMETER DriverPort
    The port used by the Spark driver (default: 20000).

.EXAMPLE
    .\Setup-HadoopTokens.ps1 -Verbose
    Runs the setup with verbose output to track each configuration step.

.EXAMPLE
    .\Setup-HadoopTokens.ps1 -ServiceFqdn "custom-node.example.com" -HdfsRpcPort 8020
    Runs the setup with custom FQDN and RPC port overrides.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "WebHDFS URL of the NameNode")]
    [string] $NameNodeWeb = "https://deb13-spark1.casdds.casd:50470",

    [Parameter(Mandatory = $false, HelpMessage = "ResourceManager Web UI URL")]
    [string] $RmWeb       = "https://deb13-spark1.casdds.casd:8090",

    [Parameter(Mandatory = $false, HelpMessage = "IP address of the service node")]
    [string] $ServiceIp   = "10.50.5.203",

    [Parameter(Mandatory = $false, HelpMessage = "FQDN of the service node")]
    [string] $ServiceFqdn = "deb13-spark1.casdds.casd",

    [Parameter(Mandatory = $false, HelpMessage = "Principal authorized to renew tokens")]
    [string] $Renewer     = "hdfs",

    [Parameter(Mandatory = $false, HelpMessage = "HDFS RPC port")]
    [string] $HdfsRpcPort = "9000",

    [Parameter(Mandatory = $false, HelpMessage = "YARN ResourceManager RPC port")]
    [string] $RmRpcPort   = "8032",

    [Parameter(Mandatory = $false, HelpMessage = "HDFS staging directory for Spark")]
    [string] $StagingDir  = "hdfs://deb13-spark1.casdds.casd:9000/users",

    [Parameter(Mandatory = $false, HelpMessage = "Spark driver port")]
    [int]    $DriverPort  = 20000
)

# ==============================================================================
# Initialization
# ==============================================================================
$ErrorActionPreference = "Stop"

# Return the root dir path of the install-tokens.ps1
$toolsDir = $PSScriptRoot
# Refresh script name
$refreshScriptName = "refresh-tokens.ps1"
$refreshScript = Join-Path $toolsDir $refreshScriptName

$registryPath = "HKCU:\Software\CASD\Hadoop"

# Use CurrentUserAllHosts so the configuration is available to all PowerShell
# hosts for the current user.
$profilePath = $PROFILE.CurrentUserAllHosts

$profileBeginMarker = "# === HDFS/YARN/Spark delegation tokens BEGIN ==="
$profileEndMarker   = "# === HDFS/YARN/Spark delegation tokens END ==="

Write-Verbose "Starting Hadoop/Spark token environment configuration..."
Write-Verbose "Tools directory : $toolsDir"
Write-Verbose "Refresh script  : $refreshScript"
Write-Verbose "Profile         : $profilePath"


# ==============================================================================
#region Helper functions
# ==============================================================================

function ConvertTo-PowerShellSingleQuotedString {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )
    # PowerShell single-quoted strings escape ' as ''
    return "'" + ($Value -replace "'", "''") + "'"
}

function Protect-TokenDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        New-Item -ItemType Directory -Path $DirectoryPath -Force | Out-Null
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        $dirInfo = New-Object System.IO.DirectoryInfo($DirectoryPath)

        # IMPORTANT:
        # Only get the DACL / Access section.
        # Do NOT touch Audit/SACL because that requires SeSecurityPrivilege.
        $acl = $dirInfo.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access
        )

        # Disable inheritance and remove inherited rules
        $acl.SetAccessRuleProtection($true, $false)

        # Remove all explicit access rules
        $existingRules = @(
            $acl.GetAccessRules(
                $true,
                $true,
                [System.Security.Principal.NTAccount]
            )
        )

        foreach ($rule in $existingRules) {
            [void]$acl.RemoveAccessRule($rule)
        }

        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow  = [System.Security.AccessControl.AccessControlType]::Allow

        $inheritFlags = `
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit

        $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None

        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUser,
            $rights,
            $inheritFlags,
            $propagationFlags,
            $allow
        )

        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM",
            $rights,
            $inheritFlags,
            $propagationFlags,
            $allow
        )

        [void]$acl.AddAccessRule($userRule)
        [void]$acl.AddAccessRule($systemRule)

        # Apply only DACL/access permissions
        $dirInfo.SetAccessControl($acl)

        Write-Verbose "Secured token directory ACL: $DirectoryPath"
    }
    catch {
        Write-Warning "Failed to set ACLs on token directory '$DirectoryPath'. Error: $($_.Exception.Message)"
    }
}

#endregion Helper functions


# ==============================================================================
#region 0. Pre-flight checks
# ==============================================================================

if (-not (Test-Path -LiteralPath $refreshScript -PathType Leaf)) {
    throw @"
Critical dependency missing.

Expected refresh script:
    $refreshScript

Make sure '$refreshScriptName' is located next to this setup script.
"@
}

if ([string]::IsNullOrWhiteSpace($env:HADOOP_HOME)) {
    Write-Warning "Environment variable HADOOP_HOME is not defined. Hadoop commands may not work."
}

if ([string]::IsNullOrWhiteSpace($env:HADOOP_CONF_DIR)) {
    Write-Warning "Environment variable HADOOP_CONF_DIR is not defined. Hadoop commands may not work."
}

if ([string]::IsNullOrWhiteSpace($env:SPARK_HOME)) {
    Write-Warning "SPARK_HOME is not defined. spark-submit may not work."
}

#endregion 0


# ==============================================================================
#region 1. Registry and Directory Configuration
# ==============================================================================

$tokenDir = Join-Path $env:LOCALAPPDATA "CASD\tokens"

if (-not (Test-Path -LiteralPath $tokenDir -PathType Container)) {
    New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
    Write-Verbose "Created token directory: $tokenDir"
}

# ------------------------------------------------------------------------------
# Lock down the token directory
# ------------------------------------------------------------------------------

Protect-TokenDirectory -DirectoryPath $tokenDir

#endregion 1


# ==============================================================================
#region 2. Registry configuration
# ==============================================================================

if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Prefer HADOOP_CONF_DIR if it is explicitly configured.
# Otherwise fall back to HADOOP_HOME\etc\hadoop.
$hadoopConfDir = ""
if (-not [string]::IsNullOrWhiteSpace($env:HADOOP_CONF_DIR)) {
    $hadoopConfDir = $env:HADOOP_CONF_DIR
}
elseif (-not [string]::IsNullOrWhiteSpace($env:HADOOP_HOME)) {
    $hadoopConfDir = Join-Path $env:HADOOP_HOME "etc\hadoop"
}

# Define configuration properties to store in the registry
$conf = @{
    ToolsPath   = $toolsDir
    TokenDir    = $tokenDir
    NameNodeWeb = $NameNodeWeb
    RmWeb       = $RmWeb
    ServiceIp   = $ServiceIp
    ServiceFqdn = $ServiceFqdn
    Renewer     = $Renewer
    HdfsRpcPort = $HdfsRpcPort
    RmRpcPort   = $RmRpcPort
    StagingDir  = $StagingDir
    SparkHome   = if ($env:SPARK_HOME) { $env:SPARK_HOME } else { "" }
    HadoopHome  = if ($env:HADOOP_HOME) { $env:HADOOP_HOME } else { "" }
    HadoopConf  = $hadoopConfDir
}

# Write or update each property in the registry
foreach ($key in $conf.Keys) {
    Set-ItemProperty -Path $registryPath -Name $key -Value $conf[$key] -Type String -Force
}

# DriverPort is stored as a DWord (integer)
Set-ItemProperty -Path $registryPath -Name "DriverPort" -Value $DriverPort -Type DWord -Force

Write-Verbose "Configuration written to: $registryPath"

#endregion 2


# ==============================================================================
#region 3. PowerShell Profile Injection
# ==============================================================================

# ------------------------------------------------------------------------------
# Ensure profile directory exists
# ------------------------------------------------------------------------------

$profileDir = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

# Build paths as literals for the generated profile.
# These values are intentionally resolved NOW, during installation.
$profileRefreshScript = ConvertTo-PowerShellSingleQuotedString $refreshScript

# ------------------------------------------------------------------------------
# Profile block
# Note: We use an expandable here-string @" ... "@.
# Variables prefixed with ` are escaped so they evaluate in the USER's profile, not now.
# Variables WITHOUT backticks (like $profileRefreshScript) evaluate NOW.
# ------------------------------------------------------------------------------

$profileBlock = @"
$profileBeginMarker

# -----------------------------------------------------------------------------
# CASD Hadoop/Spark delegation token configuration
# -----------------------------------------------------------------------------

# Acquire a fresh session token whenever PowerShell starts.
& $profileRefreshScript -Quiet

# -----------------------------------------------------------------------------
# Revoke the session token when PowerShell exits.
# -----------------------------------------------------------------------------
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
    try {
        & $profileRefreshScript -Cancel -Quiet -ErrorAction SilentlyContinue
    }
    catch {
        # PowerShell is exiting, do not prevent shutdown due to cleanup errors.
    }
} | Out-Null

# -----------------------------------------------------------------------------
# spark-submit wrapper
#
# spark-submit receives its own temporary delegation token.
# The normal session token is restored after spark-submit terminates.
# -----------------------------------------------------------------------------

function global:spark-submit {
    # Sub-expression that: Creates a new GUID and formats it as 32 hex digits with no hyphens (N format specifier)
    `$jobToken = Join-Path `$env:TEMP "hadoop-job-`$PID-`$([guid]::NewGuid().ToString('N')).dt"

    `$oldTokenLocation = `$env:HADOOP_TOKEN_FILE_LOCATION
    `$hadOldToken = Test-Path -Path Env:HADOOP_TOKEN_FILE_LOCATION
    `$localExitCode = 0

    try {
        # Generate an independent token for this Spark job.
        & $profileRefreshScript -Out `$jobToken -Quiet -ErrorAction Stop
        if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) {
            throw "Exit code `$LASTEXITCODE"
        }

        `$env:HADOOP_TOKEN_FILE_LOCATION = `$jobToken

        # Execute spark-submit (fallback to PATH if SPARK_HOME is missing)
        `$sparkCmd = if (`$env:SPARK_HOME) { "`$env:SPARK_HOME\bin\spark-submit.cmd" } else { "spark-submit.cmd" }
        & `$sparkCmd @args

        # Capture exit code before finally block alters it
        `$localExitCode = `$LASTEXITCODE
    }
    catch {
        Write-Error "Failed to execute spark-submit: `$$_"
        `$localExitCode = 1
    }
    finally {
        # Restore the previous token environment.
        if (`$hadOldToken) {
            `$env:HADOOP_TOKEN_FILE_LOCATION = `$oldTokenLocation
        }
        else {
            Remove-Item -Path Env:HADOOP_TOKEN_FILE_LOCATION -ErrorAction SilentlyContinue
        }

        # Remove the temporary token and Hadoop checksum.
        Remove-Item -LiteralPath `$jobToken -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "`$jobToken.crc" -Force -ErrorAction SilentlyContinue

        # Ensure the global exit code reflects the command's outcome
        `$global:LASTEXITCODE = `$localExitCode
    }
}

$profileEndMarker
"@

# ------------------------------------------------------------------------------
# Check user profile content, if the CASD block exists already and not equal to the latest version,
# replace it with the latest version. If no CASD block, add the latest version.
#
# This makes the installer idempotent and allows future versions of this
# setup script to update the profile configuration.
# ------------------------------------------------------------------------------

$profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $profileContent) {
    $profileContent = ""
}

$escapedBegin = [regex]::Escape($profileBeginMarker)
$escapedEnd   = [regex]::Escape($profileEndMarker)
$profilePattern = "(?s)$escapedBegin.*?$escapedEnd"

if ($profileContent -match $profilePattern) {
    Write-Verbose "Existing CASD profile block found. Replacing it."
    $profileContent = [regex]::Replace($profileContent, $profilePattern, $profileBlock.TrimEnd())
}
else {
    Write-Verbose "No existing CASD profile block found. Adding it."
    # Ensure clean appending with proper newline separation
    $profileContent = $profileContent.TrimEnd() + "`r`n" + $profileBlock.TrimEnd() + "`r`n"
}

try {
    Set-Content -LiteralPath $profilePath -Value $profileContent -Encoding UTF8 -Force
    Write-Verbose "PowerShell profile updated: $profilePath"
}
catch {
    Write-Error "Failed to write to PowerShell profile: $_"
}

#endregion 3


# ==============================================================================
#region 4. Initial token generation
# ==============================================================================

Write-Host "Generating initial token set..." -NoNewline
try {
    & $refreshScript -Quiet -ErrorAction Stop
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "refresh-tokens.ps1 returned exit code $LASTEXITCODE."
    }
    Write-Host " [OK]" -ForegroundColor Green
}
catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Warning "Initial token generation failed. You may need to run refresh-tokens.ps1 manually. Error: $_"
    # Do not throw here, as the environment setup (registry/profile) was still successful.
}

#endregion 4


# ==============================================================================
#region 5. Completion Message
# ==============================================================================

Write-Host ""
Write-Host "Token configuration completed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Please open a NEW PowerShell console for the changes to take effect."
Write-Host ""
Write-Host "Once opened, you can test the configuration with:"
Write-Host "    hdfs dfs -ls /"
Write-Host "    yarn application -list"
Write-Host "    spark-submit --deploy-mode cluster --master yarn my_job.py"
#endregion 5