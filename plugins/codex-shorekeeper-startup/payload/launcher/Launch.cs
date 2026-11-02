using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class ShorekeeperEntry {
    [STAThread]
    private static int Main(string[] args) {
        try {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            if (Array.IndexOf(args, "--preview") >= 0) {
                Process.Start(new ProcessStartInfo(Path.Combine(root, "preview.html")) { UseShellExecute = true });
                return 0;
            }
            bool restore = Array.IndexOf(args, "--restore-shortcuts") >= 0;
            string script = Path.Combine(root, "launcher", restore ? "restore-desktop.ps1" : "launch.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("请完整解压全部文件后再启动。", script);
            string flags = Array.IndexOf(args, "--original") >= 0 ? " -Original" : "";
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            Process.Start(new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"" + flags) {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = root
            });
            return 0;
        } catch (Exception error) {
            MessageBox.Show(error.Message, "守岸人 · Codex", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 1;
        }
    }
}
