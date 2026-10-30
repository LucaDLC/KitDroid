# Accende (o spegne con -Disable) la modalità sviluppatore di WSA dalle sue impostazioni e controlla che ADB sia
# autorizzato. La modalità sviluppatore apre la porta ADB di WSA (127.0.0.1:58526), che serve per installare gli APK.
#
#   .\Enable-WsaDeveloperMode.ps1 [-Disable] [-Force] [-AdbPath <adb.exe>]
#
# Dopo la prima installazione di WSA può capitare che ADB risponda "unauthorized" senza che WSA mostri nessuna
# richiesta da accettare: basta riavviare WSA una volta (chiude le app Android aperte). Lo script lo fa da solo,
# solo in quel caso, e con -Force senza chiedere.
#
# Attenzione: a modalità sviluppatore accesa ADB accetta qualsiasi client senza chiedere, da questo PC e dalle reti
# Private. Su reti di cui non ti fidi spegnila con -Disable.
[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Force,
    [string]$AdbPath = (Join-Path $env:LOCALAPPDATA 'WSA-ApkInstaller\bin\adb\adb.exe')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$AppId    = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
$WsaClient = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\WsaClient.exe'
$Port     = 58526
$Endpoint = "127.0.0.1:$Port"

function Say([string]$t) { Write-Host "    $t" }
function Test-Port { try { [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) } catch { $false } }
function Wait-Until([scriptblock]$Cond, [int]$Seconds) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $end) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 700 }
    $false
}

if (-not (Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForAndroid' -ErrorAction SilentlyContinue)) { throw 'WSA is not installed.' }
if (-not (Test-Path $WsaClient)) { throw "WsaClient.exe alias not found: $WsaClient" }

function Get-SettingsWindow {
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'ApplicationFrameWindow')
    foreach ($w in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $cond)) {
        $nav = $w.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'LeftPaneAdvanced')))
        if ($nav) { return $w }
    }
    $null
}

function Find-ById($Root, [string]$Id) {
    $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)))
}

# ---------- 1. interruttore ----------
$want = if ($Disable) { 'Off' } else { 'On' }

# WSA si spegne da solo senza app aperte e da spento le sue impostazioni non si aprono: lo avvio prima
if (-not (Get-Process vmmemWSA -ErrorAction SilentlyContinue)) {
    Say 'Starting WSA...'
    Start-Process -FilePath $WsaClient -ArgumentList '/launch', 'wsa://system' -WindowStyle Hidden
    if (-not (Wait-Until { [bool](Get-Process vmmemWSA -ErrorAction SilentlyContinue) } 90)) { throw 'WSA did not start.' }
    Start-Sleep -Seconds 6
}

Say "Opening WSA Settings to set Developer mode $want"
$win = $null
for ($attempt = 1; $attempt -le 2 -and -not $win; $attempt++) {
    Stop-Process -Name WsaSettings -ErrorAction SilentlyContinue      # un'istanza rimasta nascosta non mostrerebbe mai la finestra
    Start-Sleep -Milliseconds 800
    Start-Process explorer.exe "shell:appsFolder\$AppId!SettingsApp"
    [void](Wait-Until { $script:win = Get-SettingsWindow; [bool]$script:win } 40)
}
if (-not $win) { throw 'The WSA Settings window did not appear. Open WSA once (any Android app), wait a few seconds and run this again.' }

# l'interruttore sta in "Impostazioni avanzate" (AutomationId, uguali in tutte le lingue)
$nav = Find-ById $win 'LeftPaneAdvanced'
$nav.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
$toggle = $null
[void](Wait-Until { $script:toggle = Find-ById $win 'DeveloperModeToggle'; [bool]$script:toggle } 15)
if (-not $toggle) { throw 'Developer mode toggle not found: this WSA version has a different Settings layout.' }
$tp = $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
if ("$($tp.Current.ToggleState)" -ne $want) {
    $tp.Toggle()
    Say "Developer mode switched $want"
} else {
    Say "Developer mode was already $want"
}
Start-Sleep -Seconds 2
Stop-Process -Name WsaSettings -ErrorAction SilentlyContinue

if ($Disable) {
    if (Wait-Until { -not (Test-Port) } 20) { Say 'ADB port closed.' } else { Write-Warning 'The ADB port is still open.' }
    return
}

# ---------- 2. autorizzazione ADB ----------
if (-not (Wait-Until { Test-Port } 30)) { throw "Developer mode is on but nothing listens on port $Port. Start WSA (open any Android app) and run this again." }
if (-not (Test-Path $AdbPath)) { Say "adb.exe not found at ${AdbPath}, skipping the authorization check."; return }

function Invoke-Adb([string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo $AdbPath, ($Arguments -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(20000)) { $p.Kill(); return '' }
    $o.Result + $e.Result
}
function Get-AdbState {
    [void](Invoke-Adb @('connect', $Endpoint))
    $line = (Invoke-Adb @('devices')) -split "\r?\n" | Where-Object { $_ -like "$Endpoint*" } | Select-Object -First 1
    if ($line) { ($line -split '\s+')[1] } else { '' }
}

# avvio il server adb senza aspettarlo (resta attivo in background)
$srvPsi = New-Object Diagnostics.ProcessStartInfo $AdbPath, 'start-server'
$srvPsi.UseShellExecute = $false; $srvPsi.CreateNoWindow = $true
[void][Diagnostics.Process]::Start($srvPsi).WaitForExit(20000)

$state = Get-AdbState
Say "ADB state: ${state}"
if ($state -eq 'device') { Say 'ADB is authorized. Nothing else to do.'; return }

if ($state -ne 'unauthorized') { throw "ADB state is '$state' (expected 'device' or 'unauthorized')." }

Say "ADB is 'unauthorized' and WSA shows no prompt to accept: WSA has to restart once."
if (-not $Force) {
    if (-not [Environment]::UserInteractive) { throw 'Restart needed: run again with -Force (it closes the Android apps that are running).' }
    $ans = $Host.UI.PromptForChoice('Restart WSA', 'Restarting closes the Android apps that are running. Continue?', @('&Yes', '&No'), 1)
    if ($ans -ne 0) { Say 'Cancelled. Restart WSA yourself (WSA Settings > System > turn off the subsystem) and run this again.'; return }
}
[void](Invoke-Adb @('disconnect'))
Start-Process -FilePath $WsaClient -ArgumentList '/shutdown' -WindowStyle Hidden -Wait
[void](Wait-Until { -not (Get-Process vmmemWSA -ErrorAction SilentlyContinue) } 40)
Start-Process -FilePath $WsaClient -ArgumentList '/launch', 'wsa://system' -WindowStyle Hidden
if (-not (Wait-Until { Test-Port } 90)) { throw 'WSA did not come back (port still closed).' }
$ok = Wait-Until { (Get-AdbState) -eq 'device' } 60
if ($ok) { Say 'ADB is authorized.' } else { throw "ADB is still not authorized (state: $(Get-AdbState))." }
