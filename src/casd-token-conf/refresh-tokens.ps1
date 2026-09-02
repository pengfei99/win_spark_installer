<#
.SYNOPSIS
    Hadoop Delegation Token Manager for Windows Server / Multi-User Environments.

.DESCRIPTION
    This script automates the retrieval, local storage, tracking, and revocation
    of Hadoop HDFS and YARN Resource Manager delegation tokens.

    It supports multi-tenant / RDS Remote Desktop environments by isolating token
    files per Process ID (PID) and securing them with explicit NTFS permissions.

.PARAMETER Out
    Optional file path. When specified, generates a single token file at the given
    path (for background jobs, Spark, R, Python) and terminates without creating a session.

.PARAMETER Cancel
    Switch flag. Revokes and cleans up all active cluster tokens associated with
    the current Process ID ($PID).

.PARAMETER Quiet
    Switch flag. Suppresses non-essential terminal console outputs.

.NOTES
    Author:      Enterprise Systems Administration
    Registry:    HKCU:\Software\CASD\Hadoop
    Security:    Requires valid Cluster CA installed in Windows Trusted Root Store.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string] $Out,

    [Parameter(Mandatory=$false)]
    [switch] $Cancel,

    [Parameter(Mandatory=$false)]
    [switch] $Quiet
)

# Enforce strict error handling and variable checking
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Reads an environment variable that may not exist.
# Under Set-StrictMode -Version Latest, `$env:UNDEFINED` throws instead of
# returning $null, so read via the provider which is strict-mode safe.
function Get-EnvVar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $v = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $null }
    return [string]$v.Value
}

# User-level registry locations for configuration and active session state tracking.
$REG      = "HKCU:\Software\CASD\Hadoop"
$REG_SESS = "$REG\Sessions"
$TOKEN_GEN_JAR_NAME = "make-creds-file-1.0.0-SNAPSHOT.jar"
$TOKEN_GEN_CLASS_NAME = "org.casd.util.MakeCredsFile"

# ==============================================================================
# LOGGING & CONSOLE OUTPUT HELPERS
# ==============================================================================

function Write-LogMessage {
    param([string]$Message, [string]$Level = "INFO")

    # Always send to verbose stream for pipeline/transcript compatibility
    Write-Verbose "[$Level] $Message"

    if ($Quiet) { return }

    switch ($Level) {
        "ERROR"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        "WARNING" { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
        default   { Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
    }
}

# ==============================================================================
# CONFIGURATION & SECURITY SETUP
# ==============================================================================

# Enforce strong TLS encryption (TLS 1.2 / TLS 1.3).
# TLS 1.3 enum (12288) is not available on older .NET Framework versions (< 4.8).
# Use the raw integer value so this works on PS 5.1 across all Windows Server versions.
$Tls12 = [Net.SecurityProtocolType]::Tls12
$Tls13 = [Net.SecurityProtocolType]12288
[Net.ServicePointManager]::SecurityProtocol = $Tls12 -bor $Tls13

# Cluster CA certificates MUST be deployed to the Windows Trusted Root Store.
# TODO: Remove this block and rely on OS trust store in production.
if (-not ("TrustAllCerts" -as [type])) {
    Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public static class TrustAllCerts {
        public static void Enable() {
            ServicePointManager.ServerCertificateValidationCallback = (sender, cert, chain, errors) => true;
        }
    }
"@
}
[TrustAllCerts]::Enable()
# Write-LogMessage "WARNING: Server certificate validation is currently disabled (TrustAllCerts). This is a security risk." "WARNING"

<#
.SYNOPSIS
    Reads Hadoop client configuration from HKCU registry.
#>
function Get-HadoopConfig {
    if (-not (Test-Path $REG)) {
        throw "Configuration missing in $REG. Please execute 'install-tokens.ps1' first."
    }
    return Get-ItemProperty -Path $REG
}

# Load current user configuration from registry
$confInReg = Get-HadoopConfig

<#
.SYNOPSIS
    Restricts NTFS access permissions on sensitive delegation token files.
.DESCRIPTION
    In multi-user (RDS / Terminal Services) environments, default permissions
    may allow other authenticated users to read token files. This function
    disables inheritance and grants Full Control strictly to the Current User and SYSTEM.
.PARAMETER filePath
    Path to the token file requiring ACL hardening.
#>
function Protect-TokenFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$filePath
    )

    if ([string]::IsNullOrWhiteSpace($filePath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        $fileInfo = New-Object System.IO.FileInfo($filePath)

        # IMPORTANT:
        # Only get the DACL / Access section.
        # Do NOT request Audit/SACL, Owner, or Group sections.
        $acl = $fileInfo.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access
        )

        # Disable inheritance and remove inherited rules
        $acl.SetAccessRuleProtection($true, $false)

        # Remove all existing explicit access rules
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

        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUser,
            $rights,
            $allow
        )

        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM",
            $rights,
            $allow
        )

        [void]$acl.AddAccessRule($userRule)
        [void]$acl.AddAccessRule($systemRule)

        # Apply only file access rules, not audit/security privilege sections
        $fileInfo.SetAccessControl($acl)

        Write-LogMessage "Secured token file ACL: $filePath"
    }
    catch {
        Write-LogMessage "Failed to set ACLs on token file '$filePath'. Error: $($_.Exception.Message)" "WARNING"
    }
}

# ==============================================================================
# REST API / HTTP HELPERS (SPNEGO / KERBEROS SSO)
# ==============================================================================

<#
.SYNOPSIS
    Executes REST API requests using Windows Integrated Authentication (Kerberos/SPNEGO).
#>
function Invoke-Sso {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [hashtable]$Headers = $null
    )

    $params = @{
        Uri                   = $Uri
        Method                = $Method
        UseDefaultCredentials = $true  # Uses logged-in Windows user Kerberos ticket
    }

    if ($Body)    { $params.Body = $Body; $params.ContentType = "application/json" }
    if ($Headers) { $params.Headers = $Headers }

    try {
        return (Invoke-RestMethod @params)
    } catch {
        $errorMessage = $_.Exception.Message
        $statusCode = $null

        if ($_.Exception -and $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        # STRICT MODE FIX: Safely check if ErrorDetails exists before accessing .Message
        $responseBody = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $responseBody = $_.ErrorDetails.Message
        }

        # Fallback for PS 5.1 if ErrorDetails is empty but stream is available
        if ([string]::IsNullOrWhiteSpace($responseBody) -and $_.Exception -and $_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {
                # Ignore stream read errors and fall back to original message
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            $errorMessage = "HTTP $statusCode - $responseBody"
        } elseif ($statusCode) {
            $errorMessage = "HTTP $statusCode - $errorMessage"
        }

        throw "REST Call Failure [$Method $Uri]: $errorMessage"
    }
}

# ==============================================================================
# HADOOP DELEGATION TOKEN CREATION & REVOCATION
# ==============================================================================

<#
.SYNOPSIS
    Requests a WebHDFS Delegation Token from the NameNode.
#>
function New-HdfsToken {
    $nnWeb = $confInReg.NameNodeWeb.TrimEnd('/')
    $endpoint = "$nnWeb/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=$($confInReg.Renewer)"
    $response = Invoke-Sso -Uri $endpoint

    $token = $null
    if ($response) {
        $tokenObj = $response.Token
        # STRICT MODE FIX: Verify Token object exists before reading urlString
        if ($tokenObj -and $tokenObj.urlString) {
            $token = $tokenObj.urlString
        }
    }

    if (-not $token) { throw "Empty or malformed HDFS token returned by NameNode." }
    return $token
}

<#
.SYNOPSIS
    Requests a YARN Delegation Token from the Resource Manager.
#>
function New-RmToken {
    $rmWeb = $confInReg.RmWeb.TrimEnd('/')
    $endpoint = "$rmWeb/ws/v1/cluster/delegation-token"
    $body = @{ renewer = $confInReg.Renewer } | ConvertTo-Json
    $response = Invoke-Sso -Uri $endpoint -Method "POST" -Body $body

    $token = $null
    if ($response -and $response.token) {
        $token = $response.token
    }

    if (-not $token) { throw "Empty or malformed Resource Manager token returned." }
    return $token
}

<#
.SYNOPSIS
    Revokes an active HDFS token on the cluster.
#>
function Revoke-HdfsToken {
    param([string]$Token)
    if (-not $Token) { return }
    try {
        $nnWeb = $confInReg.NameNodeWeb.TrimEnd('/')
        $endpoint = "$nnWeb/webhdfs/v1/?op=CANCELDELEGATIONTOKEN&token=$Token"
        Invoke-Sso -Uri $endpoint -Method "PUT" | Out-Null
    } catch {
        Write-LogMessage "HDFS revocation ignored: $($_.Exception.Message)" "WARNING"
    }
}

<#
.SYNOPSIS
    Revokes an active YARN Resource Manager token on the cluster.
#>
function Revoke-RmToken {
    param([string]$Token)
    if (-not $Token) { return }
    try {
        $rmWeb = $confInReg.RmWeb.TrimEnd('/')
        $endpoint = "$rmWeb/ws/v1/cluster/delegation-token"
        $headers  = @{ "X-Hadoop-Delegation-Token" = $Token }
        Invoke-Sso -Uri $endpoint -Method "DELETE" -Headers $headers | Out-Null
    } catch {
        Write-LogMessage "RM revocation ignored: $($_.Exception.Message)" "WARNING"
    }
}

# ==============================================================================
# SESSION LIFECYCLE MANAGEMENT
# ==============================================================================

function Get-SessionKey {
    param([string]$Id)
    return "$REG_SESS\$Id"
}

<#
.SYNOPSIS
    Cleans up local token files, registry tracking keys, and revokes cluster tokens.
#>
function Remove-Session {
    param([string]$Id)

    $keyPath = Get-SessionKey $Id
    if (-not (Test-Path $keyPath)) { return }

    $session = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
    if (-not $session) {
        # Key exists but is empty or corrupt, just delete it
        Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # 1. Revoke tokens remotely on the Hadoop cluster
    if ($session.HdfsToken) { Revoke-HdfsToken $session.HdfsToken }
    if ($session.RmToken)   { Revoke-RmToken   $session.RmToken }

    # 2. Delete binary token file and associated Java CRC checksum file
    if ($session.TokenFile -and (Test-Path $session.TokenFile)) {
        $fileName = Split-Path $session.TokenFile -Leaf
        $fileDir  = Split-Path $session.TokenFile -Parent
        $crcFile  = Join-Path $fileDir ".$fileName.crc"

        Remove-Item $session.TokenFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $crcFile) {
            Remove-Item $crcFile -Force -ErrorAction SilentlyContinue
        }
    }

    # 3. Purge session record from local registry
    Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Scans the registry for session entries matching dead Windows process IDs and purges them.
#>
function Clear-OrphanSessions {
    if (-not (Test-Path $REG_SESS)) { return }

    # Temporarily allow errors so a failure to clean up one session doesn't abort the script
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    foreach ($key in Get-ChildItem $REG_SESS -ErrorAction SilentlyContinue) {
        $sessionId = $key.PSChildName

        # Skip current process ID
        if ($sessionId -eq "$PID") { continue }

        $session = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if (-not $session) {
            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $isOrphan = $false

        try {
            $proc = Get-Process -Id $sessionId -ErrorAction SilentlyContinue
            if (-not $proc) {
                $isOrphan = $true
            } else {
                # SECURITY FIX: Check for PID Reuse
                # If the process exists, verify its start time matches the session creation time.
                # If the process started AFTER the registry entry was created, it's a new process
                # that reused the old PID, meaning the original session is dead (orphaned).
                if ($session.Created) {
                    # Use InvariantCulture to prevent parsing failures on non-EN-US systems
                    $regTime = [datetime]::Parse($session.Created, [System.Globalization.CultureInfo]::InvariantCulture)

                    # Allow a small buffer (e.g., 5 seconds) for clock skew or process startup time
                    if ($proc.StartTime -gt $regTime.AddSeconds(5)) {
                        $isOrphan = $true
                        Write-LogMessage "Detected PID reuse for $sessionId. Original session is orphaned." "WARNING"
                    }
                } else {
                    # If no Created timestamp exists (legacy entry), assume orphan if PID doesn't match current user
                    $isOrphan = $true
                }
            }
        } catch {
            # If we can't inspect the process (e.g., access denied), assume it's an orphan to be safe
            $isOrphan = $true
        }

        if ($isOrphan) {
            Write-LogMessage "Revoking tokens for terminated session (PID: $sessionId)"
            Remove-Session $sessionId
        }
    }

    $ErrorActionPreference = $savedEap
}

# ==============================================================================
# EXECUTION BRANCH 1: SESSION CANCELLATION (-Cancel)
# ==============================================================================

if ($Cancel) {
    Remove-Session $PID
    Write-LogMessage "Tokens for current session PID $PID revoked."
    exit 0
}

# ==============================================================================
# BINARY TOKEN GENERATION (JAVA INTEROP)
# ==============================================================================

<#
.SYNOPSIS
    Invokes helper Java class (MakeCredsFile) to format raw tokens into a Hadoop .dt container file.
#>
function Write-CredsFile {
    param(
        [string]$DestinationPath,
        [string]$HdfsTok,
        [string]$RmTok
    )

    # ========================================================================
    # Bypass polluted system PATH by using explicit environment variables
    # ========================================================================

    # 1. Locate Java executable explicitly
    $javaBaseDir = Get-EnvVar "JAVA_HOME"
    if ([string]::IsNullOrWhiteSpace($javaBaseDir)) {
        $javaBaseDir = Get-EnvVar "JAVA_PATH" # Fallback if JAVA_PATH is used instead
    }

    if ([string]::IsNullOrWhiteSpace($javaBaseDir)) {
        throw "Neither JAVA_HOME nor JAVA_PATH environment variables are set. Cannot locate Java executable."
    }

    $javaExe = Join-Path $javaBaseDir "bin\java.exe"

    if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf)) {
        throw "Java executable not found at expected path: '$javaExe'. Please verify your JAVA_HOME or JAVA_PATH environment variable."
    }

    # 2. Locate HDFS command explicitly to get the classpath
    $hadoopCp = ""
    $hdfsCmd = $null

    $hadoopHome = Get-EnvVar "HADOOP_HOME"

    if (-not [string]::IsNullOrWhiteSpace($hadoopHome)) {
        $hdfsCmd = Join-Path $hadoopHome "bin\hdfs.cmd"
    }

    if ($hdfsCmd -and (Test-Path -LiteralPath $hdfsCmd -PathType Leaf)) {
        try {
            # Temporarily lower ErrorActionPreference so stderr warnings from hdfs.cmd don't trigger a script stop
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"

            # Use the explicit path to hdfs.cmd.
            # Remove 2>$null, which hide all outputs not the stderr warnings.
            $hadoopCp = (& $hdfsCmd classpath | Out-String).Trim()

            $ErrorActionPreference = $oldEap
        } catch {
            Write-LogMessage "Could not determine Hadoop classpath via explicit HADOOP_HOME path. Error: $($_.Exception.Message)" "WARNING"
        }
    } elseif (Get-Command hdfs -ErrorAction SilentlyContinue) {
        # Fallback to PATH only if HADOOP_HOME isn't set or invalid
        try {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $hadoopCp = (hdfs classpath | Out-String).Trim()
            $ErrorActionPreference = $oldEap
        } catch {
            Write-LogMessage "Could not determine Hadoop classpath via 'hdfs classpath'. Error: $($_.Exception.Message)" "WARNING"
        }
    } else {
        Write-LogMessage "'hdfs' command not found in HADOOP_HOME or system PATH." "WARNING"
    }

    # STRICT CHECK: Stop all if Hadoop classpath is empty
    if ([string]::IsNullOrWhiteSpace($hadoopCp)) {
        throw "Cannot load Hadoop classpath. Ensure HADOOP_HOME is set correctly and 'hdfs classpath' executes successfully."
    }

    $tokenGenCp = Join-Path $confInReg.ToolsPath $TOKEN_GEN_JAR_NAME

    # Filter out empty strings to prevent malformed classpaths (e.g., ";C:\path\to\jar")
    $cpParts = @($hadoopCp, $tokenGenCp) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $fullCp = $cpParts -join ";"

    # Temporarily unset variable to prevent recursion during MakeCredsFile run
    $savedEnv = Get-EnvVar "HADOOP_TOKEN_FILE_LOCATION"
    $env:HADOOP_TOKEN_FILE_LOCATION = $null

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        # Build arguments array to handle paths with spaces safely via Splatting
        $javaArgs = @(
            "-cp", "$fullCp",
            "$TOKEN_GEN_CLASS_NAME",
            $DestinationPath,
            "HDFS_DELEGATION_TOKEN", $HdfsTok, "$($confInReg.ServiceIp):$($confInReg.HdfsRpcPort)",
            "HDFS_DELEGATION_TOKEN", $HdfsTok, "$($confInReg.ServiceFqdn):$($confInReg.HdfsRpcPort)",
            "RM_DELEGATION_TOKEN",   $RmTok,   "$($confInReg.ServiceIp):$($confInReg.RmRpcPort)",
            "RM_DELEGATION_TOKEN",   $RmTok,   "$($confInReg.ServiceFqdn):$($confInReg.RmRpcPort)"
        )

        # Invoke Java binary helper using the EXPLICIT path
        $output = & $javaExe @javaArgs 2>&1
        $exitCode = $LASTEXITCODE

        if (-not $Quiet) {
            $output | ForEach-Object {
                # Safely convert ErrorRecord objects to strings before pattern matching
                $line = $_.ToString()
                if ($line -match "ERROR|Exception|Fail") {
                    Write-Host $line -ForegroundColor Red
                } else {
                    Write-Host $line
                }
            }
        }

        if ($exitCode -ne 0) { throw "MakeCredsFile failed with exit code $exitCode" }
        if (-not (Test-Path -LiteralPath $DestinationPath)) { throw "Target file $DestinationPath was not created by Java helper." }
    } finally {
        # Always restore previous preference states and environment variable
        $ErrorActionPreference = $savedEap
        $env:HADOOP_TOKEN_FILE_LOCATION = $savedEnv
    }

    # Lock down file permissions immediately after creation
    Protect-TokenFile $DestinationPath
}

# ==============================================================================
# EXECUTION BRANCH 2: ONE-OFF / BACKGROUND JOB (-Out)
# ==============================================================================

if ($Out) {
    Write-CredsFile -DestinationPath $Out -HdfsTok (New-HdfsToken) -RmTok (New-RmToken)
    exit 0
}

# ==============================================================================
# EXECUTION BRANCH 3: INTERACTIVE SESSION SETUP (DEFAULT)
# ==============================================================================

# Purge dead process sessions and reset current PID session state
Clear-OrphanSessions
Remove-Session $PID

# Ensure local token directory exists
if (-not (Test-Path $confInReg.TokenDir)) {
    New-Item -ItemType Directory -Path $confInReg.TokenDir -Force | Out-Null
}

# Target file path for the current process session
$tokenFilePath = Join-Path $confInReg.TokenDir "hadoop-$PID.dt"

# Fetch fresh tokens and write Java token file
$hdfsTok = New-HdfsToken
$rmTok   = New-RmToken
Write-CredsFile -DestinationPath $tokenFilePath -HdfsTok $hdfsTok -RmTok $rmTok

# Update Registry Session State
$sessionKey = Get-SessionKey $PID
New-Item -Path $sessionKey -Force | Out-Null
Set-ItemProperty -Path $sessionKey -Name "TokenFile" -Value $tokenFilePath -Type String -Force
Set-ItemProperty -Path $sessionKey -Name "HdfsToken" -Value $hdfsTok       -Type String -Force
Set-ItemProperty -Path $sessionKey -Name "RmToken"   -Value $rmTok         -Type String -Force

# Store creation time to detect PID reuse in orphan cleanup (using Round-trip format)
$creationTime = (Get-Date).ToString("o")
Set-ItemProperty -Path $sessionKey -Name "Created"   -Value $creationTime -Type String -Force

# Export environment variable for child processes (R, Python, Spark, etc.)
# CRITICAL FIX: Use "Process" scope, not "User". "User" persists across reboots and
# will point to a deleted PID-specific file on the next login, causing Hadoop client failures.
[Environment]::SetEnvironmentVariable("HADOOP_TOKEN_FILE_LOCATION", $tokenFilePath, "Process")
$env:HADOOP_TOKEN_FILE_LOCATION = $tokenFilePath

Write-LogMessage "Session tokens established ($(Get-EnvVar 'USERNAME'), renewer=$($confInReg.Renewer)): $tokenFilePath"
