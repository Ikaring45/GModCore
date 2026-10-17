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
        if (args.Length == 2 && args[0] == "--preview") {
            using (var window = new PackWindow()) {
                window.Show(); window.PerformLayout(); Application.DoEvents();
                using (var bitmap = new Bitmap(window.Width, window.Height)) {
                    window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size));
                    bitmap.Save(args[1], System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            return 0;
        }
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
    private readonly Button profile = new Button();
    private string selectedProfile = "Playable";
    private readonly TextBox log = new TextBox();
    private readonly Label status = new Label();
    private readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    private Process running;
    private static readonly Color Canvas = Color.FromArgb(25, 29, 34);
    private static readonly Color PanelColor = Color.FromArgb(37, 43, 50);
    private static readonly Color Muted = Color.FromArgb(161, 176, 191);
    private static readonly Color Blue = Color.FromArgb(0, 139, 218);
    private readonly string scripts = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts");

    public PackWindow()
    {
        Text = "Garry's PAD  /  Content Builder 1.1.1";
        Size = new Size(980, 760); MinimumSize = new Size(860, 680);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Canvas; ForeColor = Color.FromArgb(237, 242, 247);
        Font = new Font("Segoe UI", 10); StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(28), ColumnCount = 3, RowCount = 8 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
        Controls.Add(layout);
        var header = new Panel { Dock = DockStyle.Fill, Height = 126, Margin = new Padding(0, 0, 0, 22) };
        var badge = new Label { Text = "g", BackColor = Blue, ForeColor = Color.White, Font = new Font("Segoe UI", 42, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter, Location = new Point(0, 5), Size = new Size(78, 78) };
        header.Controls.Add(badge);
        header.Controls.Add(new Label { Text = "GARRY'S PAD", ForeColor = Muted, Font = new Font("Segoe UI", 9, FontStyle.Bold), AutoSize = true, Location = new Point(100, 4) });
        header.Controls.Add(new Label { Text = "Content Builder", Font = new Font("Segoe UI", 25, FontStyle.Bold), AutoSize = true, Location = new Point(96, 23) });
        header.Controls.Add(new Label { Text = "Your game. Ready for iPad.", ForeColor = Muted, AutoSize = true, Location = new Point(100, 76) });
        header.Controls.Add(new Label { Text = "01  SELECT     /     02  BUILD     /     03  VERIFY", ForeColor = Color.FromArgb(98, 180, 227), Font = new Font("Segoe UI", 9, FontStyle.Bold), AutoSize = true, Location = new Point(0, 108) });
        layout.Controls.Add(header, 0, 0); layout.SetColumnSpan(header, 3);
        AddPath(layout, 1, "Game installation", install, delegate {
            using (var dialog = new FolderBrowserDialog { Description = "Select the GarrysMod folder containing the garrysmod subfolder" })
                if (dialog.ShowDialog(this) == DialogResult.OK) install.Text = dialog.SelectedPath;
        });
        install.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam", "steamapps", "common", "GarrysMod");
        AddPath(layout, 2, "Output archive", output, delegate {
            using (var dialog = new SaveFileDialog { Filter = "ZIP archive|*.zip", FileName = "GarrysPAD_Content_Playable.zip", OverwritePrompt = true })
                if (dialog.ShowDialog(this) == DialogResult.OK) output.Text = dialog.FileName;
        });
        output.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "GarrysPAD_Content_Playable.zip");
        profile.Dock = DockStyle.Fill; profile.Height = 36; profile.TextAlign = ContentAlignment.MiddleLeft;
        profile.Padding = new Padding(10, 0, 0, 0); profile.Text = "Playable  /  Recommended     ▾";
        StyleButton(profile, false);
        var choices = new ContextMenuStrip { BackColor = PanelColor, ForeColor = Color.White, ShowImageMargin = false };
        foreach (string name in new[] { "Playable", "Playground", "CompleteBase" }) {
            string choice = name;
            var item = new ToolStripMenuItem(choice) { BackColor = PanelColor, ForeColor = Color.White };
            item.Click += delegate { selectedProfile = choice; profile.Text = choice + (choice == "Playable" ? "  /  Recommended" : "") + "     ▾"; };
            choices.Items.Add(item);
        }
        profile.Click += delegate { choices.Show(profile, new Point(0, profile.Height)); };
        Disposed += delegate { choices.Dispose(); };
        profile.Margin = new Padding(3, 6, 3, 14);
        layout.Controls.Add(new Label { Text = "Content profile", AutoSize = true, ForeColor = Muted, Margin = new Padding(0, 8, 0, 0) }, 0, 3); layout.Controls.Add(profile, 1, 3);
        var hint = new Label { Text = "PLAYABLE  Recommended · full textures, models and sounds (several GB)\nPLAYGROUND  Transfer testing only     /     COMPLETEBASE  Additional stock content\nOwned game files only. No game assets included. Physics attestation is not generated.", AutoSize = true, ForeColor = Muted, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 20) };
        layout.Controls.Add(hint, 0, 4); layout.SetColumnSpan(hint, 3);
        actions.AutoSize = true; actions.Dock = DockStyle.Fill;
        AddAction("Preview plan", delegate { Run(false, true); });
        AddAction("Build ZIP", delegate { Run(false, false); });
        AddAction("Verify ZIP", delegate { Run(true, false); });
        AddAction("Save log", SaveLog);
        layout.Controls.Add(actions, 0, 5); layout.SetColumnSpan(actions, 3);
        status.Text = "READY   /   Preview your plan before building."; status.AutoSize = true; status.Dock = DockStyle.Fill;
        status.ForeColor = Color.FromArgb(110, 204, 169); status.Margin = new Padding(0, 16, 0, 12);
        layout.Controls.Add(status, 0, 6); layout.SetColumnSpan(status, 3);
        log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Both; log.WordWrap = false;
        log.Dock = DockStyle.Fill; log.Font = new Font("Consolas", 9);
        log.BackColor = Color.FromArgb(17, 21, 25); log.ForeColor = Color.FromArgb(183, 201, 217); log.BorderStyle = BorderStyle.FixedSingle;
        log.Text = "> Content Builder 1.1.1\r\n> Select your installation and output archive to begin.\r\n";
        layout.Controls.Add(log, 0, 7); layout.SetColumnSpan(log, 3);
        for (int i = 0; i < 7; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (running != null) { e.Cancel = true; MessageBox.Show(this, "Wait for the current operation to finish before closing. This protects your archive.", "Operation in progress"); }
        };
    }

    private void AddPath(TableLayoutPanel layout, int row, string label, TextBox box, Action browse)
    {
        layout.Controls.Add(new Label { Text = label, AutoSize = true, ForeColor = Muted, Margin = new Padding(0, 10, 0, 0) }, 0, row);
        box.Dock = DockStyle.Fill; box.BackColor = PanelColor; box.ForeColor = ForeColor;
        box.BorderStyle = BorderStyle.FixedSingle; box.Margin = new Padding(3, 6, 10, 14); layout.Controls.Add(box, 1, row);
        var button = new Button { Text = "Browse...", Dock = DockStyle.Fill, AutoSize = true, Margin = new Padding(3, 4, 0, 12) };
        StyleButton(button, false);
        button.Click += delegate { browse(); }; layout.Controls.Add(button, 2, row);
    }
    private void AddAction(string title, Action action)
    {
        var button = new Button { Text = title, AutoSize = true, MinimumSize = new Size(128, 40), Margin = new Padding(0, 0, 10, 0), Padding = new Padding(12, 4, 12, 4) };
        StyleButton(button, title == "Build ZIP");
        button.Click += delegate { action(); }; actions.Controls.Add(button);
    }
    private void StyleButton(Button button, bool primary)
    {
        button.FlatStyle = FlatStyle.Flat; button.BackColor = primary ? Blue : PanelColor;
        button.ForeColor = Color.White; button.Cursor = Cursors.Hand;
        button.FlatAppearance.BorderColor = primary ? Blue : Color.FromArgb(65, 76, 88);
        button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(0, 160, 239) : Color.FromArgb(52, 62, 73);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(0, 105, 170);
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
            if (!File.Exists(script)) throw new FileNotFoundException("Extract the Scripts folder beside the executable.", script);
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script);
            if (verify) arguments += " -Path " + Quote(destination);
            else {
                string root = Path.GetFullPath(install.Text.Trim());
                if (!File.Exists(Path.Combine(root, "garrysmod", "garrysmod_dir.vpk"))) throw new IOException("Cannot find garrysmod\\garrysmod_dir.vpk. Check your game installation folder.");
                arguments += " -GModInstallRoot " + Quote(root) + " -OutputPath " + Quote(destination) + " -Profile " + Quote(selectedProfile);
                if (plan) arguments += " -PlanOnly";
                else if (File.Exists(destination)) {
                    if (MessageBox.Show(this, "Replace the existing archive?\n" + destination, "Confirm overwrite", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
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
                status.Text = code == 0 ? (verify ? "VERIFIED   /   Archive verification completed." : plan ? "PLAN READY   /   Review the log, then build your ZIP." : "BUILT   /   Verify the archive before transferring it to iPad.") : "FAILED   /   Review the log. Exit code: " + code;
                status.ForeColor = code == 0 ? Color.FromArgb(110, 204, 169) : Color.FromArgb(255, 145, 128);
                Append(status.Text); process.Dispose();
            })); };
            Append("Starting " + (verify ? "verification" : plan ? "plan preview" : "ZIP build") + " -> " + destination);
            running = process; actions.Enabled = false; install.Enabled = false; output.Enabled = false; profile.Enabled = false;
            status.Text = "WORKING   /   Large archives and SHA-256 verification can take a while.";
            status.ForeColor = Color.FromArgb(98, 180, 227);
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
        } catch (Exception error) {
            if (running != null) { running.Dispose(); running = null; }
            actions.Enabled = true; install.Enabled = true; output.Enabled = true; profile.Enabled = true;
            status.Text = "FAILED   /   " + error.Message; status.ForeColor = Color.FromArgb(255, 145, 128);
            Append(error.Message); MessageBox.Show(this, error.Message, "Content Builder", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
