# KitDroid

The APK double-click installer for Windows.

Double-click an `.apk`, confirm in a small dialog, and the app is installed in Windows Subsystem for Android (WSA). KitDroid sets everything up with one script, per user, and can be reproduced on any Windows 11 PC.

## Features

- **Confirmation dialog** showing the app's icon, name, version, size and minimum Android version.
- **One-click install** through ADB, with clear messages for the common failures (wrong architecture, signature mismatch, downgrade, no space).
- **Real app icons in File Explorer**, in every view: Details, List, small, medium and large icons. APKs without a readable icon get the Android robot.
- **Self-healing debug setup**: if ADB is unreachable or unauthorized, the dialog offers a button that turns on WSA's developer mode, restarts WSA if needed, and retries.
- **18 languages**, chosen from the Windows display language, with English as fallback.
- **WSA installer**: if WSA is missing, KitDroid downloads the newest build from the community repository, verifies it and installs it.
- **No admin rights** needed, except to install WSA itself. Everything else is written under the current user.

## Requirements

- Windows 11, 64-bit, Intel or AMD (WSA does not exist for Windows 10, and the x64 build is not supported on ARM64)
- Hardware virtualization enabled in BIOS/UEFI
- Windows PowerShell 5.1 and the .NET Framework 4.x that ship with Windows (only `csc.exe` is used)
- Internet access on first run (ADB and aapt2 come from Google; WSA, if missing, from GitHub)
- About 6 GB free on the system drive if WSA must be installed

No Android Studio, Java or Visual Studio is needed.

## Quick start

Double-click **`RUN.bat`**. It asks for administrator rights and shows a menu:

```
1) Install KitDroid
2) Uninstall KitDroid
3) Check WSA
Q) Quit
```

| Choice | Runs | What it does |
|---|---|---|
| 1 | `Setup.ps1` | Installs everything (see below). |
| 2 | `Uninstall.ps1` | Removes the file association and the install folder. |
| 3 | `scripts\Check-Wsa.ps1` | Read-only report: WSA installed/running, developer mode, ADB state, KitDroid install state, newest WSA build available. |

KitDroid works for the user that runs it. If your account is not an administrator and you enter another account's credentials at the UAC prompt, the installation goes to that account. `RUN.bat /noadmin` skips the prompt.

Without the menu:

```powershell
powershell -ExecutionPolicy Bypass -File .\Setup.ps1
```

After installing, double-click any `.apk`.

## What `Setup.ps1` does

1. **Checks** that Windows is 64-bit, that `csc.exe` exists and that the project files are complete. It then checks for WSA. If WSA is missing it offers to install it; if that is declined or fails, Setup stops and installs nothing else.
2. **Downloads ADB** (platform-tools) from Google, checks it against the SHA-1 in Google's repository manifest, and requires a valid digital signature from Google LLC on `adb.exe`.
3. **Downloads aapt2** (version 9.5.0-16666295) from Google Maven and checks the SHA-256 published next to it.
4. **Builds** the icons, the launcher (`ApkInstallerLauncher.exe`) and the Explorer extension (`ApkShell.dll`) with the `csc.exe` already in Windows. Builds are skipped when the sources have not changed.
5. **Copies** the dialog script, the translations and the helper scripts to `%LOCALAPPDATA%\WSA-ApkInstaller`.
6. **Registers** the `.apk` association for the current user, then test-loads the Explorer extension and keeps the small-icon handler only if it loads.
7. **Offers to turn on WSA developer mode**, which installing needs.
8. Optionally **restarts Explorer** so the new icons show immediately.

Setup is safe to run again: it skips what is already in place. Typical re-run time is about 20 seconds.

## WSA

Microsoft retired WSA, so KitDroid uses the community builds published at
<https://github.com/MustardChef/WSABuilds/releases>.

`Install-Wsa.ps1` picks the **newest** stable Windows 11 x64 release that contains a file named `WSA_<version>_x64_Release-Nightly-NoGApps-NoAmazon.7z` (WSA without Google apps, Amazon Appstore or Magisk). It then:

1. checks the Windows version, the architecture and the free disk space;
2. downloads the file with `curl.exe`, resumable;
3. verifies size and SHA-256 against what GitHub publishes for that file;
4. extracts it to `C:\WSA_<version>_x64` (7-Zip if present, otherwise the `tar.exe` in Windows 11);
5. runs the `Install.ps1` inside the archive as administrator (UAC prompt). Windows may ask to enable the Virtual Machine Platform feature and restart; after restarting, run Setup again.

Keep the extracted folder where it is: WSA is registered from it.

If the repository is gone, the network is down, no matching release exists or the checksum fails, the script stops with an error saying WSA is missing, and Setup does nothing more.

KitDroid was tested with `Windows_11_2407.40000.4.0_LTS_8` (WSA 2407.40000.4.0). Setup warns if the installed version is different.

```powershell
.\Install-Wsa.ps1 -CheckOnly                   # show which build would be downloaded
.\Install-Wsa.ps1 -ArchivePath D:\WSA.7z       # use an archive you already have (cannot be verified)
.\Install-Wsa.ps1 -Repository owner/repo       # use another repository
```

## Developer mode and ADB

Installing needs WSA's developer mode, which opens the ADB port `127.0.0.1:58526`.

`Enable-WsaDeveloperMode.ps1` turns it on through the WSA Settings window (UI Automation, using internal identifiers so it works in any Windows language). It starts WSA first if needed, then checks ADB.

After a fresh WSA install, ADB can answer `unauthorized` while WSA shows no prompt to accept. Restarting WSA fixed it every time in testing, and the script does that automatically, only in that state (it closes open Android apps).

The install dialog does all this by itself through its **Turn on and retry** button.

```powershell
.\Enable-WsaDeveloperMode.ps1               # turn on
.\Enable-WsaDeveloperMode.ps1 -Disable      # turn off (does not restart WSA)
```

### Security

While developer mode is on, WSA accepts ADB connections without asking, from the same machine and from other machines on networks with the **Private** profile (WSA's own firewall rule opens port 58526 there). Turn it off on networks you do not trust.

Windows may also create an inbound firewall rule for `adb.exe` the first time the ADB server runs. KitDroid neither creates nor removes it. To remove it, from an administrator PowerShell:

```powershell
Get-NetFirewallRule -DisplayName 'adb.exe' | Remove-NetFirewallRule
```

WSA itself comes from a third party. The SHA-256 check proves the file is the one the repository published, not that the build is safe, and the `Install.ps1` inside the archive runs as administrator. Use `-ArchivePath` or another source if you do not trust the repository. Likewise, the ADB SHA-1 comes from the same Google server as the file; the `adb.exe` signature check is the stronger one.

## File Explorer icons

`ApkShell.dll` contains two COM components, registered for the current user:

- **Thumbnail provider**: icons in medium, large and extra large views. Runs out of process in `dllhost.exe`.
- **Icon handler**: icons in Details, List and small views. Runs inside `explorer.exe`, so it is defensive: everything is in `try/catch`, it never opens files on network or removable drives, never opens files over 3 GB, and falls back to the default icon.

Both find the icon the way Android does: they read the binary `AndroidManifest.xml` to get the icon resource, then `resources.arsc` to map it to a file in the APK, picking the highest density. Adaptive icons (two layers) are composed from their bitmap or color layers. If that fails they try common names (`ic_launcher`, `icon`, `app_icon`). If nothing is found the Android robot is shown.

Not supported: adaptive icons whose layers are vector drawables, and WebP icons when the Windows WebP codec is missing.

If Explorer still shows old icons after setup, press F5, run `.\Setup.ps1 -RestartExplorer`, or sign out and in.

For diagnostics, create an empty file named `debug.flag` in the install folder; the extension then writes `shell.log` next to the DLL.

## Languages

English, Italian, Spanish, French, German, Portuguese, Russian, Chinese (Simplified and Traditional), Japanese, Korean, Arabic (right-to-left), Hindi, Turkish, Dutch, Polish, Indonesian, Vietnamese.

The dialog uses the Windows display language, tries the exact culture (`pt-BR`) and then the base language (`pt`), uses Traditional Chinese for `zh-TW`, `zh-HK`, `zh-MO` and `zh-Hant` and Simplified for other Chinese variants, and falls back to English.

The translations were not reviewed by native speakers. All texts are in `scripts\strings.json`; after editing run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-Translations.ps1
```

which checks that every language has the same keys and placeholders as English. To try a language without changing Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\WSA-ApkInstaller\ApkInstaller.ps1" 'C:\path\app.apk' -Lang de
```

## Command reference

**`Setup.ps1`**

| Parameter | Effect |
|---|---|
| `-InstallWsa` | Install WSA without asking if it is missing. |
| `-EnableDeveloperMode` | Turn on developer mode without asking. |
| `-RestartExplorer` | Restart Explorer at the end. |
| `-NoSmallIcons` | Do not register the small-icon handler. |
| `-Force` | Download and build everything again. |
| `-InstallDir <folder>` | Install location. Default `%LOCALAPPDATA%\WSA-ApkInstaller`. |

**`Install-Wsa.ps1`**: `-CheckOnly`, `-ArchivePath <file>`, `-ParentDir <folder>` (default `C:\`), `-Repository <owner/repo>`, `-ExtractOnly`, `-Force`.

**`Enable-WsaDeveloperMode.ps1`**: `-Disable`, `-Force` (restart WSA without asking), `-AdbPath <adb.exe>`.

**`Uninstall.ps1`**: `-InstallDir <folder>`.

**`scripts\ApkInstaller.ps1`** (the dialog): `<file.apk>`, `-Lang <code>`, `-ParseOnly` (print APK data as JSON), `-PreviewPng <file>` (render the dialog to an image), `-PreviewKey <key>` (with `-PreviewPng`, show a status message).

## Project layout

```
RUN.bat                         menu: install, uninstall, check WSA (asks for administrator)
Setup.ps1                       full per-user installation
Uninstall.ps1                   removal
Install-Wsa.ps1                 installs the newest WSA build if missing
Enable-WsaDeveloperMode.ps1     turns WSA developer mode on or off
scripts/
  ApkInstaller.ps1              the dialog: reads the APK, shows the window, installs with ADB
  strings.json                  dialog texts, one section per language
  Check-Wsa.ps1                 read-only status report
  Test-Translations.ps1         checks the translations
  Build-Assets.ps1              draws apk.ico and droid.png
  Register-Association.ps1      writes the per-user registry keys
  Remove-Association.ps1        removes them
src/
  Launcher.cs                   windowless launcher started by the double-click
  ApkShell.cs                   Explorer thumbnail provider and icon handler
```

## What it changes on the PC

**Registry (current user only)**, under `HKCU\Software\Classes`: `.apk` (default value `WSA.ApkInstaller`, content type, thumbnail handler key), `WSA.ApkInstaller` (default icon, open command `ApkInstallerLauncher.exe "%1"`, icon handler key) and the two COM classes `{7B3F2A6E-5C1D-4E8B-9A44-0D6C1F2E8A91}` (thumbnails) and `{2D9E6B14-8F3A-4C75-A1B0-5E7C93D4F206}` (icons).

**Files**: everything in `%LOCALAPPDATA%\WSA-ApkInstaller` (compiled files, copied scripts, `bin\adb`, `bin\aapt2`, build markers).

**Processes**: the ADB server stays running in the background on port 5037. WSA runs `WsaClient`, `WsaService`, `WsaSettings` and `vmmemWSA`.

KitDroid never writes to `HKLM`. WSA's own installer does (it sets `AllowDevelopmentWithoutDevLicense`).

## Uninstall

```powershell
.\Uninstall.ps1
```

It removes the registry keys, stops the ADB server and deletes the install folder. WSA, its folder and its developer mode are left alone. If Explorer still has `ApkShell.dll` loaded, some files remain until you restart Explorer or sign out; run the script again afterwards.

To remove WSA too:

```powershell
Get-AppxPackage -Name MicrosoftCorporationII.WindowsSubsystemForAndroid | Remove-AppxPackage
```

then delete its folder.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Setup stops saying WSA is not installed | WSA is missing and could not be downloaded or was declined | `.\Install-Wsa.ps1 -CheckOnly` to test the repository; install WSA by hand and run Setup again |
| "folder already exists but WSA is not registered" | WSA was extracted but not installed | Run `Install.ps1` in that folder as administrator, or delete the folder |
| Windows asks to restart during the WSA install | Virtual Machine Platform is being enabled | Restart, run Setup again |
| Dialog: developer mode is off | WSA's toggle is off | Press the retry-with-fix button |
| Dialog: WSA has not authorized this PC | `unauthorized` with no prompt | Same button; it restarts WSA once |
| `NO_MATCHING_ABIS` | The APK has no libraries WSA can run | Use another build of the app |
| `UPDATE_INCOMPATIBLE` | An app with the same name but another signature is installed | Uninstall it from WSA first (its data is lost) |
| `VERSION_DOWNGRADE` / `OLDER_SDK` | Newer version installed / app needs newer Android than WSA | Uninstall first / not possible with this WSA |
| Icons did not change | Explorer cache | F5, or `.\Setup.ps1 -RestartExplorer` |
| An APK with an icon shows the robot in Details | Vector-only or unusual icon | Enable `debug.flag` and read `shell.log` |
| "could not turn on Developer mode" in Setup | WSA Settings did not open | Start WSA, wait a few seconds, run `.\Enable-WsaDeveloperMode.ps1` |
| Scripts are blocked | PowerShell execution policy | Use `powershell -ExecutionPolicy Bypass -File ...` |
| Double-click does not open the dialog | Association changed by another program | Run Setup again, or pick `ApkInstallerLauncher` in "Open with" |

## Limitations

- Windows 11 x64 only.
- WSA is unofficial and third-party; the repository can change or disappear.
- ARM-only apps run through WSA's ARM translation and may be slower or less stable. The dialog warns about them.
- Vector-only icons are not read.
- One installation at a time: separate dialogs do not coordinate.
- The `.apk` association replaces the previous one for the current user; removing KitDroid does not restore it.
- Binaries are compiled locally and unsigned.
- Not yet tested: a full WSA install from scratch on a clean PC (download plus UAC), a second PC, and a Windows language other than Italian.

## Development

- Save every `.ps1` as **UTF-8 with BOM**; Windows PowerShell 5.1 needs it for accented characters.
- Keep machine-specific paths out of the sources: use `$env:LOCALAPPDATA`, `$env:WINDIR`, `$PSScriptRoot`.
- After changes: check syntax, run `Test-Translations.ps1`, then `Uninstall.ps1` and `Setup.ps1` from a clean state.
- If you touch the registry, update `Register-Association.ps1` and `Remove-Association.ps1` together.
- Changing a visible text means updating every language in `strings.json`.

## License

KitDroid is released under the MIT License. See [LICENSE](LICENSE).
