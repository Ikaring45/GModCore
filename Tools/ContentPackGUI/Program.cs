using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 1 && args[0] == "--self-test")
        {
            if (PackWindow.Quote("a b") != "\"a b\"" || PackWindow.Quote("C:\\a\\") != "\"C:\\a\\\\\"") return 1;
            using (var window = new PackWindow()) { if (window.Text.Length == 0) return 2; }
            return File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts", "New-GarrysPADContentPack.ps1")) ? 0 : 3;
        }
        Application.Run(new PackWindow());
        return 0;
    }
}

internal sealed class PackWindow : Form
{
    private readonly TextBox install = new TextBox();
    private readonly TextBox output = new TextBox();
    private readonly ComboBox profile = new ComboBox();
    private readonly TextBox log = new TextBox();
    private readonly Label status = new Label();
    private readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    private Process running;
    private readonly string scripts = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts");

    public PackWindow()
    {
        Text = "Garry's PAD ZIP Builder 1.0.0";
        Size = new Size(880, 650); MinimumSize = new Size(700, 520);
        Font = new Font("Yu Gothic UI", 10); StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), ColumnCount = 3, RowCount = 8 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
        Controls.Add(layout);
        var notice = new Label { Text = "正規所有のGarry's ModからiPad用ZIPを作成します。ゲーム素材は配布ツールに含まれません。", AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(notice, 0, 0); layout.SetColumnSpan(notice, 3);
        AddPath(layout, 1, "GarrysModフォルダー", install, delegate {
            using (var dialog = new FolderBrowserDialog { Description = "garrysmodフォルダーを含むGarrysModフォルダーを選択" })
                if (dialog.ShowDialog(this) == DialogResult.OK) install.Text = dialog.SelectedPath;
        });
        install.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam", "steamapps", "common", "GarrysMod");
        AddPath(layout, 2, "保存するZIP", output, delegate {
            using (var dialog = new SaveFileDialog { Filter = "ZIP archive|*.zip", FileName = "GarrysPAD_Content_Playable.zip", OverwritePrompt = true })
                if (dialog.ShowDialog(this) == DialogResult.OK) output.Text = dialog.FileName;
        });
        output.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "GarrysPAD_Content_Playable.zip");
        profile.DropDownStyle = ComboBoxStyle.DropDownList; profile.Dock = DockStyle.Fill;
        profile.Items.AddRange(new object[] { "Playable", "Playground", "CompleteBase" }); profile.SelectedIndex = 0;
        layout.Controls.Add(new Label { Text = "プロファイル", AutoSize = true }, 0, 3); layout.Controls.Add(profile, 1, 3);
        var hint = new Label { Text = "Playable: 通常用（数GB） / Playground: 転送試験用 / CompleteBase: 追加の標準素材\n物理マニフェストは生成しません。ZIP作成だけで未対応のprop物理が有効になるものではありません。", AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(hint, 0, 4); layout.SetColumnSpan(hint, 3);
        actions.AutoSize = true; actions.Dock = DockStyle.Fill;
        AddAction("事前確認", delegate { Run(false, true); });
        AddAction("ZIPを作成", delegate { Run(false, false); });
        AddAction("ZIPを検証", delegate { Run(true, false); });
        AddAction("ログを保存", SaveLog);
        layout.Controls.Add(actions, 0, 5); layout.SetColumnSpan(actions, 3);
        status.Text = "待機中 — 最初に事前確認を実行してください。"; status.AutoSize = true; status.Dock = DockStyle.Fill;
        layout.Controls.Add(status, 0, 6); layout.SetColumnSpan(status, 3);
        log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Both; log.WordWrap = false;
        log.Dock = DockStyle.Fill; log.Font = new Font("Consolas", 9);
        layout.Controls.Add(log, 0, 7); layout.SetColumnSpan(log, 3);
        for (int i = 0; i < 7; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (running != null) { e.Cancel = true; MessageBox.Show(this, "作成・検証の完了後に閉じてください。処理中のZIPを壊さないため終了を保留します。"); }
        };
    }

    private void AddPath(TableLayoutPanel layout, int row, string label, TextBox box, Action browse)
    {
        layout.Controls.Add(new Label { Text = label, AutoSize = true }, 0, row);
        box.Dock = DockStyle.Fill; layout.Controls.Add(box, 1, row);
        var button = new Button { Text = "参照…", Dock = DockStyle.Fill, AutoSize = true };
        button.Click += delegate { browse(); }; layout.Controls.Add(button, 2, row);
    }
    private void AddAction(string title, Action action)
    {
        var button = new Button { Text = title, AutoSize = true };
        button.Click += delegate { action(); }; actions.Controls.Add(button);
    }
    internal static string Quote(string value)
    {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            slashes = 0; result.Append(c);
        }
        result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
    }
    private void Append(string text)
    {
        if (IsDisposed || text == null) return;
        if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; }
        // Keep the UI bounded during multi-GB jobs. Save logs before clearing.
        if (log.TextLength > 1000000) log.Text = log.Text.Substring(log.TextLength - 500000);
        log.AppendText(text + Environment.NewLine);
    }
    private void Run(bool verify, bool plan)
    {
        if (running != null) return;
        try {
            string destination = Path.GetFullPath(output.Text.Trim());
            string script = Path.Combine(scripts, verify ? "Test-GarrysPADContentPack.ps1" : "New-GarrysPADContentPack.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("ScriptsフォルダーをEXEと一緒に展開してください。", script);
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script);
            if (verify) arguments += " -Path " + Quote(destination);
            else {
                string root = Path.GetFullPath(install.Text.Trim());
                if (!File.Exists(Path.Combine(root, "garrysmod", "garrysmod_dir.vpk"))) throw new IOException("garrysmod\\garrysmod_dir.vpkが見つかりません。インストール先を確認してください。");
                arguments += " -GModInstallRoot " + Quote(root) + " -OutputPath " + Quote(destination) + " -Profile " + Quote((string)profile.SelectedItem);
                if (plan) arguments += " -PlanOnly";
                else if (File.Exists(destination)) {
                    if (MessageBox.Show(this, "既存のZIPを置き換えますか？\n" + destination, "上書き確認", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                    arguments += " -Overwrite";
                }
            }
            var process = new Process { StartInfo = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = arguments, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            }, EnableRaisingEvents = true };
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Append(e.Data); };
            process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Append("[stderr] " + e.Data); };
            process.Exited += delegate { process.WaitForExit(); int code = process.ExitCode; BeginInvoke(new Action(delegate {
                running = null; actions.Enabled = true; install.Enabled = true; output.Enabled = true; profile.Enabled = true;
                status.Text = code == 0 ? "完了 — 作成後はZIPを検証してください。" : "失敗 — 下のログを確認してください。終了コード: " + code;
                Append(status.Text); process.Dispose();
            })); };
            Append("開始: " + (verify ? "ZIP検証" : plan ? "事前確認" : "ZIP作成") + " → " + destination);
            running = process; actions.Enabled = false; install.Enabled = false; output.Enabled = false; profile.Enabled = false;
            status.Text = "処理中（数GBの作成・ハッシュ検証には時間がかかります）";
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
        } catch (Exception error) {
            if (running != null) { running.Dispose(); running = null; }
            actions.Enabled = true; install.Enabled = true; output.Enabled = true; profile.Enabled = true;
            Append(error.Message); MessageBox.Show(this, error.Message, "エラー", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
    private void SaveLog()
    {
        using (var dialog = new SaveFileDialog { Filter = "Text log|*.txt", FileName = "GarrysPAD-ZIP-Builder.log.txt" })
            if (dialog.ShowDialog(this) == DialogResult.OK) {
                try { File.WriteAllText(dialog.FileName, log.Text, Encoding.UTF8); }
                catch (Exception error) { MessageBox.Show(this, error.Message); }
            }
    }
}
