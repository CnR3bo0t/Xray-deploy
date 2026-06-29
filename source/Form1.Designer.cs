namespace XrayDeploy;

partial class Form1
{
    /// <summary>
    ///  Required designer variable.
    /// </summary>
    private System.ComponentModel.IContainer components = null;

    /// <summary>
    ///  Clean up any resources being used.
    /// </summary>
    /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
    protected override void Dispose(bool disposing)
    {
        if (disposing && (components != null))
        {
            components.Dispose();
        }
        base.Dispose(disposing);
    }

    #region Windows Form Designer generated code

    /// <summary>
    ///  Required method for Designer support - do not modify
    ///  the contents of this method with the code editor.
    /// </summary>
    private TextBox txtServers = null!;
    private RichTextBox rtbLog = null!;
    private Button btnLoad = null!, btnRun = null!, btnPreview = null!;
    private Label lblProgress = null!;

    private void InitializeComponent()
    {
        Text = "Xray Reality 批量部署";
        ClientSize = new Size(900, 640);
        MinimumSize = new Size(700, 500);
        Font = new Font("Consolas", 9.5f);

        var lblHint = new Label { Text = "服务器列表（每行: IP  端口  用户名  密码，支持任意分隔符）：", Dock = DockStyle.Top, Height = 22 };
        txtServers = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Top, Height = 120, Font = new Font("Consolas", 9.5f) };

        btnLoad    = new Button { Text = "打开文件", Width = 90, Height = 28 };
        btnPreview = new Button { Text = "预览识别", Width = 90, Height = 28, Left = 100 };
        btnRun     = new Button { Text = "开始部署", Width = 90, Height = 28, Left = 200, BackColor = Color.SteelBlue, ForeColor = Color.White };
        lblProgress = new Label { Left = 300, Top = 4, Width = 200, Height = 22, Text = "" };

        var pnlCtrl = new Panel { Dock = DockStyle.Top, Height = 36 };
        pnlCtrl.Controls.AddRange(new Control[] { btnLoad, btnPreview, btnRun, lblProgress });

        rtbLog = new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, BackColor = Color.FromArgb(20, 20, 20), ForeColor = Color.LightGreen, Font = new Font("Consolas", 9f), ScrollBars = RichTextBoxScrollBars.Vertical };

        var split = new Panel { Dock = DockStyle.Fill };
        split.Controls.Add(rtbLog);

        Controls.Add(split);
        Controls.Add(pnlCtrl);
        Controls.Add(txtServers);
        Controls.Add(lblHint);

        btnLoad.Click    += btnLoad_Click;
        btnPreview.Click += btnPreview_Click;
        btnRun.Click     += btnRun_Click;
    }

    #endregion
}
