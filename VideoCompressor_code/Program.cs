using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace VideoCompressor
{
    public class MainForm : Form
    {
        private TextBox logBox;
        private Button startBtn;
        private Button stopBtn;
        private Button openIniBtn;
        private Label statusLabel;
        private Process monitorProc;
        private readonly string baseDir;     // exe 所在目录（setting.ini 在此，ffmpeg 通常也在此）
        private string scriptDir;            // 临时目录，存放从 exe 释放的 .ps1（用户文件夹不出现 .ps1）

        public MainForm()
        {
            baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            InitUI();
        }

        private void InitUI()
        {
            Text = "视频批量压缩监控";
            Width = 880;
            Height = 600;
            Font = new System.Drawing.Font("Consolas", 9.5f);

            statusLabel = new Label() { Left = 12, Top = 10, Width = 820, Height = 20, Text = "就绪" };
            logBox = new TextBox()
            {
                Left = 12,
                Top = 38,
                Width = 836,
                Height = 480,
                Multiline = true,
                ScrollBars = ScrollBars.Both,
                ReadOnly = true,
                Font = new System.Drawing.Font("Microsoft YaHei", 9.5f)
            };
            startBtn = new Button() { Left = 12, Top = 526, Width = 130, Height = 32, Text = "启动监控" };
            stopBtn = new Button() { Left = 152, Top = 526, Width = 130, Height = 32, Text = "停止", Enabled = false };
            openIniBtn = new Button() { Left = 292, Top = 526, Width = 160, Height = 32, Text = "打开 setting.ini" };

            startBtn.Click += (s, e) => StartMonitor();
            stopBtn.Click += (s, e) => StopMonitor();
            openIniBtn.Click += (s, e) => OpenSettingIni();

            Controls.AddRange(new Control[] { statusLabel, logBox, startBtn, stopBtn, openIniBtn });
            Load += (s, e) => StartMonitor();
            FormClosing += (s, e) => StopMonitor();
        }

        private void AppendLog(string text)
        {
            if (logBox.InvokeRequired)
            {
                logBox.Invoke(new Action<string>(AppendLog), text);
                return;
            }
            // 进度行用 \r 做控制台“原地覆盖”，在文本框里会变成乱码或单独成行，这里清掉。
            string cleaned = (text ?? "").Replace("\r", "");
            if (cleaned.Length == 0) return;
            logBox.AppendText(cleaned + Environment.NewLine);
            logBox.ScrollToCaret();
        }

        private void SetStatus(string s)
        {
            if (statusLabel.InvokeRequired)
            {
                statusLabel.Invoke(new Action<string>(SetStatus), s);
                return;
            }
            statusLabel.Text = s;
        }

        // ---- 释放内嵌资源 ----
        // 脚本 -> 临时目录（不在用户文件夹露面）；setting.ini -> exe 同目录（有则保留，无则创建）
        private void ExtractResources()
        {
            scriptDir = Path.Combine(Path.GetTempPath(), "VideoCompressor_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(scriptDir);

            var asm = Assembly.GetExecutingAssembly();
            string Find(string suffix)
            {
                foreach (var n in asm.GetManifestResourceNames())
                    if (n.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return n;
                return null;
            }

            ExtractIf(Find("encode-segments.ps1"), Path.Combine(scriptDir, "encode-segments.ps1"), overwrite: true);
            ExtractIf(Find("video_monitor.ps1"), Path.Combine(scriptDir, "video_monitor.ps1"), overwrite: true);
            ExtractIf(Find("setting.ini"), Path.Combine(baseDir, "setting.ini"), overwrite: false);
        }

        private void ExtractIf(string resName, string dest, bool overwrite)
        {
            if (resName == null) { AppendLog("WARN: 内嵌资源缺失 -> " + dest); return; }
            if (File.Exists(dest) && !overwrite) return;
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resName))
            using (var w = File.Create(dest))
                s.CopyTo(w);
        }

        private void StartMonitor()
        {
            if (monitorProc != null && !monitorProc.HasExited) return;
            ExtractResources();

            string psExe = Path.Combine(scriptDir, "video_monitor.ps1");
            string ini = Path.Combine(baseDir, "setting.ini");
            if (!File.Exists(psExe))
            {
                MessageBox.Show("找不到 video_monitor.ps1（资源释放失败）。", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // 显式把输出编码设为 UTF-8，避免中文文件名乱码
            string arg = string.Format(
                "-NoProfile -ExecutionPolicy Bypass -Command " +
                "$OutputEncoding=[System.Text.Encoding]::UTF8; " +
                "& '{0}' -Ini '{1}'",
                psExe, ini);

            var psi = new ProcessStartInfo("powershell.exe", arg)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
                CreateNoWindow = true,
                WorkingDirectory = baseDir
            };

            monitorProc = new Process() { StartInfo = psi, EnableRaisingEvents = true };
            monitorProc.OutputDataReceived += (s, e) => { if (e.Data != null) AppendLog(e.Data); };
            monitorProc.ErrorDataReceived += (s, e) => { if (e.Data != null) AppendLog("[ERR] " + e.Data); };
            monitorProc.Exited += (s, e) =>
            {
                var proc = (Process)s;
                int code = proc.ExitCode;
                AppendLog("=== 监控进程已退出 (code " + code + ") ===");
                SetStatus("已停止");
                CleanupTemp();
                Invoke(new Action(() => { startBtn.Enabled = true; stopBtn.Enabled = false; }));
            };

            try
            {
                monitorProc.Start();
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                monitorProc = null;
                return;
            }
            monitorProc.BeginOutputReadLine();
            monitorProc.BeginErrorReadLine();
            SetStatus("监控运行中…");
            startBtn.Enabled = false;
            stopBtn.Enabled = true;
            AppendLog("=== 监控已启动 ===");
            AppendLog("引擎: " + psExe);
            AppendLog("配置: " + ini);
        }

        private void StopMonitor()
        {
            if (monitorProc == null) { CleanupTemp(); return; }
            var proc = monitorProc;
            monitorProc = null;
            try
            {
                int pid = proc.Id;
                // 连子进程（encode-segments.ps1 起的 powershell / ffmpeg）一起结束
                var kill = new ProcessStartInfo("taskkill.exe", "/F /T /PID " + pid)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                Process.Start(kill)?.WaitForExit(3000);
            }
            catch { }
            try { if (!proc.HasExited) proc.Kill(); } catch { }
            CleanupTemp();
            SetStatus("已停止");
            startBtn.Enabled = true;
            stopBtn.Enabled = false;
        }

        // 清理释放到临时目录的 .ps1（用户文件夹始终不出现 .ps1）
        private void CleanupTemp()
        {
            if (string.IsNullOrEmpty(scriptDir)) return;
            try { if (Directory.Exists(scriptDir)) Directory.Delete(scriptDir, true); } catch { }
            scriptDir = null;
        }

        // 用系统默认程序打开 exe 同目录的 setting.ini
        private void OpenSettingIni()
        {
            string ini = Path.Combine(baseDir, "setting.ini");
            if (!File.Exists(ini))
            {
                MessageBox.Show("setting.ini 不存在，请先运行一次监控以生成默认配置。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo(ini) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show("无法打开 setting.ini: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
