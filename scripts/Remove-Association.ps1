# Toglie tutto ciò che ha creato Register-Association.ps1 per l'utente corrente (solo HKCU).
# Removes everything Register-Association.ps1 created for the current user (HKCU only).
$ErrorActionPreference = 'Continue'
$cls = 'HKCU:\Software\Classes'
foreach ($k in '.apk',
               'WSA.ApkInstaller',
               'CLSID\{7B3F2A6E-5C1D-4E8B-9A44-0D6C1F2E8A91}',
               'CLSID\{2D9E6B14-8F3A-4C75-A1B0-5E7C93D4F206}') {
    Remove-Item -Path "$cls\$k" -Recurse -Force -ErrorAction SilentlyContinue
}
Add-Type -Namespace Win32 -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
[Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
'Association removed.'
