# Installation script
$InstallScript = "C:\Users\pliu\Documents\git\win_spark_installer\src\install_spark.ps1"

# Current user's desktop
$Desktop = [Environment]::GetFolderPath("Desktop")
$ShortcutPath = Join-Path $Desktop "Install Spark.lnk"

# Windows PowerShell 5.1
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# Create shortcut
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)

$Shortcut.TargetPath = $PowerShellExe
$Shortcut.Arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$InstallScript`""
$Shortcut.WorkingDirectory = Split-Path $InstallScript
$Shortcut.Description = "Install Spark"

# Optional: use a custom icon
# $Shortcut.IconLocation = "C:\MyInstaller\installer.ico"

$Shortcut.Save()

Write-Host "Shortcut created successfully: $ShortcutPath"