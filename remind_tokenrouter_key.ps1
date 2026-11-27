# TokenRouter key 到期提醒（由计划任务 ALEN-TokenRouter-Key-Expiry 在 2026-12-26 触发）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$msg = @"
TokenRouter 免费 key 明天到期（2026-12-27）

要换的三处：
1. opencode.json  → provider.tokenrouter.options.apiKey
2. hermes config.yaml → api.tokenrouter.com 那条 api_key
3. tokens/TOKENS.json → tokenrouter.expires_at（改成新 key 的 +30 天）

新 key 拿法：tokenrouter.com 登录 → 控制台 → API Keys → 新建
不换的话：额度条该行会转红，select_model.py 会自动把它踢出候选。
"@

$f = New-Object System.Windows.Forms.Form
$f.Text = "ALEN 额度条 · TokenRouter key 到期提醒"
$f.Size = New-Object System.Drawing.Size(520, 300)
$f.StartPosition = "CenterScreen"
$f.TopMost = $true

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = $msg
$lbl.Dock = "Fill"
$lbl.Padding = New-Object System.Windows.Forms.Padding(16)
$lbl.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
[void]$f.Controls.Add($lbl)

$btn = New-Object System.Windows.Forms.Button
$btn.Text = "知道了"
$btn.Dock = "Bottom"
$btn.Height = 40
$btn.Add_Click({ $f.Close() })
[void]$f.Controls.Add($btn)

[void]$f.ShowDialog()
