# KitDroid: installa lo strumento "doppio clic su un .apk -> conferma -> installa in WSA" per l'utente corrente.
# Non serve essere amministratori, tranne per installare WSA stessa.
#
#   .\Setup.ps1 [-InstallWsa] [-EnableDeveloperMode] [-RestartExplorer] [-NoSmallIcons] [-Force] [-InstallDir <cartella>]
#
# -InstallWsa            se WSA manca, scarica e installa l'ultima build (vedi Install-Wsa.ps1); senza WSA Setup si ferma
# -EnableDeveloperMode   accende il debug di WSA senza chiedere (apre la porta ADB, vedi README)
# -RestartExplorer       riavvia Esplora risorse per caricare subito le icone
# -NoSmallIcons          non registra il gestore delle icone piccole (gira dentro explorer.exe)
# -Force                 riscarica ADB e aapt2 e ricompila
# -InstallDir            dove installare, default %LOCALAPPDATA%\WSA-ApkInstaller

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'WSA-ApkInstaller'),
    [switch]$NoSmallIcons,
    [switch]$InstallWsa,
    [switch]$EnableDeveloperMode,
    [switch]$RestartExplorer,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'      # senza barra di avanzamento Invoke-WebRequest è molto più veloce
$Kit = $PSScriptRoot

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "    ok: $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "    warning: $Text" -ForegroundColor Yellow }

# ---------- 0. controlli ----------
Step 'Checking prerequisites'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is required.' }
if ($PSVersionTable.PSVersion.Major -ne 5) { Warn "Written for Windows PowerShell 5.1 (this is $($PSVersionTable.PSVersion)); run it with powershell.exe if something fails." }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found ($csc). Enable the .NET Framework 4.x feature of Windows." }
$fw = Split-Path $csc
foreach ($f in 'src\ApkShell.cs', 'src\Launcher.cs', 'scripts\ApkInstaller.ps1', 'scripts\strings.json', 'scripts\Build-Assets.ps1', 'scripts\Register-Association.ps1', 'Enable-WsaDeveloperMode.ps1', 'Install-Wsa.ps1') {
    if (-not (Test-Path (Join-Path $Kit $f))) { throw "Kit file missing: $f" }
}
$wsaPackage = 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
$wsa = Get-AppxPackage -Name $wsaPackage -ErrorAction SilentlyContinue
if ($wsa) {
    Ok "WSA $($wsa.Version) is installed"
    if ($wsa.Version -ne '2407.40000.4.0') { Warn 'The kit was made and tested with WSA 2407.40000.4.0; this version may behave differently.' }
} else {
    # senza WSA non c'è niente da configurare
    Warn 'Windows Subsystem for Android is NOT installed.'
    Write-Host '    The kit takes it from the community repository https://github.com/MustardChef/WSABuilds/releases (newest build).'
    $doInstall = [bool]$InstallWsa
    if (-not $doInstall -and [Environment]::UserInteractive) {
        $doInstall = $Host.UI.PromptForChoice('Install WSA', 'Download the newest build (about 550 MB) and install it now?', @('&Yes', '&No'), 1) -eq 0
    }
    if (-not $doInstall) {
        throw 'WSA is missing, so nothing was installed. Run Setup.ps1 -InstallWsa (or .\Install-Wsa.ps1), or install WSA yourself, then run Setup.ps1 again.'
    }
    & (Join-Path $Kit 'Install-Wsa.ps1') -Force
    $wsa = Get-AppxPackage -Name $wsaPackage -ErrorAction SilentlyContinue
    if (-not $wsa) { throw 'WSA is still missing after the installation attempt, so nothing else was installed.' }
    Ok "WSA $($wsa.Version) is installed"
}
Ok "install folder: $InstallDir"
New-Item -ItemType Directory -Force $InstallDir, "$InstallDir\bin" | Out-Null

# ---------- 1. strumenti ----------
$adbExe  = Join-Path $InstallDir 'bin\adb\adb.exe'
$aaptExe = Join-Path $InstallDir 'bin\aapt2\aapt2.exe'

function Get-File([string]$Url, [string]$File) {
    Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing -TimeoutSec 300
}

if ($Force -or -not (Test-Path $adbExe)) {
    Step 'Downloading ADB (platform-tools) from Google'
    [xml]$repo = (Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/repository2-3.xml' -UseBasicParsing -TimeoutSec 120).Content
    $pkg = $repo.'sdk-repository'.remotePackage | Where-Object { $_.path -eq 'platform-tools' } | Select-Object -First 1
    $arc = $pkg.archives.archive | Where-Object { $_.'host-os' -eq 'windows' } | Select-Object -First 1
    $url = 'https://dl.google.com/android/repository/' + $arc.complete.url
    $sha1 = $arc.complete.checksum.'#text'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wsaapk_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'platform-tools.zip'
        Get-File $url $zip
        $got = (Get-FileHash $zip -Algorithm SHA1).Hash
        if ($got -ne $sha1.ToUpper()) { throw "platform-tools checksum mismatch (expected $sha1, got $got)" }
        Ok "SHA-1 matches Google's repository manifest ($($arc.complete.url))"
        Expand-Archive $zip -DestinationPath (Join-Path $tmp 'x') -Force
        if (Test-Path "$InstallDir\bin\adb") { & $adbExe kill-server 2>$null; Remove-Item "$InstallDir\bin\adb" -Recurse -Force }
        Move-Item (Join-Path $tmp 'x\platform-tools') "$InstallDir\bin\adb"
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $sig = Get-AuthenticodeSignature $adbExe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=Google LLC') { throw "adb.exe is not signed by Google LLC (status: $($sig.Status))" }
    Ok 'adb.exe is signed by Google LLC'
} else { Ok 'ADB already installed (use -Force to download again)' }

if ($Force -or -not (Test-Path $aaptExe)) {
    Step 'Downloading aapt2 from Google Maven'
    $ver = '9.5.0-16666295'
    $url = "https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/$ver/aapt2-$ver-windows.jar"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wsaapk_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $jar = Join-Path $tmp 'aapt2.zip'
        Get-File $url $jar
        $expected = [Text.Encoding]::ASCII.GetString((Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing -TimeoutSec 60).Content).Trim().Split(' ')[0]
        $got = (Get-FileHash $jar -Algorithm SHA256).Hash
        if ($got -ne $expected.ToUpper()) { throw "aapt2 checksum mismatch (expected $expected, got $got)" }
        Ok "SHA-256 matches the one published next to the file on Google Maven ($ver)"
        Expand-Archive $jar -DestinationPath (Join-Path $tmp 'x') -Force
        if (Test-Path "$InstallDir\bin\aapt2") { Remove-Item "$InstallDir\bin\aapt2" -Recurse -Force }
        New-Item -ItemType Directory "$InstallDir\bin\aapt2" | Out-Null
        Copy-Item (Join-Path $tmp 'x\aapt2.exe') $aaptExe
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
} else { Ok 'aapt2 already installed (use -Force to download again)' }

# ---------- 2. compilazione ----------
Step 'Drawing icons'
& (Join-Path $Kit 'scripts\Build-Assets.ps1') -OutDir $InstallDir
Ok 'apk.ico, droid.png'

Step 'Compiling launcher and Explorer extension'
Remove-Item "$InstallDir\*.old.*" -Force -ErrorAction SilentlyContinue      # copie messe da parte da un'esecuzione precedente
function Compile([string]$Out, [string[]]$CscArgs, [string[]]$Inputs) {
    $target = Join-Path $InstallDir $Out
    # se sorgenti e opzioni non sono cambiati non ricompilo (e non tocco una DLL già caricata da Explorer)
    $mark = Join-Path $InstallDir ".build-$Out.sha256"
    $text = (($Inputs | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash }) -join '') + '|' + ($CscArgs -join ' ')
    $sig = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '')
    if (-not $Force -and (Test-Path $target) -and (Test-Path $mark) -and ((Get-Content $mark -Raw).Trim() -eq $sig)) { Ok "$Out is up to date"; return }
    # csc dà all'assembly il nome del file di output: compilo col nome finale in una cartella temporanea e poi sposto
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('wsaapk_build_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $stage | Out-Null
    try {
        $built = Join-Path $stage $Out
        & $csc /nologo /optimize+ "/out:$built" @CscArgs
        if ($LASTEXITCODE -ne 0) { throw "csc failed for $Out" }
        if (Test-Path $target) {
            try { Move-Item $built $target -Force }
            catch {
                $old = "$target.old." + [guid]::NewGuid().ToString('N').Substring(0, 8)
                Move-Item $target $old -Force
                Move-Item $built $target -Force
                Warn "$Out was in use; the previous copy was renamed to $(Split-Path $old -Leaf) (delete it after signing out)"
            }
        } else { Move-Item $built $target }
        Set-Content -Path $mark -Value $sig
        Ok "$Out built"
    } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
Compile 'ApkInstallerLauncher.exe' @('/target:winexe', "/win32icon:$InstallDir\apk.ico", (Join-Path $Kit 'src\Launcher.cs')) @((Join-Path $Kit 'src\Launcher.cs'), "$InstallDir\apk.ico")

$wb = (Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\WindowsBase" -Recurse -Filter WindowsBase.dll | Select-Object -First 1).FullName
$refs = @("$fw\System.Drawing.dll", "$fw\System.IO.Compression.dll", "$fw\System.Core.dll", "$fw\System.Xaml.dll", "$fw\WPF\PresentationCore.dll", $wb) | ForEach-Object { "/r:$_" }
Compile 'ApkShell.dll' (@('/target:library') + $refs + (Join-Path $Kit 'src\ApkShell.cs')) @((Join-Path $Kit 'src\ApkShell.cs'))

# ---------- 3. script ----------
Step 'Copying scripts'
Copy-Item (Join-Path $Kit 'scripts\ApkInstaller.ps1') $InstallDir -Force
Copy-Item (Join-Path $Kit 'scripts\strings.json') $InstallDir
Copy-Item (Join-Path $Kit 'scripts\Register-Association.ps1') $InstallDir -Force
Copy-Item (Join-Path $Kit 'scripts\Remove-Association.ps1') $InstallDir -Force
Copy-Item (Join-Path $Kit 'Enable-WsaDeveloperMode.ps1') $InstallDir -Force
Ok 'ApkInstaller.ps1, Enable-WsaDeveloperMode.ps1'

# ---------- 4. registrazione ----------
Step 'Registering .apk (current user)'
$regArgs = @{ InstallDir = $InstallDir }
if ($NoSmallIcons) { $regArgs.NoSmallIcons = $true }
& (Join-Path $InstallDir 'Register-Association.ps1') @regArgs

# il gestore delle icone gira dentro explorer.exe: lo lascio registrato solo se si carica
if (-not $NoSmallIcons) {
    $loaded = $false
    try {
        $t = [Type]::GetTypeFromCLSID([guid]'{2D9E6B14-8F3A-4C75-A1B0-5E7C93D4F206}')
        $o = [Activator]::CreateInstance($t)
        $loaded = $o -is [System.Runtime.InteropServices.ComTypes.IPersistFile]
    } catch { }
    if ($loaded) { Ok 'the Explorer icon handler loads correctly' }
    else {
        Warn 'the icon handler could not be loaded: leaving it unregistered (Details/List views keep the robot icon)'
        & (Join-Path $InstallDir 'Register-Association.ps1') -InstallDir $InstallDir -NoSmallIcons | Out-Null
    }
}

# ---------- 5. debug di WSA (serve per installare gli APK) ----------
$devModeDone = $false
if ($wsa) {
    $doDev = [bool]$EnableDeveloperMode
    if (-not $doDev -and [Environment]::UserInteractive) {
        Write-Host ''
        Write-Host '    Installing APKs needs WSA Developer mode. While it is on, WSA accepts ADB connections without asking,' -ForegroundColor Yellow
        Write-Host '    from this PC and from the private networks (turn it off with Enable-WsaDeveloperMode.ps1 -Disable).' -ForegroundColor Yellow
        $doDev = $Host.UI.PromptForChoice('WSA Developer mode', 'Turn it on now? (WSA is restarted once if needed: Android apps that are open are closed)', @('&Yes', '&No'), 1) -eq 0
    }
    if ($doDev) {
        Step 'Enabling WSA Developer mode'
        try {
            & (Join-Path $Kit 'Enable-WsaDeveloperMode.ps1') -AdbPath $adbExe -Force
            $devModeDone = $true
        } catch {
            # il resto è già installato: il popup potrà farlo al primo uso
            Warn "could not turn on Developer mode now: $($_.Exception.Message)"
        }
    }
}

# ---------- 6. Explorer ----------
if ($RestartExplorer) {
    Step 'Restarting Explorer'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Ok 'Explorer restarted: the new icons are active'
}

Step 'Done'
Write-Host "    Double-click an .apk to install it. Folder: $InstallDir"
if (-not $devModeDone) { Write-Host '    WSA Developer mode was not turned on: the install dialog offers a button to turn it on the first time you install an app.' -ForegroundColor Yellow }
if (-not $RestartExplorer) {
    Write-Host '    Icons in Explorer: if you see the old icons, restart Explorer (Setup.ps1 -RestartExplorer) or sign out and in.' -ForegroundColor Yellow
}
