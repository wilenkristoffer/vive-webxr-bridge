// VIVE WebXR Bridge.exe: starts the bridge window (src\gui.ps1) without a console window.
// Built by build.ps1 with the C# compiler that ships with the .NET Framework on Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "src", "gui.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Can't find " + script + ".\n\nKeep this program in the vive-webxr-bridge folder.",
                "VIVE WebXR Bridge", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        var start = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,  // no console; the script shows its own window
            WorkingDirectory = dir,
        };
        Process.Start(start);
    }
}
