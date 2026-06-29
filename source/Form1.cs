using System.Text.RegularExpressions;
using Renci.SshNet;

namespace XrayDeploy;

public partial class Form1 : Form
{
    private int _done, _total;

    public Form1() => InitializeComponent();

    static readonly Regex ReIp   = new(@"(?:\d{1,3}\.){3}\d{1,3}");
    static readonly Regex RePort = new(@"^(?:端口|port|PORT)[^\d]*(?<p>\d{2,5})$", RegexOptions.IgnoreCase);
    static readonly Regex ReUser = new(@"^(?:用户名?|username?|login|user)[^\w]*(?<u>[\w.\-@]+)$", RegexOptions.IgnoreCase);
    static readonly Regex RePwd  = new(@"^(?:密码|pass(?:word)?|pwd)[^\S]*[:：\s]+(?<pw>\S+)$", RegexOptions.IgnoreCase);
    // 带标签的 IP 行：  "IP：1.2.3.4"  "IP 1.2.3.4"  "host: 1.2.3.4"
    static readonly Regex ReIpLabel = new(@"^(?:IP|host|address|addr|服务器)[^\d]*(?<ip>(?:\d{1,3}\.){3}\d{1,3})\s*$", RegexOptions.IgnoreCase);
    // 单行 4 字段（分隔符任意）
    static readonly Regex ReInline  = new(
        @"(?<h>(?:\d{1,3}\.){3}\d{1,3})\s*[:\t ,|]+\s*(?<p>\d{2,5})\s*[:\t ,|]+\s*(?<u>[\w.\-@]+)\s*[:\t ,|]+\s*(?<pw>\S+)");

    static List<ServerInfo> Parse(string text)
    {
        var list   = new List<ServerInfo>();
        var lines  = text.Split('\n').Select(l => l.TrimEnd('\r').Trim()).ToArray();

        // ── 策略1：单行 4 字段内联（IP 端口 用户 密码） ──
        bool hasInline = false;
        foreach (var ln in lines)
        {
            var m = ReInline.Match(ln);
            if (!m.Success) continue;
            if (int.TryParse(m.Groups["p"].Value, out int p) && p is >= 1 and <= 65535)
            {
                list.Add(new(m.Groups["h"].Value, p, m.Groups["u"].Value, m.Groups["pw"].Value));
                hasInline = true;
            }
        }
        if (hasInline) return list;

        // ── 策略2：分块语义解析（连续非空行视为一个服务器块） ──
        var blocks = new List<List<string>>();
        var cur = new List<string>();
        foreach (var ln in lines)
        {
            if (string.IsNullOrEmpty(ln))
            { if (cur.Count > 0) { blocks.Add(cur); cur = new(); } }
            else cur.Add(ln);
        }
        if (cur.Count > 0) blocks.Add(cur);

        foreach (var block in blocks)
        {
            string? host = null, user = null, pwd = null;
            int port = 22;

            foreach (var ln in block)
            {
                // IP 带标签
                var mLabel = ReIpLabel.Match(ln);
                if (mLabel.Success) { host = mLabel.Groups["ip"].Value; continue; }

                // 裸 IP 行
                if (ReIp.IsMatch(ln) && ln.Split('.').Length == 4)
                {
                    var tok = ln.Split(new[]{' ','\t',':','：'}, StringSplitOptions.RemoveEmptyEntries);
                    host = tok[0];
                    // 同一行可能跟着端口
                    if (tok.Length >= 2 && int.TryParse(tok[1], out int pp) && pp is >= 1 and <= 65535)
                        port = pp;
                    continue;
                }

                var mPort = RePort.Match(ln);
                if (mPort.Success && int.TryParse(mPort.Groups["p"].Value, out int ep) && ep is >= 1 and <= 65535)
                { port = ep; continue; }

                var mUser = ReUser.Match(ln);
                if (mUser.Success) { user = mUser.Groups["u"].Value; continue; }

                var mPwd = RePwd.Match(ln);
                if (mPwd.Success) { pwd = mPwd.Groups["pw"].Value; continue; }

                // 无标签裸值推断：纯数字短串=端口，已有host且无user=user，已有user=pwd
                var toks = ln.Split(new[]{' ','\t',':','：'}, 2, StringSplitOptions.RemoveEmptyEntries);
                var val  = toks.Length == 2 ? toks[1].Trim() : ln;   // 支持 "root" 或 "user: root"

                if (int.TryParse(val, out int rp) && rp is >= 1 and <= 65535 && host != null)
                { port = rp; continue; }

                if (host != null && user == null && Regex.IsMatch(val, @"^[\w.\-@]{1,32}$"))
                { user = val; continue; }

                if (host != null && user != null && pwd == null && val.Length > 0)
                { pwd = val; }
            }

            if (host != null && user != null && pwd != null)
                list.Add(new(host, port, user, pwd));
        }

        return list;
    }

    async Task DeployOne(ServerInfo srv, string localScript)
    {
        var tag = $"{srv.Host}:{srv.Port}";
        Log($"\n{"=".PadRight(52, '=')}\n[{tag}] 连接中...");
        try
        {
            using var client = new SshClient(srv.Host, srv.Port, srv.User, srv.Password);
            client.ConnectionInfo.Timeout = TimeSpan.FromSeconds(30);
            await Task.Run(client.Connect);

            using (var sftp = new SftpClient(srv.Host, srv.Port, srv.User, srv.Password))
            {
                sftp.ConnectionInfo.Timeout = TimeSpan.FromSeconds(30);
                await Task.Run(sftp.Connect);
                using var fs = File.OpenRead(localScript);
                await Task.Run(() => sftp.UploadFile(fs, "/tmp/xray-reality.sh", true));
                sftp.Disconnect();
            }
            Log($"[{tag}] 脚本已上传，执行中...");

            using var cmd = client.CreateCommand("chmod +x /tmp/xray-reality.sh && bash /tmp/xray-reality.sh");
            cmd.CommandTimeout = TimeSpan.FromMinutes(10);
            var ar = cmd.BeginExecute();
            using var reader = new StreamReader(cmd.OutputStream);
            string? line;
            while ((line = await Task.Run(reader.ReadLine)) != null)
                Log($"[{tag}] {line}");
            cmd.EndExecute(ar);
            if (!string.IsNullOrWhiteSpace(cmd.Error))
                Log($"[{tag}][STDERR] {cmd.Error.Trim()}");
            Log($"[{tag}] 完成 ✓");
            client.Disconnect();
        }
        catch (Exception ex) { Log($"[{tag}][ERROR] {ex.Message}"); }
        finally { Interlocked.Increment(ref _done); UpdateProgress(); }
    }

    void Log(string msg) =>
        rtbLog.Invoke(() => { rtbLog.AppendText(msg + "\r\n"); rtbLog.ScrollToCaret(); });

    void UpdateProgress() =>
        lblProgress.Invoke(() => lblProgress.Text = $"{_done} / {_total}");

    private void btnPreview_Click(object sender, EventArgs e)
    {
        var servers = Parse(txtServers.Text);
        if (servers.Count == 0) { MessageBox.Show("未识别到任何服务器，请检查格式。"); return; }

        static string MaskPwd(string p) =>
            p.Length <= 2 ? new string('*', p.Length) : p[..2] + new string('*', Math.Min(p.Length - 2, 6));

        var frm = new Form
        {
            Text = $"识别预览 — 共 {servers.Count} 台",
            Size = new Size(680, 360),
            StartPosition = FormStartPosition.CenterParent,
            Font = new Font("Consolas", 9.5f)
        };
        var grid = new DataGridView
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            AllowUserToAddRows = false,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize,
            BackgroundColor = Color.FromArgb(30, 30, 30),
            ForeColor = Color.White,
            GridColor = Color.DimGray,
            DefaultCellStyle = { BackColor = Color.FromArgb(30, 30, 30), ForeColor = Color.White },
            ColumnHeadersDefaultCellStyle = { BackColor = Color.FromArgb(50, 50, 50), ForeColor = Color.LightGreen }
        };
        grid.Columns.AddRange(
            new DataGridViewTextBoxColumn { HeaderText = "#",    FillWeight = 5 },
            new DataGridViewTextBoxColumn { HeaderText = "Host" },
            new DataGridViewTextBoxColumn { HeaderText = "Port", FillWeight = 10 },
            new DataGridViewTextBoxColumn { HeaderText = "User" },
            new DataGridViewTextBoxColumn { HeaderText = "Password" });

        for (int i = 0; i < servers.Count; i++)
        {
            var s = servers[i];
            grid.Rows.Add(i + 1, s.Host, s.Port, s.User, MaskPwd(s.Password));
        }

        frm.Controls.Add(grid);
        frm.ShowDialog(this);
    }

    private void btnLoad_Click(object sender, EventArgs e)
    {
        using var dlg = new OpenFileDialog { Filter = "文本文件|*.txt|所有文件|*.*" };
        if (dlg.ShowDialog() == DialogResult.OK)
            txtServers.Text = File.ReadAllText(dlg.FileName);
    }

    private async void btnRun_Click(object sender, EventArgs e)
    {
        var servers = Parse(txtServers.Text);
        if (servers.Count == 0) { MessageBox.Show("未解析到任何服务器，请检查格式。"); return; }

        string scriptPath = Path.Combine(AppContext.BaseDirectory, "xray-reality.sh");
        if (!File.Exists(scriptPath))
        {
            using var dlg = new OpenFileDialog { Title = "选择 xray-reality.sh", Filter = "Shell 脚本|*.sh|所有文件|*.*" };
            if (dlg.ShowDialog() != DialogResult.OK) return;
            scriptPath = dlg.FileName;
        }

        btnRun.Enabled = false;
        rtbLog.Clear();
        _done = 0; _total = servers.Count;
        lblProgress.Text = $"0 / {_total}";

        foreach (var s in servers)
            Log($"[解析] {s.Host}:{s.Port}  用户:{s.User}");
        Log("");

        await Task.WhenAll(servers.Select(s => DeployOne(s, scriptPath)));
        Log("\n全部完成。");
        btnRun.Enabled = true;
    }
}

record ServerInfo(string Host, int Port, string User, string Password);
