# Toglie ciò che ha installato Setup.ps1: associazione .apk, anteprime e icone (HKCU) e cartella di installazione.
# Non tocca WSA né la sua modalità sviluppatore.
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'WSA-ApkInstaller')
)
$ErrorActionPreference = 'Continue'
$Kit = $PSScriptRoot

Write-Host '==> Removing the .apk association' -ForegroundColor Cyan
& (Join-Path $Kit 'scripts\Remove-Association.ps1')

Write-Host '==> Removing files' -ForegroundColor Cyan
$adb = Join-Path $InstallDir 'bin\adb\adb.exe'
if (Test-Path $adb) {
    $psi = New-Object Diagnostics.ProcessStartInfo $adb, 'kill-server'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    try { [void][Diagnostics.Process]::Start($psi).WaitForExit(15000) } catch { }
}
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        $left = Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue
        Write-Host "    Some files are still in use by Explorer: $(($left | ForEach-Object Name) -join ', ')" -ForegroundColor Yellow
        Write-Host "    Sign out (or restart Explorer) and delete the folder: $InstallDir" -ForegroundColor Yellow
    } else { Write-Host '    install folder removed' -ForegroundColor Green }
}

Write-Host "`nNote: Windows may have created an inbound firewall rule named 'adb.exe' when the ADB server first ran." -ForegroundColor Yellow
Write-Host "      Remove it from an administrator PowerShell:  Get-NetFirewallRule -DisplayName 'adb.exe' | Remove-NetFirewallRule" -ForegroundColor Yellow
