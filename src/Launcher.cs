using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

/// <summary>
/// CS2 Demo 分析器 启动器。
///
/// 编译为 /target:winexe —— 它自己不是控制台程序，不会创建控制台窗口。
/// 子进程 powershell 用 CreateNoWindow=true 启动，也不会创建控制台。
/// 结果：双击不会有任何终端闪现，只有分析器主界面。
/// </summary>
static class Launcher
{
    [STAThread]
    static void Main()
    {
        try
        {
            string here = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(here, "DemoAnalyzer.ps1");

            if (!File.Exists(script))
            {
                MessageBox.Show("找不到 DemoAnalyzer.ps1：\n" + script,
                    "启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string ps = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");

            if (!File.Exists(ps))
            {
                ps = "powershell.exe";
            }

            var psi = new ProcessStartInfo(
                ps,
                "-STA -NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;          // 关键：不给子进程创建控制台
            psi.WorkingDirectory = here;

            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "启动失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
