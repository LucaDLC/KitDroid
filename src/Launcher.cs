using System;
using System.Diagnostics;
using System.IO;

// Launcher senza finestra: Windows lo lancia per i .apk e lui avvia ApkInstaller.ps1 nascosto.
// Windowless launcher: Windows runs it for .apk files, and it starts ApkInstaller.ps1 hidden.
static class Launcher
{
    [STAThread]
    static void Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "ApkInstaller.ps1");
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        string apk = args.Length > 0 ? args[0] : "";

        var psi = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" \"" + apk + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }
}
