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

# Enforce strict error handling for the main execution flow.
$ErrorActionPreference = "Stop"

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

    if ($Quiet) { return }

    switch ($Level) {
        "ERROR"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        "WARNING" { Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
        default   { Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
    }
    # Also send to verbose stream for pipeline compatibility
    Write-Verbose $Message
}

# ==============================================================================
# CONFIGURATION & SECURITY SETUP
# ==============================================================================

# Enforce strong TLS encryption (TLS 1.2 / TLS 1.3).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

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
    param([string]$filePath)
    if (-not (Test-Path $filePath)) { return }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        # Instantiate ACL object
        $acl = Get-Acl $filePath

        # Disable inheritance and remove inherited rules
        $acl.SetAccessRuleProtection($true, $false)

        # Safely remove existing explicit rules (copy to array to avoid collection modification during enumeration)
        $explicitRules = @($acl.Access | Where-Object { -not $_.IsInherited })
        foreach ($rule in $explicitRules) {
            $acl.RemoveAccessRule($rule) | Out-Null
        }

        # Define explicit access rules
        $accessRuleUser   = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "Allow")
        $accessRuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")

        $acl.AddAccessRule($accessRuleUser)
        $acl.AddAccessRule($accessRuleSystem)

        # Apply hardened ACL back to the file
        Set-Acl -Path $filePath -AclObject $acl
    } catch {
        Write-LogMessage "Failed to apply NTFS permissions to $filePath : $($_.Exception.Message)" "WARNING"
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
        SkipHttpErrorCheck    = $false
    }

    if ($Body)    { $params.Body = $Body; $params.ContentType = "application/json" }
    if ($Headers) { $params.Headers = $Headers }

    try {
        return (Invoke-RestMethod @params)
    } catch {
        $errorMessage = $_.Exception.Message

        # Robust error extraction for both PS 5.1 (WebException) and PS 7+ (HttpResponseException)
        if ($_.Exception.Response) {
            try {
                $responseBody = ""
                # PS 7+ / HttpResponseMessage
                if ($_.Exception.Response.GetType().Name -eq "HttpResponseMessage" -and $_.Exception.Response.Content) {
                    $responseBody = $_.Exception.Response.Content.ReadAsStringAsync().Result
                }
                # PS 5.1 / WebException
                elseif ($_.Exception.Response.GetResponseStream) {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $reader.BaseStream.Position = 0
                    $reader.DiscardBufferedData()
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                }

                # Fallback to built-in ErrorDetails if stream reading yields nothing
                if ([string]::IsNullOrWhiteSpace($responseBody) -and $_.ErrorDetails.Message) {
                    $responseBody = $_.ErrorDetails.Message
                }

                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    $errorMessage = "HTTP $($_.Exception.Response.StatusCode.value__) - $responseBody"
                }
            } catch {
                # Fallback if stream reading fails, keep original errorMessage
            }
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
    $endpoint = "$($confInReg.NameNodeWeb)/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=$($confInReg.Renewer)"
    $response = Invoke-Sso -Uri $endpoint
    $token = $response.Token.urlString

    if (-not $token) { throw "Empty HDFS token returned by NameNode." }
    return $token
}

<#
.SYNOPSIS
    Requests a YARN Delegation Token from the Resource Manager.
#>
function New-RmToken {
    $endpoint = "$($confInReg.RmWeb)/ws/v1/cluster/delegation-token"
    $body = @{ renewer = $confInReg.Renewer } | ConvertTo-Json
    $response = Invoke-Sso -Uri $endpoint -Method "POST" -Body $body
    $token = $response.token

    if (-not $token) { throw "Empty Resource Manager token returned." }
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
        $endpoint = "$($confInReg.NameNodeWeb)/webhdfs/v1/?op=CANCELDELEGATIONTOKEN&token=$Token"
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
        $endpoint = "$($confInReg.RmWeb)/ws/v1/cluster/delegation-token"
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
    return
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

    # Verify Java is available
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        throw "Java executable not found in system PATH. Please install Java or update PATH."
    }

    # Dynamically extract Hadoop Java classpath
    $hadoopCp = ""
    try {
        $hadoopCp = (hdfs classpath 2>$null | Out-String).Trim()
    } catch {
        Write-LogMessage "Could not determine Hadoop classpath via 'hdfs classpath'. Ensure Hadoop bin directory is in your system PATH." "WARNING"
    }
    $tokenGenCp = "$confInReg.ToolsPath/$TOKEN_GEN_JAR_NAME"
    $fullCp = "$hadoopCp;$tokenGenCp"

    # Temporarily unset variable to prevent recursion during MakeCredsFile run
    $savedEnv = $env:HADOOP_TOKEN_FILE_LOCATION
    $env:HADOOP_TOKEN_FILE_LOCATION = $null

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

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

    # Invoke Java binary helper
    $output = & java @javaArgs 2>&1
    $exitCode = $LASTEXITCODE

    # Restore previous preference states
    $ErrorActionPreference = $savedEap
    $env:HADOOP_TOKEN_FILE_LOCATION = $savedEnv

    if (-not $Quiet) {
        $output | ForEach-Object {
            if ($_ -match "ERROR|Exception|Fail") {
                Write-Host $_ -ForegroundColor Red
            } else {
                Write-Host $_
            }
        }
    }

    if ($exitCode -ne 0) { throw "MakeCredsFile failed with exit code $exitCode" }
    if (-not (Test-Path $DestinationPath)) { throw "Target file $DestinationPath was not created by Java helper." }

    # Lock down file permissions immediately after creation
    Protect-TokenFile $DestinationPath
}

# ==============================================================================
# EXECUTION BRANCH 2: ONE-OFF / BACKGROUND JOB (-Out)
# ==============================================================================

if ($Out) {
    Write-CredsFile -DestinationPath $Out -HdfsTok (New-HdfsToken) -RmTok (New-RmToken)
    return
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

Write-LogMessage "Session tokens established ($env:USERNAME, renewer=$($confInReg.Renewer)): $tokenFilePath"