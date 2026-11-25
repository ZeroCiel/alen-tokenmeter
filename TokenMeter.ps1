# ALEN TokenMeter 额度条 v1.0.1 —— 每条线路一根进度条: 剩余天数/额度 + 状态点
# 数据源: tokens\TOKENS.json (台账) + FREE-LINES-status.json (4.5h 线路巡检) + TOKEN-STATUS.json (09:00 钥匙巡检)
# v1.0.1 修复: 清场循环变量 $c 与颜色表 $C 大小写同名, foreach($c in $null) 首轮执行一次并创建局部 $c,
#              永久遮蔽 $C 导致 dot/fill 颜色全为环境色不可见 —— 改名 $dead 并防 $null。
# 必须保存为 UTF-8 BOM; 启动: powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File TokenMeter.ps1
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $base 'tokenmeter.log'
function Write-Log([string]$m){ try{ "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $m" | Out-File -FilePath $log -Append -Encoding UTF8 }catch{} }

$mutex = New-Object System.Threading.Mutex($false, 'ALENTokenMeterMutex')
if(-not $mutex.WaitOne(0, $false)){ Write-Log 'already running - exit'; exit }

Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wp, IntPtr lp);
'@

$TOKDIR  = if($env:TOKENS_DIR){ $env:TOKENS_DIR } else { 'D:\Backup\Documents\deepseek-harness\default-workspace\tokens' }
$TOKJSON = Join-Path $TOKDIR 'TOKENS.json'
$LINEJSON= Join-Path $TOKDIR 'FREE-LINES-status.json'
$KEYJSON = Join-Path $TOKDIR 'TOKEN-STATUS.json'

function Read-Utf8Json([string]$p){
  try{
    $sr = New-Object IO.StreamReader($p, [Text.Encoding]::UTF8)
    $s  = $sr.ReadToEnd(); $sr.Close()
    return ($s | ConvertFrom-Json)
  }catch{ return $null }
}

$shortNames = @{
  'gitcode-codingplan'='GitCode';
  'moma-deepseek'='MoMA 移动云'; 'qiniu-conatus'='七牛活动'; 'free-amd'='AMD 云'; 'modelscope'='魔搭'
  'zhipu'='智谱'; 'magpie-zen'='Magpie Zen'; 'opencode-zen-builtin'='Zen 内置'; 'deepseek-official'='DS 官方'
  'groq'='Groq'; 'openai-gemini'='OAI/Gem'; 'scnet-maas'='SCNet按量'; 'scnet-tokenplan'='SCNet套餐'
}
$winStart = @{
  'moma-deepseek'   = [DateTimeOffset]'2026-11-24T00:00:00+08:00'
  'qiniu-conatus'   = [DateTimeOffset]'2026-10-24T00:00:00+08:00'
  'scnet-tokenplan' = [DateTimeOffset]'2026-11-24T22:51:00+08:00'
}

$C = @{
  bg    = [Drawing.Color]::FromArgb(22,24,29)
  row   = [Drawing.Color]::FromArgb(30,33,39)
  track = [Drawing.Color]::FromArgb(45,49,58)
  txt   = [Drawing.Color]::FromArgb(232,232,232)
  dim   = [Drawing.Color]::FromArgb(154,160,168)
  green = [Drawing.Color]::FromArgb(61,220,132)
  orange= [Drawing.Color]::FromArgb(255,179,0)
  red   = [Drawing.Color]::FromArgb(255,82,82)
  gray  = [Drawing.Color]::FromArgb(107,112,120)
}

$W=368; $HDR=40; $ROWH=32; $GAP=3

$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.BackColor=$C.bg
$f.Size=New-Object Drawing.Size($W,200)
$f.TopMost=$true; $f.ShowInTaskbar=$false; $f.StartPosition='Manual'; $f.Text='ALEN额度条'
$f.Opacity=0.97

$title = New-Object System.Windows.Forms.Label
$title.Text='◆ ALEN 额度条'; $title.AutoSize=$false
$title.Size=New-Object Drawing.Size(150,24); $title.Location=New-Object Drawing.Point(12,9)
$title.ForeColor=$C.txt; $title.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.75,[Drawing.FontStyle]::Bold)
$title.BackColor=[Drawing.Color]::Transparent
$f.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text='…'; $sub.AutoSize=$false
$sub.Size=New-Object Drawing.Size(180,20); $sub.Location=New-Object Drawing.Point($W-192,11)
$sub.ForeColor=$C.dim; $sub.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25)
$sub.TextAlign='MiddleRight'; $sub.BackColor=[Drawing.Color]::Transparent
$f.Controls.Add($sub)

$drag = {
  param($s,$e)
  if($e.Button -eq [System.Windows.Forms.MouseButtons]::Left){
    [Native.Win]::ReleaseCapture()|Out-Null
    [Native.Win]::SendMessage($f.Handle,0xA1,[IntPtr]2,[IntPtr]::Zero)|Out-Null
  }
}
foreach($ctl in @($f,$title,$sub)){ $ctl.Add_MouseDown($drag) }

$tipTip = New-Object System.Windows.Forms.ToolTip
$tipTip.AutoPopDelay=20000; $tipTip.InitialDelay=300

$script:rowCtrls = @()

function New-Row([string]$name,[string]$right,[double]$frac,$dotC,$fillC,[string]$tip,[int]$y){
  $rp = New-Object System.Windows.Forms.Panel
  $rp.Size=New-Object Drawing.Size(($W-16),$ROWH); $rp.Location=New-Object Drawing.Point(8,$y)
  $rp.BackColor=$C.row

  $dotL = New-Object System.Windows.Forms.Label
  $dotL.Size=New-Object Drawing.Size(8,8); $dotL.Location=New-Object Drawing.Point(8,12)
  $dotL.BackColor=$dotC

  $nm = New-Object System.Windows.Forms.Label
  $nm.Text=$name; $nm.AutoSize=$false; $nm.Size=New-Object Drawing.Size(104,20)
  $nm.Location=New-Object Drawing.Point(21,6); $nm.ForeColor=$C.txt
  $nm.Font=New-Object Drawing.Font('Microsoft YaHei UI',9); $nm.BackColor=[Drawing.Color]::Transparent

  $track = New-Object System.Windows.Forms.Panel
  $track.Size=New-Object Drawing.Size(122,8); $track.Location=New-Object Drawing.Point(128,12)
  $track.BackColor=$C.track
  $fillP = New-Object System.Windows.Forms.Panel
  $fw = [int][Math]::Max(3, [Math]::Min(1.0,$frac)*122)
  $fillP.Size=New-Object Drawing.Size($fw,8); $fillP.Location=New-Object Drawing.Point(0,0)
  $fillP.BackColor=$fillC
  $track.Controls.Add($fillP)

  $rl = New-Object System.Windows.Forms.Label
  $rl.Text=$right; $rl.AutoSize=$false; $rl.Size=New-Object Drawing.Size(96,20)
  $rl.Location=New-Object Drawing.Point(250,6); $rl.ForeColor=$C.dim
  $rl.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $rl.TextAlign='MiddleRight'
  $rl.BackColor=[Drawing.Color]::Transparent

  foreach($ctl in @($dotL,$nm,$track,$rl)){ $rp.Controls.Add($ctl) }
  foreach($ctl in @($rp,$dotL,$nm,$track,$fillP,$rl)){ $ctl.Add_MouseDown($drag) }
  if($tip){ $tipTip.SetToolTip($rp,$tip); $tipTip.SetToolTip($nm,$tip) }
  $f.Controls.Add($rp)
  $script:rowCtrls += $rp
}

function Build-Rows{
  if($script:rowCtrls){
    foreach($dead in $script:rowCtrls){ try{ $dead.Dispose() }catch{} }
  }
  $script:rowCtrls = @()

  $tok   = Read-Utf8Json $TOKJSON
  $lines = Read-Utf8Json $LINEJSON
  $keys  = Read-Utf8Json $KEYJSON
  $keyMap=@{}
  if($keys -and $keys.keys){ foreach($k in $keys.keys){ $keyMap[$k.name]=$k } }
  $lineMap=@{}
  if($lines -and $lines.lines){ foreach($p in $lines.lines.PSObject.Properties){ $lineMap[$p.Name]=$p.Value } }

  $y = $HDR
  $now = [DateTimeOffset]::Now
  $n = 0
  if($tok -and $tok.tokens){
    foreach($t in $tok.tokens){
      if($t.id -eq 'scnet-token-plan'){ continue }
      $nm = $shortNames[$t.id]; if(-not $nm){ $nm = $t.id }
      $tip = [string]$t.provider
      if($t.expiry_rule){ $tip += "`n" + $t.expiry_rule }
      if($t.quota_official){ $tip += "`n" + $t.quota_official }
      if($t.verified_at){ $tip += "`n实测: " + $t.verified_at }

      $dot=$C.gray; $fill=$C.gray; $frac=1.0; $right=''

      $authOk = $true
      if($keyMap.ContainsKey($t.id) -and $keyMap[$t.id].auth -eq '401'){ $authOk=$false }

      if($t.id -eq 'deepseek-official'){
        $bal = $null
        if($keyMap.ContainsKey('deepseek-official') -and $keyMap['deepseek-official'].balance -match '(-?[\d.]+)'){ $bal=[double]$Matches[1] }
        if($bal -ne $null -and $bal -lt 0){
          $right = ('余额 ¥{0}' -f $bal); $dot=$C.red; $fill=$C.red; $frac=0.04
          $tip += "`n充值 >= ¥0.04 原 key 即恢复 (GET /user/balance 200)"
        }else{
          $right='可充值后用'; $dot=$C.green; $fill=$C.green
        }
      }
      elseif($t.id -eq 'groq' -or $t.id -eq 'openai-gemini'){
        $right='代理禁用中'; $dot=$C.gray; $fill=$C.gray; $frac=0.5
        $tip += "`nClash 127.0.0.1:7790 节点修复后从 disabled_providers 移除即恢复"
      }
      elseif($t.id -eq 'scnet-maas'){
        $right='待建通用key'; $dot=$C.orange; $fill=$C.orange; $frac=0.5
        $tip += "`n控制台-模型API-API Key管理 创建 sk- 通用 key (AK/SK 不是模型 key)"
      }
      elseif($t.id -eq 'free-amd'){
        $tomorrow = [DateTime]::Today.AddDays(1)
        $remH = ($tomorrow - [DateTime]::Now).TotalHours
        $frac = [Math]::Max(0.03, [Math]::Min(1.0, $remH/24))
        $right = ('{0}h 后重置' -f [int]$remH)
        $ok = $true; if($lineMap.ContainsKey('amd') -and -not $lineMap['amd'].ok){ $ok=$false }
        if($ok){ $dot=$C.green; $fill=$C.green } else { $dot=$C.orange; $fill=$C.orange; $right='探活失败·'+$right }
        $tip += "`n每日 1 积分仅够最小探测, 编码活优先其他免费线"
      }
      elseif($t.id -eq 'zhipu'){
        $right='免费档可用'; $dot=$C.green; $fill=$C.green
        $tip += "`n付费模型 4.5-air/4.6v 资源包已用完(429/1113); 按次包剩 18/99, 12-20 到期"
      }
      elseif($t.expires_at){
        $exp = [DateTimeOffset]::Parse($t.expires_at, [Globalization.CultureInfo]::InvariantCulture)
        $rem = $exp - $now
        if($rem.TotalSeconds -le 0){
          $right='已到期·待巡检清'; $dot=$C.red; $fill=$C.red; $frac=0.03
        }else{
          $st = $now
          if($winStart.ContainsKey($t.id)){ $st = $winStart[$t.id] }
          $tot = ($exp - $st).TotalSeconds
          if($tot -le 0){ $tot = 1 }
          $frac = [Math]::Max(0.03, [Math]::Min(1.0, $rem.TotalSeconds/$tot))
          $d = [int][Math]::Floor($rem.TotalDays); $h = $rem.Hours
          if($d -ge 1){ $right = ('剩{0}天{1}h' -f $d,$h) } else { $right = ('剩{0}h{1}m' -f $h,$rem.Minutes) }
          if($rem.TotalDays -lt 2 -or $frac -le 0.12){ $dot=$C.red; $fill=$C.red }
          elseif($frac -le 0.3){ $dot=$C.orange; $fill=$C.orange }
          else{ $dot=$C.green; $fill=$C.green }
        }
        $lk = $null
        if($t.id -eq 'qiniu-conatus' -and $lineMap.ContainsKey('qiniu')){ $lk=$lineMap['qiniu'] }
        if($t.id -eq 'moma-deepseek'  -and $lineMap.ContainsKey('moma')){ $lk=$lineMap['moma'] }
        if($lk -and -not $lk.ok){ $right='上游断·'+$right; if($dot -eq $C.green){ $dot=$C.orange; $fill=$C.orange } }
        if($t.id -eq 'scnet-tokenplan' -and $keyMap.ContainsKey('scnet-tokenplan') -and $keyMap['scnet-tokenplan'].auth -ne 'ok'){
          $right='key异常'; $dot=$C.red; $fill=$C.red
        }
      }
      else{
        $right='长期免费'; $dot=$C.green; $fill=$C.green
        $lkN = $t.id
        if($t.id -eq 'opencode-zen-builtin'){ $lkN='magpie' }
        if($lineMap.ContainsKey($lkN) -and -not $lineMap[$lkN].ok){
          $right='探活失败'; $dot=$C.orange; $fill=$C.orange
        }
      }
      if(-not $authOk){ $dot=$C.red; $fill=$C.red; $right='key 401' }

      New-Row $nm $right $frac $dot $fill $tip $y
      $y += $ROWH + $GAP
      $n++
    }
  }
  $f.Height = $y + 6
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Location = New-Object Drawing.Point(($wa.Right - $W - 8), ($wa.Bottom - $f.Height - 8))
  $sub.Text = ('{0} 条线 · {1}' -f $n, [DateTime]::Now.ToString('HH:mm'))
  return $n
}

$cm = New-Object System.Windows.Forms.ContextMenuStrip
$i1=$cm.Items.Add('立即刷新');        $i1.Add_Click({ [void](Build-Rows) })
$i2=$cm.Items.Add('置顶 开/关');      $i2.Add_Click({ $f.TopMost = -not $f.TopMost })
$i3=$cm.Items.Add('打开台账目录');    $i3.Add_Click({ Start-Process explorer.exe $TOKDIR })
$i4=$cm.Items.Add('退出');            $i4.Add_Click({ $f.Close() })
$f.ContextMenuStrip = $cm

$timer = New-Object System.Windows.Forms.Forms.Timer
$timer.Interval = 120000
$timer.Add_Tick({ [void](Build-Rows) })
$timer.Start()

$rows = Build-Rows
Write-Log ('shown rows=' + $rows)
[System.Windows.Forms.Application]::Run($f)
Write-Log 'closed'
