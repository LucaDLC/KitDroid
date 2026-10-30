# Installa WSA se manca, prendendo l'ultima build dal repository della community
# https://github.com/MustardChef/WSABuilds/releases: la release più recente per Windows 11 x64 che ha il file
# WSA_<versione>_x64_Release-Nightly-NoGApps-NoAmazon.7z. Controlla dimensione e SHA-256 pubblicati da GitHub.
# Se il repository o il file non ci sono, si ferma con un errore e non fa altro.
# Poi estrae l'archivio e lancia il suo Install.ps1 come amministratore (UAC). La cartella di WSA va lasciata dov'è.
#
#   .\Install-Wsa.ps1 [-CheckOnly] [-ArchivePath <file.7z>] [-ParentDir <cartella>] [-Repository <utente/repo>] [-ExtractOnly] [-Force]
#
# -CheckOnly       mostra quale build scaricherebbe, senza scaricare
# -ArchivePath     usa un archivio già scaricato (non si può verificare)
# -ParentDir       dove creare WSA_<versione>_x64, default C:\
# -Repository      un altro repository GitHub, default MustardChef/WSABuilds
# -ExtractOnly     scarica ed estrae ma non installa
# -Force           non chiede conferma
# -IgnoreExisting  solo per i test: continua anche se WSA è già installata
#
# Installs WSA if it is missing, taking the newest build from the community repository
# https://github.com/MustardChef/WSABuilds/releases: the newest Windows 11 x64 release that has the file
# WSA_<version>_x64_Release-Nightly-NoGApps-NoAmazon.7z. It checks the size and SHA-256 published by GitHub.
# If the repository or the file is missing, it stops with an error and does nothing else.
# Then it extracts the archive and runs its Install.ps1 as administrator (UAC). The WSA folder must stay where it is.
# -CheckOnly       shows which build would be downloaded, without downloading
# -ArchivePath     uses an archive already downloaded (it cannot be verified)
# -ParentDir       where to create WSA_<version>_x64, default C:\
# -Repository      another GitHub repository, default MustardChef/WSABuilds
# -ExtractOnly     downloads and extracts but does not install
# -Force           does not ask for confirmation
# -IgnoreExisting  for tests only: continues even if WSA is already installed
[CmdletBinding()]
param(
    [string]$ParentDir = ($env:SystemDrive + '\'),
    [string]$ArchivePath,
    [switch]$ExtractOnly,
    [switch]$Force,
    [switch]$IgnoreExisting,
    [switch]$CheckOnly,
    [string]$Repository = 'MustardChef/WSABuilds'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo    = $Repository
$Variant = '_x64_Release-Nightly-NoGApps-NoAmazon.7z'      # la build con cui è stato fatto e provato / the build the kit was made and tested with
$Package = 'MicrosoftCorporationII.WindowsSubsystemForAndroid'

function Say([string]$t)  { Write-Host "    $t" }
function Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Fail([string]$why) {
    throw "Windows Subsystem for Android is NOT installed and could not be installed automatically: $why`nInstall WSA yourself (see https://github.com/$Repo/releases), then run Setup.ps1 again."
}

# la release più recente per Windows 11 x64 che ha il file giusto
# the newest Windows 11 x64 release that has the right file
function Get-LatestWsaBuild {
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers @{ 'User-Agent' = 'wsa-apk-kit' } -TimeoutSec 60
    } catch { Fail "the repository https://github.com/$Repo is not reachable ($($_.Exception.Message))." }
    $ordered = @($releases) | Where-Object { -not $_.draft -and -not $_.prerelease } | Sort-Object { [datetime]$_.published_at } -Descending
    foreach ($rel in $ordered) {
        if ($rel.tag_name -notmatch '^Windows_11_\d+\.\d+\.\d+\.\d+(_[A-Za-z0-9]+)*$' -or $rel.tag_name -match '_arm64$') { continue }
        $asset = @($rel.assets) | Where-Object { $_.name -like "WSA_*$Variant" } | Select-Object -First 1
        if ($asset) { return [pscustomobject]@{ Release = $rel; Asset = $asset } }
    }
    Fail "no Windows 11 x64 release in $Repo has a file named WSA_*$Variant (the repository may have changed or been removed)."
}

Step 'Windows Subsystem for Android'
$installed = Get-AppxPackage -Name $Package -ErrorAction SilentlyContinue
if ($installed -and -not ($IgnoreExisting -and ($ExtractOnly -or $CheckOnly))) { Say "already installed: version $($installed.Version) ($($installed.InstallLocation))"; return }

if ([Environment]::OSVersion.Version.Build -lt 22000) { throw 'WSA needs Windows 11 (build 22000 or later).' }
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'This kit installs the x64 build of WSA: it needs a 64-bit Intel/AMD Windows.' }

# ---- cosa scaricare / what to download ----
$work = Join-Path ([IO.Path]::GetTempPath()) 'wsa-apk-kit-download'
New-Item -ItemType Directory -Force $work | Out-Null
$archive = $ArchivePath
$expectedSha = $null; $expectedSize = $null
if ($archive) {
    if (-not (Test-Path $archive)) { throw "Archive not found: $archive" }
    $fileName = Split-Path $archive -Leaf
    Say "Using $archive (not verified: no published checksum for a local file)"
} else {
    $build = Get-LatestWsaBuild
    $asset = $build.Asset
    $fileName = $asset.name
    $expectedSize = [int64]$asset.size
    if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $expectedSha = $Matches[1].ToUpper() }
    Say "Newest build in the repository: $($build.Release.name)"
    Say "Release: $($build.Release.html_url)"
    Say ("File:    {0} ({1:N0} MB)" -f $fileName, ($expectedSize / 1MB))
    if (-not $expectedSha) { Say 'Warning: GitHub publishes no checksum for this file; only its size can be checked.' }
    if ($CheckOnly) { Say 'CheckOnly: nothing downloaded.'; return }
}

$folder = $fileName -replace '_Release-.*$', ''            # cartella radice dell'archivio, es. WSA_2407.40000.4.0_x64 / root folder of the archive, e.g. WSA_2407.40000.4.0_x64
$target = Join-Path $ParentDir $folder
if (Test-Path $target) { throw "$target already exists but WSA is not registered. Run its Install.ps1 as administrator, or delete the folder and run this again." }
$drive = Get-PSDrive -Name ($ParentDir.Substring(0, 1)) -ErrorAction SilentlyContinue
if ($drive -and $drive.Free -lt 6GB) { throw "Not enough free space on $($drive.Name): (about 6 GB are needed for the download and the extracted files)." }

if (-not $Force) {
    if (-not [Environment]::UserInteractive) { throw 'Run again with -Force to download and install without asking.' }
    if ($Host.UI.PromptForChoice('Install WSA', "Download $fileName and install it to ${target}?", @('&Yes', '&No'), 1) -ne 0) { Say 'Cancelled.'; return }
}

# ---- download ----
if (-not $archive) {
    $archive = Join-Path $work $fileName
    Step 'Downloading (resumable)'
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (-not (Test-Path $curl)) { Fail 'curl.exe was not found (it ships with Windows 10 1803 and later).' }
    & $curl -L --fail --retry 5 -C - -o $archive $asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { Fail "the download did not complete (curl exit code $LASTEXITCODE). Running the script again resumes it." }

    Step 'Verifying'
    if ((Get-Item $archive).Length -ne $expectedSize) { Fail "unexpected file size ($((Get-Item $archive).Length) bytes, GitHub says $expectedSize)." }
    if ($expectedSha) {
        $hash = (Get-FileHash $archive -Algorithm SHA256).Hash
        if ($hash -ne $expectedSha) { Fail "SHA-256 mismatch (expected $expectedSha, got $hash): the downloaded file is not the one the repository published." }
        Say 'SHA-256 matches the one GitHub publishes for this file.'
    } else { Say 'Size matches.' }
}

# ---- estrazione / extraction ----
Step "Extracting to $ParentDir"
$sevenZip = @((Get-Command 7z -ErrorAction SilentlyContinue).Source, 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
New-Item -ItemType Directory -Force $ParentDir | Out-Null
if ($sevenZip) {
    & $sevenZip x $archive "-o$ParentDir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed (exit code $LASTEXITCODE)." }
} else {
    # Windows 11 ha bsdtar, che legge i .7z
    # Windows 11 includes bsdtar, which reads .7z files
    $tar = Join-Path $env:WINDIR 'System32\tar.exe'
    if (-not (Test-Path $tar)) { throw 'Cannot extract a .7z: install 7-Zip (https://www.7-zip.org) and run this again.' }
    & $tar -xf $archive -C $ParentDir
    if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE). Install 7-Zip and run this again." }
}
if (-not (Test-Path (Join-Path $target 'Install.ps1'))) { throw "Install.ps1 not found in ${target}: unexpected archive layout." }
Say "extracted: $target"

if ($ExtractOnly) { Say 'ExtractOnly: not running the installer.'; return }

# ---- installazione (amministratore) / installation (administrator) ----
Step 'Installing WSA (a UAC prompt will appear)'
Say 'The installer window may ask to restart Windows (Virtual Machine Platform). If so, restart and run Setup.ps1 again.'
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$p = Start-Process -FilePath $ps -Verb RunAs -WorkingDirectory $target -PassThru -Wait `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $target 'Install.ps1')
if (Get-AppxPackage -Name $Package -ErrorAction SilentlyContinue) {
    Say 'WSA is installed.'
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue      # l'archivio non serve più / the archive is no longer needed
} else {
    throw 'WSA does not show up as installed. If Windows asked for a restart, restart and run this again; otherwise run Install.ps1 in the extracted folder as administrator and read its messages.'
}
