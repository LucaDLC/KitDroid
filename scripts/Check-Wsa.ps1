# Mostra lo stato di WSA e di KitDroid: pacchetto, avvio, debug, ADB, installazione del kit e ultima build disponibile.
# Non modifica niente.
$ErrorActionPreference = 'Continue'
$Kit = Split-Path $PSScriptRoot -Parent
$InstallDir = Join-Path $env:LOCALAPPDATA 'WSA-ApkInstaller'
$Port = 58526

function Row([string]$Name, [string]$Value, [string]$State = 'info') {
    $color = switch ($State) { 'ok' { 'Green' } 'bad' { 'Red' } 'warn' { 'Yellow' } default { 'Gray' } }
    Write-Host ('  {0,-26} ' -f $Name) -NoNewline
    Write-Host $Value -ForegroundColor $color
}

Write-Host 'WSA' -ForegroundColor Cyan
$pkg = Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue
if ($pkg) {
    Row 'Installed' "yes, version $($pkg.Version)" 'ok'
    Row 'Folder' $pkg.InstallLocation
    Row 'Package status' "$($pkg.Status)" $(if ("$($pkg.Status)" -eq 'Ok') { 'ok' } else { 'bad' })
} else {
    Row 'Installed' 'NO (run option 1: it offers to install it)' 'bad'
}

$running = [bool](Get-Process vmmemWSA -ErrorAction SilentlyContinue)
Row 'Running' $(if ($running) { 'yes' } else { 'no (it stops by itself when no Android app is open)' }) $(if ($running) { 'ok' } else { 'warn' })

$portOpen = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
Row 'Developer mode (port 58526)' $(if ($portOpen) { 'on (ADB port open)' } elseif ($running) { 'off' } else { 'unknown, WSA is not running' }) $(if ($portOpen) { 'ok' } else { 'warn' })

$adb = Join-Path $InstallDir 'bin\adb\adb.exe'
if ($portOpen -and (Test-Path $adb)) {
    $srv = New-Object Diagnostics.ProcessStartInfo $adb, 'start-server'
    $srv.UseShellExecute = $false; $srv.CreateNoWindow = $true
    try { [void][Diagnostics.Process]::Start($srv).WaitForExit(15000) } catch { }
    $psi = New-Object Diagnostics.ProcessStartInfo $adb, "connect 127.0.0.1:$Port"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    try { $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); [void]$p.WaitForExit(15000) } catch { }
    $psi2 = New-Object Diagnostics.ProcessStartInfo $adb, 'devices'
    $psi2.UseShellExecute = $false; $psi2.CreateNoWindow = $true; $psi2.RedirectStandardOutput = $true
    $state = ''
    try {
        $p2 = [Diagnostics.Process]::Start($psi2); $t = $p2.StandardOutput.ReadToEndAsync(); [void]$p2.WaitForExit(15000)
        $line = ($t.Result -split "\r?\n" | Where-Object { $_ -like "127.0.0.1:$Port*" } | Select-Object -First 1)
        if ($line) { $state = ($line -split '\s+')[1] }
    } catch { }
    switch ($state) {
        'device'       { Row 'ADB' 'authorized, ready to install' 'ok' }
        'unauthorized' { Row 'ADB' 'unauthorized: the install popup (or Enable-WsaDeveloperMode.ps1) restarts WSA to fix it' 'bad' }
        default        { Row 'ADB' "no answer ($state)" 'warn' }
    }
} else {
    Row 'ADB' 'not checked (needs WSA running with developer mode on)'
}

Write-Host "`nKitDroid" -ForegroundColor Cyan
$files = 'ApkInstallerLauncher.exe', 'ApkShell.dll', 'ApkInstaller.ps1', 'strings.json', 'bin\adb\adb.exe', 'bin\aapt2\aapt2.exe'
$missing = @($files | Where-Object { -not (Test-Path (Join-Path $InstallDir $_)) })
if (-not (Test-Path $InstallDir)) { Row 'Installed' "no ($InstallDir not found)" 'bad' }
elseif ($missing.Count) { Row 'Installed' ('incomplete, missing: ' + ($missing -join ', ')) 'bad' }
else { Row 'Installed' "yes ($InstallDir)" 'ok' }
$assoc = (Get-ItemProperty 'HKCU:\Software\Classes\.apk' -ErrorAction SilentlyContinue).'(default)'
Row '.apk double-click' $(if ($assoc -eq 'WSA.ApkInstaller') { 'handled by KitDroid' } else { 'not handled by KitDroid' }) $(if ($assoc -eq 'WSA.ApkInstaller') { 'ok' } else { 'warn' })

Write-Host "`nNewest WSA build in the repository" -ForegroundColor Cyan
try { & (Join-Path $Kit 'Install-Wsa.ps1') -CheckOnly -IgnoreExisting 6>&1 | Where-Object { "$_" -match 'Newest|Release|File' } | ForEach-Object { "$_" } }
catch { Row 'Repository' ($_.Exception.Message -split "`n")[0] 'bad' }
