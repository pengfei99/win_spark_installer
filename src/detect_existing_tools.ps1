<#
.SYNOPSIS
    Step 1: Detects existing Java installations on Windows Server.
    Step 2: Detects existing hadoop installations on Windows Server.
    Step 3: Detects existing Spark installations on Windows Server.
#>
[CmdletBinding()]
param()

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 1: DETECTING EXISTING JDK INSTALL " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Acquire the active user's identity dynamically
$CurrentUser = [Environment]::UserName
$UserAppData  = $env:LOCALAPPDATA

$JdkDetected = $false
$JdkPath     = $null

# step1. Detects existing Java installations on Windows Server.

# 1.1 Check Environment Variable of the user account
$JdkEnvName="JAVA_HOME"
$JdkEnvVal = [Environment]::GetEnvironmentVariable($JdkEnvName, [EnvironmentVariableTarget]::Machine)

if (-not [string]::IsNullOrEmpty($JdkEnvVal)) {
    Write-Host "[!] $JdkEnvName environment variable found: $JdkEnvVal" -ForegroundColor Yellow
    if (Test-Path "$JdkEnvVal\bin\java.exe") {
        $JdkDetected = $true
        $JdkExistingPath = $JdkEnvVal
    }
}

# 1.2 if no env var set for jdk or jdk path invalid, check JDK Installation Path manually
$_ExpectedJdkPath = "C:\Users\" + $_currentUser + "\AppData\Local\java\"

if (Test-Path "$_ExpectedJdkPath\bin\java.exe") {
    Write-Host "[!] Spark binary detected at path: $Path" -ForegroundColor Yellow
    $JdkDetected = $true
    $JdkExistingPath = $_ExpectedJdkPath
}


$Result = [PSCustomObject]@{
    JdkIsInstalled   = $JdkDetected
    JdkPath  = $JdkExistingPath
}

if ($JdkDetected) {
    Write-Host "[-] Detection Complete: JDK is ALREADY installed at '$JdkExistingPath'." -ForegroundColor Yellow
} else {
    Write-Host "[+] Detection Complete: No existing JDK installation detected." -ForegroundColor Green
}

return $Result