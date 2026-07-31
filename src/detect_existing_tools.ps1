<#
.SYNOPSIS
    Step 1: Detects existing Spark installations on Windows Server.
#>
[CmdletBinding()]
param()

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 1: DETECTING EXISTING SPARK INSTALL " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$SparkDetected = $false
$ExistingPath = $null

# Check System Environment Variable
$SparkHomeEnv = [Environment]::GetEnvironmentVariable("SPARK_HOME", [EnvironmentVariableTarget]::Machine)

if (-not [string]::IsNullOrEmpty($SparkHomeEnv)) {
    Write-Host "[!] SPARK_HOME environment variable found: $SparkHomeEnv" -ForegroundColor Yellow
    if (Test-Path $SparkHomeEnv) {
        $SparkDetected = $true
        $ExistingPath = $SparkHomeEnv
    }
}

# Check Common Installation Paths
$CommonPaths = @("C:\spark", "C:\BigData\spark", "C:\hadoop\spark")
foreach ($Path in $CommonPaths) {
    if (Test-Path "$Path\bin\spark-submit.cmd") {
        Write-Host "[!] Spark binary detected at path: $Path" -ForegroundColor Yellow
        $SparkDetected = $true
        $ExistingPath = $Path
    }
}

$Result = [PSCustomObject]@{
    IsInstalled   = $SparkDetected
    DetectedPath  = $ExistingPath
}

if ($SparkDetected) {
    Write-Host "[-] Detection Complete: Spark is ALREADY installed at '$ExistingPath'." -ForegroundColor Yellow
} else {
    Write-Host "[+] Detection Complete: No existing Spark installation detected." -ForegroundColor Green
}

return $Result