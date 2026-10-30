# Registra per l'utente corrente (HKCU, senza admin) tutto ciò che serve per i file .apk:
#   doppio clic    -> ApkInstallerLauncher.exe (apre il popup)
#   icone grandi   -> provider di anteprime di ApkShell (icona dell'app)
#   icone piccole  -> gestore di icone di ApkShell (icona dell'app, altrimenti il robot)
# Per annullare: Remove-Association.ps1. Si può rilanciare.
#
# Registers for the current user (HKCU, no admin) everything needed for .apk files:
# double-click    -> ApkInstallerLauncher.exe (opens the popup)
# large icons   -> ApkShell thumbnail provider (app icon)
# small icons  -> ApkShell icon handler (app icon, otherwise the robot)
# To undo: Remove-Association.ps1. It can be run again.
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [switch]$NoSmallIcons      # non registra il gestore di icone (gira dentro explorer.exe): Dettagli ed Elenco restano col robot / does not register the icon handler (runs inside explorer.exe): Details and List keep the robot
)
$ErrorActionPreference = 'Stop'

$exe = Join-Path $InstallDir 'ApkInstallerLauncher.exe'
$ico = Join-Path $InstallDir 'apk.ico'
$dll = Join-Path $InstallDir 'ApkShell.dll'
foreach ($f in $exe, $ico) { if (-not (Test-Path $f)) { throw "Missing file: $f" } }

$progId      = 'WSA.ApkInstaller'
$cls         = 'HKCU:\Software\Classes'
$thumbClsid  = '{7B3F2A6E-5C1D-4E8B-9A44-0D6C1F2E8A91}'
$iconClsid   = '{2D9E6B14-8F3A-4C75-A1B0-5E7C93D4F206}'
$thumbIface  = '{e357fccd-a995-4576-b01f-234630154e96}'   # chiave di IThumbnailProvider / IThumbnailProvider key

function Set-Default([string]$Path, $Value) {
    New-Item -Path $Path -Force | Out-Null
    Set-ItemProperty -Path $Path -Name '(default)' -Value $Value
}

function Register-ComClass([string]$Clsid, [string]$Class, [string]$Title) {
    $srv = "$cls\CLSID\$Clsid\InprocServer32"
    Set-Default "$cls\CLSID\$Clsid" $Title
    Set-Default $srv (Join-Path $env:WINDIR 'System32\mscoree.dll')
    Set-ItemProperty -Path $srv -Name 'ThreadingModel' -Value 'Both'
    Set-ItemProperty -Path $srv -Name 'Class' -Value $Class
    Set-ItemProperty -Path $srv -Name 'Assembly' -Value 'ApkShell, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null'
    Set-ItemProperty -Path $srv -Name 'RuntimeVersion' -Value 'v4.0.30319'
    Set-ItemProperty -Path $srv -Name 'CodeBase' -Value ('file:///' + ($dll -replace '\\', '/'))
}

# --- tipo di file, comando, icona di default / file type, command, default icon ---
Set-Default "$cls\$progId" 'Pacchetto Android (installa in WSA)'
Set-Default "$cls\$progId\DefaultIcon" "`"$ico`""
Set-Default "$cls\$progId\shell\open" 'Installa in WSA'
Set-Default "$cls\$progId\shell\open\command" "`"$exe`" `"%1`""
Set-Default "$cls\.apk" $progId
Set-ItemProperty -Path "$cls\.apk" -Name 'Content Type' -Value 'application/vnd.android.package-archive'

# --- anteprime (icone grandi) / thumbnails (large icons) ---
if (Test-Path $dll) {
    Register-ComClass $thumbClsid 'ApkShell.ApkThumbnailProvider' 'APK thumbnail provider (WSA)'
    foreach ($k in '.apk', $progId) { Set-Default "$cls\$k\ShellEx\$thumbIface" $thumbClsid }
}

# --- icone piccole (Dettagli, Elenco) / small icons (Details, List) ---
# DefaultIcon = %1 dice a Explorer che l'icona dipende dal file; il gestore dà apk.ico agli APK senza icona.
#
# DefaultIcon = %1 tells Explorer that the icon depends on the file; the handler gives apk.ico to APKs without an icon.
if ((Test-Path $dll) -and -not $NoSmallIcons) {
    Register-ComClass $iconClsid 'ApkShell.ApkIconHandler' 'APK icon handler (WSA)'
    Set-Default "$cls\$progId\ShellEx\IconHandler" $iconClsid
    Set-Default "$cls\$progId\DefaultIcon" '%1'
} else {
    Remove-Item -Path "$cls\$progId\ShellEx\IconHandler" -Recurse -Force -ErrorAction SilentlyContinue
}

# valore messo da una versione precedente, ora inutile
# value set by an earlier version, now unused
foreach ($k in '.apk', $progId) { Remove-ItemProperty -Path "$cls\$k" -Name 'ThumbnailCutoff' -ErrorAction SilentlyContinue }

Add-Type -Namespace Win32 -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
[Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)   # SHCNE_ASSOCCHANGED
'Association registered for the current user: .apk -> ' + $exe
