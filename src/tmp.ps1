<#
.SYNOPSIS
    Multi-User Windows Server - User Scope JDK Detection Routine
.DESCRIPTION
    1. Checks User Environment Variable (JAVA_HOME).
    2. Validates existence of $JAVA_HOME\bin\java.exe.
    3. Validates execution and extracts Java version.
    4. Falls back to $env:LOCALAPPDATA\java\jdk-* scanning if needed.
#>

[CmdletBinding()]
param()

$CurrentUser = [Environment]::UserName

$JdkDetected     = $false
$ActiveJdkPath   = $null
$JavaMajorVer    = $null


# -------------------------------------------------------------------
# STEP 1: CDETECTING JDK FOR USER
# -------------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " DETECTING JDK FOR USER: $CurrentUser " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$UserJavaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", [EnvironmentVariableTarget]::User)

if (-not [string]::IsNullOrEmpty($UserJavaHome)) {
    Write-Host "[!] Found User JAVA_HOME: '$UserJavaHome'" -ForegroundColor Yellow

    # Clean trailing slashes
    $UserJavaHome = $UserJavaHome.TrimEnd('\')
    $JavaExePath  = Join-Path $UserJavaHome "bin\java.exe"

    # Test the jdk_path\bin\java.exe binary
    if (Test-Path $JavaExePath -PathType Leaf) {
        Write-Host "[+] Binary validated: '$JavaExePath' exists." -ForegroundColor Green

        # Test binary execution & capture version
        try {
            $VersionOutput = & $JavaExePath -version 2>&1 | Out-String
            if ($VersionOutput -match 'version "(?:1\.)?(\d+)') {
                $JavaMajorVer = [int]$Matches[1]
                $JdkDetected  = $true
                $ActiveJdkPath = $UserJavaHome

                Write-Host "[+] Execution Success: Java Major Version $JavaMajorVer detected." -ForegroundColor Green
            }
        } catch {
            Write-Host "[-] ERROR: java.exe failed to execute. The binary may be corrupted or blocked by AppLocker/SRP." -ForegroundColor Red
        }
    } else {
        Write-Host "[-] WARNING: JAVA_HOME is set, but 'bin\java.exe' was NOT found at '$JavaExePath'." -ForegroundColor Red
    }
} else {
    Write-Host "[i] No User-level JAVA_HOME environment variable set." -ForegroundColor Gray
}

# -------------------------------------------------------------------
# STEP 2: CDETECTING Hadoop FOR USER
# -------------------------------------------------------------------

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " DETECTING HADOOP FOR USER: $CurrentUser " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$UserHadoopHome = [Environment]::GetEnvironmentVariable("HADOOP_HOME", [EnvironmentVariableTarget]::User)

if (-not [string]::IsNullOrEmpty($UserHadoopHome)) {
    Write-Host "[!] Found User HADOOP_HOME: '$UserHadoopHome'" -ForegroundColor Yellow

    # Clean trailing slashes
    $UserHadoopHome = $UserHadoopHome.TrimEnd('\')
    $HadoopExePath  = Join-Path $UserHadoopHome "bin\winutils.exe"

    # Test the HADOOP_HOME\bin\winutils.exe binary
    if (Test-Path $HadoopExePath -PathType Leaf) {
        Write-Host "[+] Binary validated: '$HadoopExePath' exists." -ForegroundColor Green

        # Test binary execution & capture version
        try {
            $VersionOutput = & $HadoopExePath -version 2>&1 | Out-String
            if ($VersionOutput -match 'version "(?:1\.)?(\d+)') {
                $JavaMajorVer = [int]$Matches[1]
                $JdkDetected  = $true
                $ActiveJdkPath = $UserHadoopHome

                Write-Host "[+] Execution Success: Java Major Version $JavaMajorVer detected." -ForegroundColor Green
            }
        } catch {
            Write-Host "[-] ERROR: java.exe failed to execute. The binary may be corrupted or blocked by AppLocker/SRP." -ForegroundColor Red
        }
    } else {
        Write-Host "[-] WARNING: HADOOP_HOME is set, but 'bin\java.exe' was NOT found at '$HadoopExePath'." -ForegroundColor Red
    }
} else {
    Write-Host "[i] No User-level HADOOP_HOME environment variable set." -ForegroundColor Gray
}

# -------------------------------------------------------------------
# SUMMARY RESULT
# -------------------------------------------------------------------
$Result = [PSCustomObject]@{
    CurrentUser      = $CurrentUser
    JdkDetected      = $JdkDetected
    ActiveJdkPath    = $ActiveJdkPath
    JavaMajorVersion = $JavaMajorVer
    IsSpark4Compliant= ($JavaMajorVer -ge 17) # Spark 4.x requires Java 17+
}

Write-Host "`n------------------------------------------" -ForegroundColor Gray
Write-Host " DETECTION RESULTS FOR $CurrentUser " -ForegroundColor Gray
Write-Host "------------------------------------------" -ForegroundColor Gray
Write-Host "JDK Detected       : $JdkDetected"
Write-Host "Path               : $ActiveJdkPath"
Write-Host "Java Major Version : $JavaMajorVer"
Write-Host "Spark 4 Ready (17+): $($Result.IsSpark4Compliant)"
Write-Host "------------------------------------------`n" -ForegroundColor Gray

return $Result