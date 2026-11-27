param([switch]$Query,[switch]$Settings)
# ALEN TokenMeter 额度条 v1.8.1 —— 异常提醒小窗: 探活失败 + opencode 真实回话失败(chat_errors.py) 同窗提醒
#                            提醒窗贴额度条上方(放不下就贴左侧), 不抢焦点; 确认即收起, 出现新异常再弹
#                            v1.7.4: 长条按「警戒值」归一化(剩余/警戒值 满格, 低于警戒值缩红条)
#                            v1.7.2: 百智领积分按钮入百智云行; DS 官方行加「充值」入口(platform.deepseek.com/usage)
# 数据源: tokens\TOKENS.json (台账, 含 model_details) + FREE-LINES-status.json (探活) + TOKEN-STATUS.json (钥匙巡检)
# 交互: 点线路行展开/收起模型; 按住拖动移动窗口; 右键菜单
# 必须保存为 UTF-8 BOM; 启动: powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File TokenMeter.ps1
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $base 'tokenmeter.log'
function Write-Log([string]$m){ try{ "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $m" | Out-File -FilePath $log -Append -Encoding UTF8 }catch{} }

$TOKDIR  = if($env:TOKENS_DIR){ $env:TOKENS_DIR } else { 'D:\Backup\Documents\deepseek-harness\default-workspace\tokens' }
$TOKJSON = Join-Path $TOKDIR 'TOKENS.json'
$LINEJSON= Join-Path $TOKDIR 'FREE-LINES-status.json'
$KEYJSON = Join-Path $TOKDIR 'TOKEN-STATUS.json'
$CREDITJSON = Join-Path $TOKDIR 'baizhi-credits.json'
$WARNJSON = Join-Path $TOKDIR 'warn.json'
# 警戒值表: 剩余低于该值即红条; 长条长度 = 剩余/警戒值 (>=1 满格)
$script:warnMap = @{}
try{
  if(Test-Path $WARNJSON){
    $wt = [IO.File]::ReadAllText($WARNJSON)
    if($wt){ foreach($pp in (ConvertFrom-Json $wt).PSObject.Properties){ if($pp.Name -notlike '_*'){ try{ $script:warnMap[[string]$pp.Name] = [double]$pp.Value }catch{} } } }
  }
}catch{}
$CUSTJSON= Join-Path $TOKDIR 'custom-providers.json'

function Read-Utf8Json([string]$p){
  try{
    $sr = New-Object IO.StreamReader($p, [Text.Encoding]::UTF8)
    $s  = $sr.ReadToEnd(); $sr.Close()
    return ($s | ConvertFrom-Json)
  }catch{ return $null }
}

# ===== 启动自动选线路（可用 + 高分档 + 低延迟，写 opencode/hermes/zcode）=====
function Invoke-AutoSelect {
  $py = Join-Path $base 'select_model.py'
  if(-not (Test-Path $py)){ return }
  $lk = Read-Utf8Json (Join-Path $TOKDIR 'model-lock.json')
  if($lk -and $lk.locked){ Write-Log 'auto-select skipped (locked)'; return }
  try{
    Start-Process -FilePath 'python' -ArgumentList @($py, '--apply', '--quiet') -WindowStyle Hidden | Out-Null
    Write-Log 'auto-select started (background)'
  }catch{
    Write-Log ('auto-select failed: ' + $_.Exception.Message)
  }
}

# ===== 百智云每日领积分（配合额度条的控件 + 每日自动）=====
function Start-BaizhiDailyBackground {
  $ps = Join-Path $base 'baizhi_daily.ps1'
  if(-not (Test-Path $ps)){ return }
  try{
    Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$ps) -WindowStyle Hidden | Out-Null
  }catch{}
}
function Invoke-BaizhiDaily([switch]$Force){
  $ps = Join-Path $base 'baizhi_daily.ps1'
  if(-not (Test-Path $ps)){ Write-Log 'baizhi_daily.ps1 missing'; return $false }
  try{
    $pargs = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$ps)
    if($Force){ $pargs += '-Force' }
    $out = & powershell @pargs 2>&1
    $line = (($out | Out-String).Trim())
    Write-Log ('baizhi daily -> ' + $line)
    if($line -match 'captcha'){
      try{ [Windows.Forms.MessageBox]::Show('百智云弹出验证码，已把浏览器切到前台，请手动完成。','ALEN 额度条') | Out-Null }catch{}
    }
    return ($line -match '^ok:')
  }catch{
    Write-Log ('baizhi daily failed: ' + $_.Exception.Message)
    return $false
  }
}
function Get-BaizhiDailyText {
  $p = Join-Path $TOKDIR 'baizhi-daily-claim.json'
  $st = Read-Utf8Json $p
  if($st -and $st.date -eq (Get-Date -Format 'yyyy-MM-dd') -and $st.ok){ return '✓积分' }
  if($st -and $st.date -eq (Get-Date -Format 'yyyy-MM-dd') -and $st.need_captcha){ return '待验证' }
  return '领积分'
}

# ===== 自定义服务商接入（手写）=====
function Read-CustomProviders {
  $o = Read-Utf8Json $CUSTJSON
  $arr = @()
  if($o -and $o.providers){ $arr = @($o.providers) }
  return ,$arr
}

function Write-CustomProviders($arr){
  $json = @{ providers = @($arr) } | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($CUSTJSON, $json, (New-Object Text.UTF8Encoding($true)))
}

function Show-SettingsForm {
  $script:cust = Read-CustomProviders
  $sf = New-Object System.Windows.Forms.Form
  $sf.Text='设置 · 自定义服务商接入'
  $sf.FormBorderStyle='FixedDialog'; $sf.StartPosition='CenterScreen'
  $sf.Size=New-Object Drawing.Size(570,470); $sf.TopMost=$true
  $sf.BackColor=[Drawing.Color]::FromArgb(24,26,31)
  $sf.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)

  $lb = New-Object System.Windows.Forms.ListBox
  $lb.Location=New-Object Drawing.Point(12,12); $lb.Size=New-Object Drawing.Size(200,364)
  $lb.BackColor=[Drawing.Color]::FromArgb(32,35,42); $lb.ForeColor=[Drawing.Color]::FromArgb(232,232,232)
  $sf.Controls.Add($lb); $script:setLb=$lb; $script:setSf=$sf

  $script:refreshList = {
    $script:setLb.Items.Clear()
    foreach($cp in @($script:cust)){ $script:setLb.Items.Add([string]$cp.name) }
  }
  & $script:refreshList

  $labels = @('名称*','ID*','Base URL*','Key 环境变量','模型(逗号分隔)','备注')
  $txts = @()
  $x0=228; $y0=14; $step=46
  for($i=0; $i -lt $labels.Count; $i++){
    $l = New-Object System.Windows.Forms.Label
    $l.Text=$labels[$i]; $l.Location=New-Object Drawing.Point($x0, ($y0 + $i*$step))
    $l.Size=New-Object Drawing.Size(160,16); $l.ForeColor=[Drawing.Color]::FromArgb(154,160,168)
    $sf.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location=New-Object Drawing.Point($x0, ($y0 + $i*$step + 18))
    $t.Size=New-Object Drawing.Size(310,24)
    $t.BackColor=[Drawing.Color]::FromArgb(32,35,42); $t.ForeColor=[Drawing.Color]::FromArgb(232,232,232)
    $sf.Controls.Add($t); $txts += $t
  }
  $script:setTxts=$txts

  $lb.Add_SelectedIndexChanged({
    param($s,$e)
    if($script:setLb.SelectedIndex -lt 0){ return }
    $cp = $script:cust[$script:setLb.SelectedIndex]
    if(-not $cp){ return }
    $t0=$script:setTxts
    $t0[0].Text=[string]$cp.name; $t0[1].Text=[string]$cp.id
    $t0[2].Text=[string]$cp.base_url; $t0[3].Text=[string]$cp.key_env
    $t0[4].Text=(@($cp.models) -join ','); $t0[5].Text=[string]$cp.note
  })

  $btnSave = New-Object System.Windows.Forms.Button
  $btnSave.Text='保存'; $btnSave.Location=New-Object Drawing.Point(228,388); $btnSave.Size=New-Object Drawing.Size(96,28)
  $btnSave.BackColor=[Drawing.Color]::FromArgb(61,220,132); $btnSave.ForeColor=[Drawing.Color]::FromArgb(12,20,16); $btnSave.FlatStyle='Flat'
  $btnSave.Add_Click({
    $t0=$script:setTxts
    $nm=$t0[0].Text.Trim(); $id=$t0[1].Text.Trim(); $bu=$t0[2].Text.Trim()
    if($nm -eq '' -or $bu -eq ''){ [Windows.Forms.MessageBox]::Show('名称和 Base URL 必填','提示') | Out-Null; return }
    if($id -eq ''){ $id='cust-' + (Get-Date -Format 'MMddHHmmss') }
    $ms=@(); foreach($m in ($t0[4].Text -split ',')){ $mm=$m.Trim(); if($mm -ne ''){ $ms += $mm } }
    $item=[pscustomobject]@{ name=$nm; id=$id; base_url=$bu; key_env=$t0[3].Text.Trim(); models=@($ms); note=$t0[5].Text.Trim(); added_at=[DateTimeOffset]::Now.ToString('o') }
    $arr=@($script:cust)
    $found=-1; for($j=0;$j -lt $arr.Count;$j++){ if([string]$arr[$j].id -eq $id){ $found=$j; break } }
    if($found -ge 0){ $arr[$found]=$item } else { $arr += $item }
    Write-CustomProviders $arr
    $script:cust = Read-CustomProviders
    & $script:refreshList
    if($rebuild){ $rebuild.Start() }
  })
  $sf.Controls.Add($btnSave)

  $btnDel = New-Object System.Windows.Forms.Button
  $btnDel.Text='删除选中'; $btnDel.Location=New-Object Drawing.Point(332,388); $btnDel.Size=New-Object Drawing.Size(96,28)
  $btnDel.BackColor=[Drawing.Color]::FromArgb(46,50,58); $btnDel.ForeColor=[Drawing.Color]::FromArgb(232,232,232); $btnDel.FlatStyle='Flat'
  $btnDel.Add_Click({
    if($script:setLb.SelectedIndex -lt 0){ return }
    $arr=@($script:cust); $new=@()
    for($j=0;$j -lt $arr.Count;$j++){ if($j -ne $script:setLb.SelectedIndex){ $new += $arr[$j] } }
    Write-CustomProviders $new
    $script:cust = Read-CustomProviders
    & $script:refreshList
    foreach($t in $script:setTxts){ $t.Text='' }
    if($rebuild){ $rebuild.Start() }
  })
  $sf.Controls.Add($btnDel)

  $btnClose = New-Object System.Windows.Forms.Button
  $btnClose.Text='关闭'; $btnClose.Location=New-Object Drawing.Point(444,388); $btnClose.Size=New-Object Drawing.Size(96,28)
  $btnClose.BackColor=[Drawing.Color]::FromArgb(46,50,58); $btnClose.ForeColor=[Drawing.Color]::FromArgb(232,232,232); $btnClose.FlatStyle='Flat'
  $btnClose.Add_Click({ $script:setSf.Close() })
  $sf.Controls.Add($btnClose)

  $sf.Add_Shown({ $script:setTxts[0].Focus() })
  $null = $sf.ShowDialog()
  $sf.Dispose()
}

function Get-Recommended {
  # 读三份数据, 返回当前可用且在推荐顺序中排第一的线路
  $tok   = Read-Utf8Json $TOKJSON
  $lines = Read-Utf8Json $LINEJSON
  $keys  = Read-Utf8Json $KEYJSON
  if(-not $lines){ return $null }
  $keyMap=@{}
  if($keys -and $keys.keys){ foreach($k in $keys.keys){ $keyMap[$k.name]=$k } }
  $lineMap=@{}
  if($lines.lines){ foreach($p in $lines.lines.PSObject.Properties){ $lineMap[$p.Name]=$p.Value } }
  $order=@($lines.recommended_order)
  if($order.Count -eq 0){ $order=@('zhipu','magpie','moma','qiniu','modelscope','amd') }
  $active=@{}
  if($tok -and $tok.tokens){
    foreach($t in @($tok.tokens)){
      if($t.status -like 'removed*'){ continue }
      if($t.status -ne 'active'){ continue }
      $active[[string]$t.id]=$true
    }
  }
  $ocProv=@{}
  try{
    $oc=Read-Utf8Json 'C:\Users\Administrator\.config\opencode\opencode.json'
    if($oc -and $oc.provider){
      foreach($p in $oc.provider.PSObject.Properties){
        $first=$null
        if($p.Value.models){ foreach($m in $p.Value.models.PSObject.Properties){ $first=$m.Name; break } }
        elseif($p.Value.whitelist){ $first=@($p.Value.whitelist)[0] }   # 内置 Zen 只有 whitelist, 没 models
        $ocProv[$p.Name]=$first
      }
    }
  }catch{}
  $provOf=@{ 'zhipu'='zhipu'; 'moma'='deepseek'; 'magpie'='opencode'; 'amd'='free-amd'; 'modelscope'='modelscope'; 'qiniu'=$null }
  $idsOf=@{ 'zhipu'=@('zhipu'); 'moma'=@('moma-deepseek'); 'magpie'=@('opencode-zen-builtin'); 'amd'=@('free-amd'); 'modelscope'=@('modelscope'); 'qiniu'=@('qiniu-conatus') }
  foreach($ln in $order){
    $ok=$true
    if($lineMap.ContainsKey($ln)){ $ok=[bool]$lineMap[$ln].ok }
    $ids=@($idsOf[$ln])
    if($ids.Count -gt 0){
      $anyActive=$false
      foreach($id in $ids){ if($active.ContainsKey($id)){ $anyActive=$true } }
      if(-not $anyActive){ $ok=$false }
      foreach($id in $ids){ if($keyMap.ContainsKey($id) -and ([string]$keyMap[$id].auth -eq '401' -or [string]$keyMap[$id].auth -eq '402' -or [string]$keyMap[$id].auth -eq '429' -or [string]$keyMap[$id].auth -eq 'removed')){ $ok=$false } }
    }
    if($ok){
      $ocPid=$provOf[$ln]
      $model=$null
      if($ocPid -and $ocProv.ContainsKey($ocPid)){ $model=$ocProv[$ocPid] }
      return [pscustomobject]@{ line=$ln; provider=$ocPid; models=@(if($model){$model}) }
    }
  }
  return $null
}

function Write-Recommendation {
  try{
    $r=Get-Recommended
    if($r){
      $obj=[ordered]@{
        at=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        line=$r.line; provider=$r.provider; models=@($r.models)
        note='当前可用推荐线路(FREE-LINES-status.recommended_order 首个 ok)'
      }
      ($obj | ConvertTo-Json -Compress) | Out-File (Join-Path $TOKDIR 'recommended-line.json') -Encoding UTF8
    }
  }catch{ Write-Log ('recommendation write failed: ' + $_.Exception.Message) }
}

$shortNames = @{
  'moma-deepseek'='MoMA 移动云'; 'qiniu-conatus'='七牛活动'; 'free-amd'='AMD 云'; 'modelscope'='魔搭'
  'zhipu'='智谱'; 'magpie-zen'='Magpie Zen'; 'opencode-zen-builtin'='Zen 内置'; 'deepseek-official'='DS 官方'
  'groq'='Groq'; 'openai-gemini'='OAI/Gem'; 'scnet-maas'='SCNet按量'; 'scnet-tokenplan'='SCNet套餐'
  'gitcode-codingplan'='GitCode Lite'; 'tokenrouter'='TokenRouter'; 'apinex'='APINEX'
  'zcode-context'='ZCode 上下文'
}

if($Query){
  $r=Get-Recommended
  if($r){ Write-Output ($r | ConvertTo-Json -Compress) } else { Write-Output '{"line":null,"provider":null,"models":[]}' }
  exit 0
}

if($Settings){
  Show-SettingsForm
  exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'ALENTokenMeterMutex')
if(-not $mutex.WaitOne(0, $false)){ Write-Log 'already running - exit'; exit }

$winStart = @{
  'moma-deepseek'   = [DateTimeOffset]'2026-11-24T00:00:00+08:00'
  'qiniu-conatus'   = [DateTimeOffset]'2026-10-24T00:00:00+08:00'
  'scnet-tokenplan' = [DateTimeOffset]'2026-11-24T22:51:00+08:00'
  'gitcode-codingplan' = [DateTimeOffset]'2026-11-25T18:38:00+08:00'
}

$C = @{
  bg    = [Drawing.Color]::FromArgb(22,24,29)
  row   = [Drawing.Color]::FromArgb(30,33,39)
  mrow  = [Drawing.Color]::FromArgb(26,28,33)
  track = [Drawing.Color]::FromArgb(45,49,58)
  txt   = [Drawing.Color]::FromArgb(232,232,232)
  dim   = [Drawing.Color]::FromArgb(154,160,168)
  green = [Drawing.Color]::FromArgb(61,220,132)
  orange= [Drawing.Color]::FromArgb(255,179,0)
  red   = [Drawing.Color]::FromArgb(255,82,82)
  gray  = [Drawing.Color]::FromArgb(107,112,120)
  rowBrd= [Drawing.Color]::FromArgb(61,220,132)
  mrowBrd=[Drawing.Color]::FromArgb(86,94,106)
}

$W=380; $HDR=40; $ROWH=32; $MODELH=24; $GAP=4
$ROWX=8; $ROWW=$W-20

Invoke-AutoSelect

$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.BackColor=$C.bg
$f.Size=New-Object Drawing.Size($W,240)
$f.TopMost=$true; $f.ShowInTaskbar=$false; $f.StartPosition='Manual'; $f.Text='ALEN额度条'
$f.Opacity=0.97
# 窗口外框: 1px 深灰边框 + 标题区下方分隔线
$f.Add_Paint({
  param($s,$e)
  $g = $e.Graphics
  $p = New-Object Drawing.Pen([Drawing.Color]::FromArgb(42,47,56))
  $g.DrawRectangle($p, 0, 0, ($s.Width-1), ($s.Height-1))
  [void]$g.DrawLine($p, 0, ($HDR-1), ($s.Width-1), ($HDR-1))
})

$title = New-Object System.Windows.Forms.Label
$title.Text='◆ ALEN 额度条'; $title.AutoSize=$false
$title.Size=New-Object Drawing.Size(112,24); $title.Location=New-Object Drawing.Point(12,9)
$title.ForeColor=$C.txt; $title.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.75,[Drawing.FontStyle]::Bold)
$title.BackColor=[Drawing.Color]::Transparent
$f.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text='…'; $sub.AutoSize=$false
$sub.Size=New-Object Drawing.Size(190,20)
$subX = $W - 202
$sub.Location=New-Object Drawing.Point($subX,11)
$sub.ForeColor=$C.dim; $sub.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25)
$sub.TextAlign='MiddleRight'; $sub.BackColor=[Drawing.Color]::Transparent
$f.Controls.Add($sub)

# 百智每日领积分小控件（v1.7.0: 从标题栏移到百智云行内, 仅当日未领时出现）
$script:bzRowY = -1
$script:bzDone = $false
$script:bzBtn = New-Object System.Windows.Forms.Button
$script:bzBtn.Text = Get-BaizhiDailyText
$script:bzBtn.Size = New-Object Drawing.Size(36,20)
$script:bzBtn.Visible = $false
$script:bzBtn.FlatStyle = 'Flat'
$script:bzBtn.BackColor = [Drawing.Color]::FromArgb(46,50,58)
$script:bzBtn.ForeColor = [Drawing.Color]::FromArgb(255,182,72)
$script:bzBtn.Font = New-Object Drawing.Font('Microsoft YaHei UI',8)
$script:bzBtn.Add_Click({
  [void](Invoke-BaizhiDaily -Force)
  [void](Build-Rows)
})

# DS 官方充值入口（固定挂在 DS 官方行右侧，点开 DeepSeek 用量/充值页）
$script:dsRowY = -1
$script:dsBtn = New-Object System.Windows.Forms.Button
$script:dsBtn.Text = '充值'
$script:dsBtn.Size = New-Object Drawing.Size(36,20)
$script:dsBtn.Visible = $false
$script:dsBtn.FlatStyle = 'Flat'
$script:dsBtn.BackColor = [Drawing.Color]::FromArgb(46,50,58)
$script:dsBtn.ForeColor = [Drawing.Color]::FromArgb(124,156,255)
$script:dsBtn.Font = New-Object Drawing.Font('Microsoft YaHei UI',8)
$script:dsBtn.Add_Click({ try{ Start-Process 'https://platform.deepseek.com/usage' }catch{} })

$list = New-Object System.Windows.Forms.Panel
$list.Location=New-Object Drawing.Point(0,$HDR)
$list.Size=New-Object Drawing.Size($W,160)
$list.AutoScroll=$true
$list.BackColor=$C.bg
$f.Controls.Add($list)

$script:expanded = @{}
$script:provIds  = @()
$script:rowCtl     = @()
$script:dragState = @{ on=$false; moved=$false; sx=0; sy=0; fx=0; fy=0 }

$tipTip = New-Object System.Windows.Forms.ToolTip
$tipTip.AutoPopDelay=20000; $tipTip.InitialDelay=300

$rebuild = New-Object System.Windows.Forms.Timer
$rebuild.Interval = 20
$rebuild.Add_Tick({ $rebuild.Stop(); [void](Build-Rows) })

$script:skinMeta = @{}

# ===== 线路异常提醒小窗（AlertPanel.ps1，贴额度条上方，不抢焦点）=====
. (Join-Path $base 'AlertPanel.ps1')
Init-AlertPanel $f

function Get-RoundRect([int]$x,[int]$y,[int]$w,[int]$h,[int]$rad){
  if($w -lt 2){ $w=2 }; if($h -lt 2){ $h=2 }
  if($rad -gt ([int]($w/2))){ $rad=[int]($w/2) }
  if($rad -gt ([int]($h/2))){ $rad=[int]($h/2) }
  if($rad -lt 1){ $rad=1 }
  $d = $rad*2
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  [void]$p.AddArc($x, $y, $d, $d, 180, 90)
  [void]$p.AddArc(($x+$w-$d), $y, $d, $d, 270, 90)
  [void]$p.AddArc(($x+$w-$d), ($y+$h-$d), $d, $d, 0, 90)
  [void]$p.AddArc($x, ($y+$h-$d), $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# 游戏风胶囊进度条: 深色凹槽 + 分段刻度 + 亮色填充(两端半圆) + 顶部内高光 + 细描边
function Draw-ProgressBar($g,[int]$x,[int]$y,[int]$w,[int]$h,[double]$frac,$fillC){
  $rad = [int]($h/2)
  $slot = Get-RoundRect $x $y $w $h $rad
  $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(16,18,22))),$slot)
  for($i=1; $i -lt 10; $i++){
    $tx = $x + [int]($w*$i/10)
    $g.DrawLine((New-Object Drawing.Pen([Drawing.Color]::FromArgb(58,64,74)),1), $tx, ($y+1), $tx, ($y+$h-1))
  }
  $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(70,76,86)),1),$slot)
  $fw = [int][Math]::Max($h, [Math]::Min(1.0,$frac)*$w)
  if($fw -ge $h){
    $fp = Get-RoundRect $x $y $fw $h $rad
    $g.FillPath((New-Object Drawing.SolidBrush($fillC)),$fp)
    $hh = [int]($h/2)-1; if($hh -lt 1){ $hh=1 }
    $hl = Get-RoundRect ($x+2) ($y+1) ($fw-4) $hh ([int]($hh/2))
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(90,255,255,255))),$hl)
    $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(30,0,0,0)),1),$fp)
  }
}

# 产品化条目皮肤: 小圆角卡片(暗底+弱边界) + 左侧状态竖条 + 胶囊进度条
function Set-RowSkin([System.Windows.Forms.Control]$ctl,[double]$frac,$fillC,[int]$bx,[int]$by,[int]$bw,[int]$bh,$stateC){
  $ctl.BackColor=[Drawing.Color]::Transparent
  if(-not $ctl.Name){ $ctl.Name = 'row' + [Guid]::NewGuid().ToString('N') }
  $script:skinMeta[$ctl.Name]=[pscustomobject]@{frac=[double]$frac;fill=$fillC;bx=$bx;by=$by;bw=$bw;bh=$bh;state=$stateC}
  $ctl.Add_Paint({
    param($s,$e)
    $m = $script:skinMeta[[string]$s.Name]
    if($null -eq $m){ return }
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $body = Get-RoundRect 1 1 ($s.Width-3) ($s.Height-3) 6
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(35,39,48))),$body)
    $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(44,49,59)),1),$body)
    $sbH = 12; $sbY = [int](($s.Height-$sbH)/2)
    $sb = Get-RoundRect 3 $sbY 3 $sbH 2
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.Color]$m.state)),$sb)
    Draw-ProgressBar $g ([int]$m.bx) ([int]$m.by) ([int]$m.bw) ([int]$m.bh) ([double]$m.frac) ([Drawing.Color]$m.fill)
  })
}

function Add-Mouse([System.Windows.Forms.Control]$ctl,[string]$providerId){
  $ctl.Tag = $providerId
  $ctl.Add_MouseDown({
    param($s,$e)
    if($e.Button -ne [System.Windows.Forms.MouseButtons]::Left){ return }
    $script:dragState.on = $true
    $script:dragState.moved = $false
    $script:dragState.sx = [System.Windows.Forms.Cursor]::Position.X
    $script:dragState.sy = [System.Windows.Forms.Cursor]::Position.Y
    $script:dragState.fx = $f.Location.X
    $script:dragState.fy = $f.Location.Y
  })
  $ctl.Add_MouseMove({
    param($s,$e)
    if(-not $script:dragState.on){ return }
    $dx = [System.Windows.Forms.Cursor]::Position.X - $script:dragState.sx
    $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:dragState.sy
    if(-not $script:dragState.moved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 4){ $script:dragState.moved = $true }
    if($script:dragState.moved){ $f.Location = New-Object Drawing.Point(($script:dragState.fx + $dx), ($script:dragState.fy + $dy)) }
  })
  $ctl.Add_MouseUp({
    param($s,$e)
    if(-not $script:dragState.on){ return }
    $script:dragState.on = $false
    if(-not $script:dragState.moved -and $s.Tag){
      $id = [string]$s.Tag
      $script:expanded[$id] = -not [bool]$script:expanded[$id]
      $rebuild.Start()
    }
  })
}

function Format-Num([double]$n){
  if($n -ge 1e8){ return ('{0:0.##}亿' -f ($n/1e8)) }
  if($n -ge 1e4){ return ('{0:0.#}万' -f ($n/1e4)) }
  return ([string][int]$n)
}

function New-ProviderRow([string]$id,[string]$name,[string]$right,[double]$frac,$dotC,$fillC,[string]$tip,[int]$y,[bool]$expandable,[bool]$expanded,[Drawing.Color]$borderC){
  $rp = New-Object System.Windows.Forms.Panel
  $rp.Size=New-Object Drawing.Size($ROWW,$ROWH); $rp.Location=New-Object Drawing.Point($ROWX,$y)
  $rp.Name = 'row-' + [string]$id
  Set-RowSkin $rp $frac $fillC 132 12 56 8 $dotC   # 进度条缩短到 132~188, 给右侧详情栏让位

  $ind = New-Object System.Windows.Forms.Label
  $ind.Text = if($expandable){ if($expanded){'▾'}else{'▸'} } else {''}
  $ind.AutoSize=$false; $ind.Size=New-Object Drawing.Size(14,20)
  $ind.Location=New-Object Drawing.Point(2,6)
  $ind.ForeColor=$C.dim; $ind.Font=New-Object Drawing.Font('Segoe UI Symbol',8)
  $ind.BackColor=[Drawing.Color]::Transparent

  $dotL = New-Object System.Windows.Forms.Label
  $dotL.Size=New-Object Drawing.Size(8,8); $dotL.Location=New-Object Drawing.Point(18,12)
  $dotL.BackColor=$dotC

  $nm = New-Object System.Windows.Forms.Label
  $nm.Text=$name; $nm.AutoSize=$false; $nm.Size=New-Object Drawing.Size(98,20)
  $nm.Location=New-Object Drawing.Point(30,6); $nm.ForeColor=$C.txt
  $nm.Font=New-Object Drawing.Font('Microsoft YaHei UI',9); $nm.BackColor=[Drawing.Color]::Transparent


  $rl = New-Object System.Windows.Forms.Label
  $rl.Text=$right; $rl.AutoSize=$false; $rl.Size=New-Object Drawing.Size(158,20)   # 加宽: 详情叠加后不截断
  $rl.Location=New-Object Drawing.Point(194,6); $rl.ForeColor=$C.dim               # 左移, 右缘仍 352
  $rl.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $rl.TextAlign='MiddleRight'
  $rl.BackColor=[Drawing.Color]::Transparent

  foreach($ctl in @($ind,$dotL,$nm,$rl)){ $rp.Controls.Add($ctl) }
  foreach($ctl in @($rp,$ind,$dotL,$nm,$rl)){ Add-Mouse $ctl $id }
  if($tip){ $tipTip.SetToolTip($rp,$tip); $tipTip.SetToolTip($nm,$tip) }
  $list.Controls.Add($rp)
  $script:rowCtl += $rp
}

function New-ModelRow([string]$name,[string]$right,[double]$frac,$fillC,[string]$tip,[int]$y,[bool]$usable,$rightColor,[Drawing.Color]$borderC){
  $rw = $ROWW - 24
  $rp = New-Object System.Windows.Forms.Panel
  $rp.Size=New-Object Drawing.Size($rw,$MODELH); $rp.Location=New-Object Drawing.Point(($ROWX+24),$y)
  $rp.Name = 'mdl-' + [Guid]::NewGuid().ToString('N')
  $rp.BackColor=$C.mrow

  $short = $name
  $slash = $short.LastIndexOf('/')
  if($slash -gt 0 -and $slash -le 26){ $short = $short.Substring($slash + 1) }
  if($short.Length -gt 34){ $short = $short.Substring(0,33) + '…' }

  $nm = New-Object System.Windows.Forms.Label
  $nm.Text=$short; $nm.AutoSize=$false; $nm.Size=New-Object Drawing.Size(176,18)
  $nm.Location=New-Object Drawing.Point(4,3)
  $nm.ForeColor = if($usable){ $C.txt } else { $C.gray }
  $nm.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $nm.BackColor=[Drawing.Color]::Transparent


  $rl = New-Object System.Windows.Forms.Label
  $rl.Text=$right; $rl.AutoSize=$false; $rl.Size=New-Object Drawing.Size(70,18)
  $rl.Location=New-Object Drawing.Point(266,3)
  $rl.ForeColor = $rightColor
  $rl.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $rl.TextAlign='MiddleRight'
  $rl.BackColor=[Drawing.Color]::Transparent

  foreach($ctl in @($nm,$rl)){ $rp.Controls.Add($ctl) }
  foreach($ctl in @($rp,$nm,$rl)){ Add-Mouse $ctl '' }
  if($tip){ $tipTip.SetToolTip($rp,$tip); $tipTip.SetToolTip($nm,$tip) }
  $list.Controls.Add($rp)
  $script:rowCtl += $rp
}

$script:sortMode = 'recommend'
$script:recLines = @()
$lineKey = @{
  'zhipu'='zhipu'; 'moma-deepseek'='moma'; 'magpie-zen'='magpie'
  'free-amd'='amd'; 'qiniu-conatus'='qiniu'; 'modelscope'='modelscope'
  'apinex'='apinex'; 'tokenrouter'='tokenrouter'; 'scnet-tokenplan'='scnet-tokenplan'
}

# ZCode 会话上下文容量（把 ZCode 界面的「上下文容量」合并进额度条）
# 数据源: ~/.zcode/cli/rollout/model-io-*.jsonl（每次模型调用一行, 取最近一次完整记录的 usage）
function Update-ZCodeContext {
  $out = Join-Path $TOKDIR 'zcode-context.json'
  try {
    $rc = Join-Path $env:USERPROFILE '.zcode\cli\rollout'
    if(-not (Test-Path $rc)){ return }
    $f = Get-ChildItem -Path $rc -Filter 'model-io-*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(-not $f){ return }
    # 源文件没更新就不重复解析（每次 Build-Rows 都会调用本函数）
    if((Test-Path $out) -and $f.LastWriteTime -le (Get-Item $out).LastWriteTime){ return }
    # 只读文件尾部 8MB（单行可达上百 KB，无需整读）
    $fs = [System.IO.File]::OpenRead($f.FullName)
    try {
      $fs.Seek([Math]::Max(0, $fs.Length - 8MB), 'Begin') | Out-Null
      $ms = New-Object System.IO.MemoryStream
      $buf = New-Object byte[] 65536
      while(($r = $fs.Read($buf,0,$buf.Length)) -gt 0){ $ms.Write($buf,0,$r) }
      $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally { $fs.Dispose() }
    $lines = $text -split "`n"
    $entry = $null
    $lo = [Math]::Max(0, $lines.Count - 8)
    for($i=$lines.Count-1; $i -ge $lo; $i--){
      $ln = ([string]$lines[$i]).Trim()
      if($ln.Length -lt 20){ continue }
      try{
        $j = $ln | ConvertFrom-Json
        if($j.response -and $j.response.usage){ $entry = $j; break }
      }catch{}
    }
    if(-not $entry){ return }
    $u = $entry.response.usage
    $win = 1000000   # 当前免费池/常用模型上下文容量均为 1M；如有不同容量的模型在此加映射
    $obj = [pscustomobject]@{
      used     = [int64]$u.inputTokens
      cache    = [int64]$u.cacheReadTokens
      output   = [int64]$u.outputTokens
      model    = "$($entry.model.providerId)/$($entry.model.modelId)"
      window   = [int64]$win
      msgCount = [int]$entry.request.messageCount
      at       = [string]$entry.completedAt
      file     = [string]$f.Name
    }
    [System.IO.File]::WriteAllText($out, ($obj | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
  } catch { Write-Log ("zcode-context 刷新失败: " + $_.Exception.Message) }
}

function Line-Ok([string]$id,$map){
  if($id -eq 'zcode-context'){ return $true }   # 监控行置顶, 不参与探活排序
  $k=$lineKey[$id]; if(-not $k){ return $true }
  if($map.ContainsKey($k)){ return [bool]$map[$k].ok }
  return $true
}

function Line-Lat([string]$id,$map){
  if($id -eq 'zcode-context'){ return 0 }
  $k=$lineKey[$id]; if(-not $k){ return 999999 }
  if($map.ContainsKey($k) -and $null -ne $map[$k].latency_ms){ return [double]$map[$k].latency_ms }
  return 999999
}

function Line-Rank([string]$id,$rankMap){
  if($id -eq 'zcode-context'){ return -1 }   # 推荐序模式下也置顶
  $k=$lineKey[$id]; if(-not $k){ return 900 }
  if($rankMap.ContainsKey($k)){ return [int]$rankMap[$k] }
  return 900
}

# 线路行右侧追加「探活延迟 + 模型数」详情（各分支都在天数/额度之后调用）
function Add-LineDetail([string]$id,[string]$right,[int]$modelCount,$map){
  if($id -eq 'zcode-context'){ return $right }
  $seg = @()
  $k=$lineKey[$id]
  if($k -and $map -and $map.ContainsKey($k)){
    $ln=$map[$k]
    if([bool]$ln.ok){
      if($null -ne $ln.latency_ms){ $seg += ('{0}ms' -f [int]$ln.latency_ms) } else { $seg += '通' }
    } else {
      $seg += '断'
    }
  }
  if($modelCount -gt 0 -and $id -ne 'opencode-zen-builtin'){ $seg += ('{0}型' -f $modelCount) }
  if($seg.Count -gt 0){ return ($right + '·' + ($seg -join '/')) }
  return $right
}

function Build-Rows{
  [void](Update-ZCodeContext)   # 每次重建前刷新 ZCode 上下文数据（源文件未变则秒过）
  foreach($r in $script:rowCtl){ try{ $r.Dispose() }catch{} }
  $script:rowCtl = @()
  $script:provIds = @()
  $script:bzRowY = -1
  $script:bzDone = $false
  $script:dsRowY = -1

  $script:selLine = ''
  try{ $sl0 = Read-Utf8Json (Join-Path $TOKDIR 'selected-line.json'); if($sl0 -and $sl0.line){ $script:selLine = [string]$sl0.line } }catch{}
  $tok   = Read-Utf8Json $TOKJSON
  $lines = Read-Utf8Json $LINEJSON
  $keys  = Read-Utf8Json $KEYJSON
  $keyMap=@{}
  if($keys -and $keys.keys){ foreach($k in $keys.keys){ $keyMap[$k.name]=$k } }
  $lineMap=@{}
  if($lines -and $lines.lines){ foreach($p in $lines.lines.PSObject.Properties){ $lineMap[$p.Name]=$p.Value } }

  $y = 0
  $now = [DateTimeOffset]::Now
  $n = 0
  if($tok -and $tok.tokens){
    $items = @()
    foreach($t in $tok.tokens){
      if($t.id -eq 'scnet-token-plan'){ continue }
      if($t.status -like 'removed*'){ continue }
      $items += $t
    }
    $rankMap = @{}
    $ri = 0
    if($lines.recommended_order){ foreach($ro in @($lines.recommended_order)){ if(-not $rankMap.ContainsKey([string]$ro)){ $rankMap[[string]$ro] = $ri; $ri++ } } }
    if($script:sortMode -eq 'auto'){
      $items = @($items | Sort-Object -Property @{Expression={ -(Line-Ok $_.id $lineMap) }} , @{Expression={ Line-Lat $_.id $lineMap }})
    }else{
      $items = @($items | Sort-Object -Property @{Expression={ Line-Rank $_.id $rankMap }})
    }
    $script:recLines = @()
    foreach($t in $items){
      $nm = $shortNames[$t.id]; if(-not $nm){ $nm = $t.id }
      $tip = [string]$t.provider
      if($t.expiry_rule){ $tip += "`n" + $t.expiry_rule }
      if($t.quota_official){ $tip += "`n" + $t.quota_official }
      if($t.verified_at){ $tip += "`n实测: " + $t.verified_at }

      $dot=$C.gray; $fill=$C.gray; $frac=1.0; $right=''
      # 本行用于「警戒值归一化」的指标值(天/元/积分)与默认警戒值
      $metric=$null; $warnDef=$null; $warnLock=$false
      # 模型明细 + 探活汇总(提前算): 全部探活失败时不再冒充「长期免费」
      $mdl = @()
      if($t.model_details){ $mdl = @($t.model_details) }
      elseif($t.models){ foreach($m in @($t.models)){ $mdl += [pscustomobject]@{ name=[string]$m; tier='?'; usable=$true; quota=$null; note='' } } }
      $probeAll = @($mdl | Where-Object { $_.probe -and $_.probe.at })
      $probeOkCnt = @($probeAll | Where-Object { $_.probe.ok }).Count
      $allProbeRed = ($probeAll.Count -gt 0 -and $probeOkCnt -eq 0)

      $authCode = ''
      if($keyMap.ContainsKey($t.id) -and $keyMap[$t.id].auth){ $authCode = [string]$keyMap[$t.id].auth }
      $authOk = -not ($authCode -eq '401' -or $authCode -eq '402' -or $authCode -eq '403')

      if($t.id -eq 'deepseek-official'){
        $bal = $null
        if($keyMap.ContainsKey('deepseek-official') -and $keyMap['deepseek-official'].balance -match '(-?[\d.]+)'){ $bal=[double]$Matches[1] }
        $metric=$bal; $warnDef=5
        if($bal -ne $null -and $bal -lt 0){
          $right = ('余额 ¥{0}' -f $bal); $dot=$C.red; $fill=$C.red; $frac=0.04
          $tip += "`n充值 >= ¥0.04 原 key 即恢复 (GET /user/balance 200)"
        }else{
          if($bal -ne $null -and $bal -gt 0){ $right = ('余额 ¥{0}' -f $bal) } else { $right='可充值后用' }
          $dot=$C.green; $fill=$C.green
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
      elseif($t.id -eq 'apinex'){
        $right='需充值解锁'; $dot=$C.gray; $fill=$C.gray; $frac=0.3
        $tip += "`n402: 单次充值 >= $5 解锁每日2500万 free tokens(永久); 未充值前不可用"
      }
      elseif($t.id -eq 'free-amd'){
        $tomorrow = [DateTime]::Today.AddDays(1)
        $remH = ($tomorrow - [DateTime]::Now).TotalHours
        $frac = [Math]::Max(0.03, [Math]::Min(1.0, $remH/24))
        $metric = $remH/24.0; $warnDef = 0.25
        $right = ('{0}h 后重置' -f [int]$remH)
        $ok = $true; if($lineMap.ContainsKey('amd') -and -not $lineMap['amd'].ok){ $ok=$false }
        if($ok){ $dot=$C.green; $fill=$C.green } else { $dot=$C.orange; $fill=$C.orange; $right='探活失败·'+$right }
        $tip += "`n每日 1 积分仅够最小探测, 编码活优先其他免费线"
      }
      elseif($t.id -eq 'baizhi'){
        $cr = $null
        $co = Read-Utf8Json $CREDITJSON
        if($co -and $null -ne $co.remaining){ $cr = [double]$co.remaining }
        elseif($t.credits -and $null -ne $t.credits.remaining){ $cr = [double]$t.credits.remaining }
        $metric=$cr; $warnDef=50
        $dot=$C.green; $fill=$C.green
        if($cr -ne $null){ $right = [string]([decimal]$cr) } else { $right = '积分计费' }
        $bs = Read-Utf8Json (Join-Path $TOKDIR 'baizhi-daily-claim.json')
        if($bs -and $bs.date -eq (Get-Date -Format 'yyyy-MM-dd') -and $bs.ok){ $right = '✓ ' + [string]([decimal]$cr); $script:bzDone=$true }
        else{ $dot=$C.orange; $fill=$C.orange; $warnLock=$true }   # 未领积分保持橙色, 不被警戒值改绿
        $tip += "`n积分余额只在控制台 baizhi.cloud/console/apps 可见（API key 查不到，需登录态）"
        $tip += "`n行右侧橙色按钮可领100积分（可能弹验证码）; 右键菜单亦有入口"
      }
      elseif($t.id -eq 'zhipu'){
        $right='免费档可用'; $dot=$C.green; $fill=$C.green
        $tip += "`n付费模型 4.5-air/4.6v 资源包已用完(429/1113); 按次包剩 18/99, 12-20 到期"
      }
      elseif($t.id -eq 'zcode-context'){
        # ZCode 会话上下文容量（数据由 Update-ZCodeContext 从 rollout 解析）
        $zc = Read-Utf8Json (Join-Path $TOKDIR 'zcode-context.json')
        if($zc -and $zc.used){
          $used=[double]$zc.used; $win=[double]$zc.window
          if($win -le 0){ $win=1 }
          $frac=[Math]::Max(0.02,[Math]::Min(1.0,$used/$win))
          $cacheRate=0
          if($used -gt 0 -and $zc.cache){ $cacheRate=[int][Math]::Round(100.0*([double]$zc.cache)/$used) }
          $fk = { param($n) if($n -ge 1000000){ '{0:N1}M' -f ($n/1000000.0) } elseif($n -ge 1000){ '{0:N0}K' -f ($n/1000.0) } else { [string][int64]$n } }
          $right = ('{0}/{1} · 缓存 {2}%' -f (& $fk $used), (& $fk $win), $cacheRate)
          if($frac -lt 0.5){ $dot=$C.green; $fill=$C.green }
          elseif($frac -lt 0.8){ $dot=$C.orange; $fill=$C.orange }
          else{ $dot=$C.red; $fill=$C.red }
          $tip += "`n模型 $($zc.model) · 消息 $($zc.msgCount) 条"
          $tip += "`n输入 $($zc.used) · 缓存读 $($zc.cache) · 输出 $($zc.output)（最近一次调用）"
          $tip += "`n来源 ~/.zcode/cli/rollout/$($zc.file) · 随额度条自动刷新"
        } else {
          $right='等待模型调用'; $dot=$C.gray; $fill=$C.gray; $frac=0.05
          $tip += "`nZCode 产生模型调用后自动显示（rollout/model-io-*.jsonl）"
        }
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
          $metric = $rem.TotalDays; $warnDef = 3
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
        if($allProbeRed){
          # 检查全红: 台账/网页写着长期免费, 但所有模型实测均失败 -> 不冒充可用, 灰显「不可用」
          $right='不可用'; $dot=$C.gray; $fill=$C.gray; $frac=0.04
          $tip += ("`n网页/台账标注「长期免费」, 但 {0} 个模型实测全部失败(全红) -> 按「不可用」显示" -f $probeAll.Count)
        }
        elseif($t.id -eq 'opencode-zen-builtin'){
          # 官方入口通道: 只能用 `opencode run` 探活(HTTP 带 key 必 429), 结果写在台账 probe 里
          # 不再借用 magpie 网关的状态——那是另一条结构性走不通的转发线
          $zd  = @($t.model_details)
          $zpr = @($zd | ForEach-Object { $_.probe } | Where-Object { $_ })
          if($zpr.Count -gt 0){
            $zok = @($zpr | Where-Object { $_.ok }).Count
            $right = ('{0}/{1} 可用' -f $zok, $zd.Count)
            if($zok -eq 0){ $dot=$C.red; $fill=$C.red }
            elseif($zok -lt $zd.Count){ $dot=$C.orange; $fill=$C.orange }
          }
        }
        else{
          $lkN = $t.id
          if($lineMap.ContainsKey($lkN) -and -not $lineMap[$lkN].ok){
            $right='探活失败'; $dot=$C.orange; $fill=$C.orange
          }
        }
      }
      # 全部分支统一补详情: 天数/额度 之后仍保留探活延迟与模型数
      $right = Add-LineDetail $t.id $right ($mdl.Count) $lineMap
      # 按警戒值归一化长条: 剩余/警戒值 满格; 低于警戒值 -> 按比例缩短并变红
      if($null -ne $metric -and $null -ne $warnDef){
        $wv = if($script:warnMap.ContainsKey([string]$t.id)){ [double]$script:warnMap[[string]$t.id] } else { [double]$warnDef }
        if($wv -gt 0){
          $mv = [double]$metric
          $frac = [Math]::Max(0.02, [Math]::Min(1.0, $mv/$wv))
          if(-not $warnLock){
            if($mv -ge $wv){ $dot=$C.green; $fill=$C.green } else { $dot=$C.red; $fill=$C.red }
          }
          $tip += ("`n警戒值 {0}（剩余低于它会变红条）" -f $wv)
        }
      }
      if(-not $authOk){ $dot=$C.red; $fill=$C.red; $right=('key ' + $authCode) }

      $provOk = ($t.status -eq 'active')
      # allProbeRed 时不在这里改红: 行按用户要求灰显「不可用」, 模型行才全红
      if($provOk -and $mdl.Count -gt 0 -and -not $allProbeRed){
        $anyOk = $false
        foreach($m in $mdl){
          $u = $true
          if($null -ne $m.usable){ $u = [bool]$m.usable }
          if($u){ $anyOk = $true; break }
        }
        if(-not $anyOk){ $dot=$C.red; $fill=$C.red; $frac=0.04; $right='全部不可用' }
      }

      $exp = [bool]$script:expanded[$t.id]
      $script:provIds += $t.id
      if($script:selLine -and $t.id -eq $script:selLine){ $right = '✓ 当前 · ' + $right }

      $script:recLines += [pscustomobject]@{ id=[string]$t.id; line=[string]$lineKey[$t.id]; name=[string]$nm; ok=(($dot -eq $C.green) -and $authOk -and $provOk) }
      New-ProviderRow $t.id $nm $right $frac $dot $fill $tip $y ($mdl.Count -gt 0) $exp $C.rowBrd
      if($t.id -eq 'baizhi'){
        $script:bzRowY = $y
        foreach($cl in $script:rowCtl[-1].Controls){
          if($cl -is [System.Windows.Forms.Label] -and $cl.Width -ge 100 -and $cl.TextAlign -eq 'MiddleRight'){
            $cl.Location = New-Object Drawing.Point(194,6); $cl.Size = New-Object Drawing.Size(158,20)
          }
        }
      }
      if($t.id -eq 'deepseek-official'){
        $script:dsRowY = $y
        foreach($cl in $script:rowCtl[-1].Controls){
          if($cl -is [System.Windows.Forms.Label] -and $cl.Width -ge 100 -and $cl.TextAlign -eq 'MiddleRight'){
            $cl.Location = New-Object Drawing.Point(194,6); $cl.Size = New-Object Drawing.Size(158,20)
          }
        }
      }
      $y += $ROWH + $GAP

      if($exp -and $mdl.Count -gt 0){
        foreach($m in $mdl){
          $usable = $provOk
          if($null -ne $m.usable){ $usable = $usable -and [bool]$m.usable }
          if($allProbeRed){ $usable = $false }   # 全红: 模型行一律按不可用(红)显示
          $q = $m.quota
          $mfrac=1.0; $mfill=$C.green; $mright='共享池'; $mrc=$C.dim
          if(-not $usable){
            $mrc=$C.gray; $mfill=$C.gray; $mfrac=0.02
            if($q -and $null -ne $q.total -and [double]$q.total -gt 0 -and [double]$q.remaining -le 0){
              $mright='已用完'; $mfill=$C.red; $mrc=$C.red
            }
            elseif($m.probe -and -not [bool]$m.probe.ok){
              $mright='不可用'; $mfill=$C.red; $mrc=$C.red
            }
            else{
              $mright='不启用'
            }
          }
          elseif($q -and [string]$q.unit -eq 'credits'){
            $mright='积分'; $mfrac=1.0; $mfill=$C.green
          }
          elseif($q -and [string]$q.unit -eq 'free'){
            $mright='免费'; $mfrac=1.0; $mfill=$C.green
          }
          elseif($q -and $null -ne $q.total -and [double]$q.total -gt 0){
            $remN = 0.0
            if($null -ne $q.remaining){ $remN = [double]$q.remaining }
            $mfrac = [Math]::Max(0.02, [Math]::Min(1.0, $remN/[double]$q.total))
            if($remN -le 0){ $mright='已用完'; $mfill=$C.red; $mfrac=0.02 }
            else{
              $mright = '剩' + (Format-Num $remN)
              if($mfrac -le 0.12){ $mfill=$C.red } elseif($mfrac -le 0.3){ $mfill=$C.orange }
            }
          }
          $mtip = [string]$m.name
          if($m.tier){ $mtip += "`n档位: $($m.tier)" }
          if($m.note){ $mtip += "`n$($m.note)" }
          if($m.probe -and $m.probe.at){
            if($m.probe.ok){ $mtip += "`n探活: $($m.probe.at) OK $($m.probe.ms)ms" }
            else { $mtip += "`n探活: $($m.probe.at) 失败 [$($m.probe.status)] $($m.probe.error)" }
          }
          if(-not $provOk){ $mtip += "`n线路状态: $($t.status)" }
          New-ModelRow ([string]$m.name) $mright $mfrac $mfill $mtip $y $usable $mrc $C.mrowBrd
          $y += $MODELH + 2
        }
      }
      $n++
    }
  }

  # 自定义服务商接入（手写设置接口）
  $cust = Read-CustomProviders
  if($cust -and $cust.Count -gt 0){
    foreach($cp in $cust){
      try{
        $cid = 'custom:' + [string]$cp.id
        $cname = [string]$cp.name
        $cright = '自定义接入'
        $ctip = 'Base: ' + [string]$cp.base_url
        $ck = ''
        if($cp.key_env){ $ck = [string]$cp.key_env }
        if($ck -ne ''){
          $kv = [Environment]::GetEnvironmentVariable($ck)
          if($kv){ $ctip += "`nKey 环境变量 $ck : 已设置" } else { $ctip += "`nKey 环境变量 $ck : 未设置"; $cright='缺key' }
        }else{ $ctip += '`n未配置 Key 环境变量' }
        $cdot=$C.green; $cfill=$C.green; $cfrac=0.6
        if($cright -eq '缺key'){ $cdot=$C.orange; $cfill=$C.orange }
        if($cp.note){ $ctip += "`n" + [string]$cp.note }
        $mdl=@()
        if($cp.models){ foreach($m in @($cp.models)){ $mdl += [pscustomobject]@{ name=[string]$m; tier='自定义'; usable=$true; quota=$null; note='' } } }
        $cexp = [bool]$script:expanded[$cid]
        $script:provIds += $cid
        New-ProviderRow $cid $cname $cright $cfrac $cdot $cfill $ctip $y ($mdl.Count -gt 0) $cexp $C.rowBrd
        $y += $ROWH + $GAP
        if($cexp -and $mdl.Count -gt 0){
          foreach($mm in $mdl){
            New-ModelRow ([string]$mm.name) '—' 0.0 $C.gray $ctip $y $true $C.dim $C.mrowBrd
            $y += $MODELH + 2
          }
        }
        $n++
      }catch{
        Write-Log ('自定义接入渲染失败 id=' + [string]$cp.id + ' :: ' + $_.Exception.Message)
      }
    }
  }

  $contentH = [Math]::Max(0, $y)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $maxH = [Math]::Max(200, $wa.Height - 80)
  $f.Height = [int][Math]::Min(($HDR + $contentH + 10), $maxH)
  $list.Size = New-Object Drawing.Size($W, ($f.Height - $HDR))
  $list.AutoScrollMinSize = New-Object Drawing.Size(0, ($contentH + 6))
  $f.Location = New-Object Drawing.Point(($wa.Right - $W - 8), ($wa.Bottom - $f.Height - 8))
  $sub.Text = ('{0} 条线 · {1}' -f $n, [DateTime]::Now.ToString('HH:mm'))
  if($script:bzBtn){
    $script:bzBtn.Text = if((Get-BaizhiDailyText) -eq '待验证'){ '验证' }else{ '领取' }
    if(($script:bzRowY -ge 0) -and (-not $script:bzDone)){
      $script:bzBtn.Location = New-Object Drawing.Point(($ROWX+$ROWW-42), ($script:bzRowY+6))
      if($script:bzBtn.Parent -ne $list){ $list.Controls.Add($script:bzBtn) }
      $script:bzBtn.Visible = $true
      $script:bzBtn.BringToFront()
      $tipTip.SetToolTip($script:bzBtn,'百智云每日领积分：点一下领 100（可能弹验证码）')
    }else{
      $script:bzBtn.Visible = $false
    }
  }
  if($script:dsBtn){
    if($script:dsRowY -ge 0){
      $script:dsBtn.Location = New-Object Drawing.Point(($ROWX+150), ($script:dsRowY+6))   # 文字栏左缘(194)之外, 不压字
      if($script:dsBtn.Parent -ne $list){ $list.Controls.Add($script:dsBtn) }
      $script:dsBtn.Visible = $true
      $script:dsBtn.BringToFront()
      $tipTip.SetToolTip($script:dsBtn,'打开 DeepSeek 平台用量/充值页 platform.deepseek.com/usage')
    }else{
      $script:dsBtn.Visible = $false
    }
  }
  try{
    $sl = Read-Utf8Json (Join-Path $TOKDIR 'selected-line.json')
    if($sl -and $sl.opencode_model){
      $script:curModel = $sl.opencode_model
      if($script:i11){ $script:i11.Text = '当前线路: ' + $script:curModel }
    }
  }catch{}
  Write-Recommendation
  # 线路异常提醒（只读 TOKENS.json 的 probe 结果，不额外发请求）
  try{ Update-AlertPanel $f }catch{ Write-Log ('alert panel failed: ' + $_.Exception.Message) }
  return $n
}

$cm = New-Object System.Windows.Forms.ContextMenuStrip
$i1=$cm.Items.Add('立即刷新');        $i1.Add_Click({ [void](Build-Rows) })
$i2=$cm.Items.Add('置顶 开/关');      $i2.Add_Click({ $f.TopMost = -not $f.TopMost })
$i5=$cm.Items.Add('全部展开');        $i5.Add_Click({ foreach($id in $script:provIds){ $script:expanded[$id]=$true }; [void](Build-Rows) })
$i6=$cm.Items.Add('全部收起');        $i6.Add_Click({ $script:expanded=@{}; [void](Build-Rows) })
$i9=$cm.Items.Add('⚙ 设置（手写接入）…'); $i9.Add_Click({ Show-SettingsForm })
$i3=$cm.Items.Add('打开台账目录');    $i3.Add_Click({ Start-Process explorer.exe $TOKDIR })
$i7=$cm.Items.Add('复制推荐可用线路'); $i7.Add_Click({ try{ [Windows.Forms.Clipboard]::SetText((Get-Content (Join-Path $TOKDIR 'recommended-line.json') -Raw)) }catch{} })
$i8=$cm.Items.Add('排序: 推荐序/自动'); $i8.Add_Click({ if($script:sortMode -eq 'auto'){ $script:sortMode='recommend' }else{ $script:sortMode='auto' }; [void](Build-Rows) })
$i8b=$cm.Items.Add('警戒值配置（warn.json）'); $i8b.Add_Click({ try{ Start-Process notepad $WARNJSON }catch{} })
$iAl1=$cm.Items.Add('异常提醒 开/关')
$iAl1.Add_Click({
  $script:alertEnabled = -not $script:alertEnabled
  if(-not $script:alertEnabled -and $script:alertForm){ $script:alertForm.Hide() }
  $script:alertSig = ''
  Write-Log ('alert enabled=' + $script:alertEnabled)
  [void](Build-Rows)
})
$iAl2=$cm.Items.Add('查看全部线路状态（含长期不可用）')
$iAl2.Add_Click({
  $script:alertForceShow = $true
  $script:alertExpanded  = $true
  $script:alertHidden    = $false
  $script:alertSig       = ''
  [void](Build-Rows)
})
$i10=$cm.Items.Add('设置百智云积分…')
$i10.Add_Click({
  $df = New-Object System.Windows.Forms.Form
  $df.Text='百智云积分'; $df.FormBorderStyle='FixedDialog'; $df.StartPosition='CenterScreen'
  $df.Size=New-Object Drawing.Size(266,146); $df.TopMost=$true
  $lb = New-Object System.Windows.Forms.Label
  $lb.Text='当前积分'; $lb.AutoSize=$true; $lb.Location=New-Object Drawing.Point(16,22)
  $nu = New-Object System.Windows.Forms.NumericUpDown
  $nu.Minimum=0; $nu.Maximum=1000000; $nu.Location=New-Object Drawing.Point(96,18)
  $nu.Size=New-Object Drawing.Size(130,24)
  $cur = 0
  $co = Read-Utf8Json $CREDITJSON
  if($co -and $null -ne $co.remaining){ $cur = [int]$co.remaining }
  elseif($tok -and $tok.tokens){
    $bz = @($tok.tokens | Where-Object { $_.id -eq 'baizhi' })[0]
    if($bz -and $bz.credits -and $null -ne $bz.credits.remaining){ $cur = [int]$bz.credits.remaining }
  }
  if($cur -ge 0 -and $cur -le 1000000){ $nu.Value = [decimal]$cur }
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text='保存'; $ok.Size=New-Object Drawing.Size(72,28); $ok.Location=New-Object Drawing.Point(50,68)
  $ok.Add_Click({
    $obj = @{ remaining = [int]$nu.Value; checked_at = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); source = '控件手动' }
    [IO.File]::WriteAllText($CREDITJSON, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $df.Close()
    [void](Build-Rows)
  })
  $cn = New-Object System.Windows.Forms.Button
  $cn.Text='取消'; $cn.Size=New-Object Drawing.Size(72,28); $cn.Location=New-Object Drawing.Point(140,68)
  $cn.Add_Click({ $df.Close() })
  $df.Controls.AddRange(@($lb,$nu,$ok,$cn))
  [void]$df.ShowDialog()
})
$iBz=$cm.Items.Add('百智每日领积分（点此立即领）')
$iBz.Add_Click({ [void](Invoke-BaizhiDaily -Force); [void](Build-Rows) })
$script:curModel = '—'
try{
  $sl = Read-Utf8Json (Join-Path $TOKDIR 'selected-line.json')
  if($sl -and $sl.opencode_model){ $script:curModel = $sl.opencode_model }
}catch{}
$script:i11=$cm.Items.Add(('当前线路: ' + $script:curModel))
$script:i11.Add_Click({ try{ [Windows.Forms.Clipboard]::SetText($script:curModel) }catch{} })
$i12=$cm.Items.Add('重新选择可用线路')
$i12.Add_Click({
  $lk = Read-Utf8Json (Join-Path $TOKDIR 'model-lock.json')
  if($lk -and $lk.locked){ Write-Log 'reselect skipped (locked)'; return }
  try{
    $out = & python (Join-Path $base 'select_model.py') --apply --quiet 2>&1
    Write-Log ('reselect -> ' + (($out | Out-String).Trim()))
  }catch{ Write-Log ('reselect failed: ' + $_.Exception.Message) }
  $sl = Read-Utf8Json (Join-Path $TOKDIR 'selected-line.json')
  if($sl -and $sl.opencode_model){
    $script:curModel = $sl.opencode_model
    $script:i11.Text = '当前线路: ' + $script:curModel
  }
  [void](Build-Rows)
})
$i13=$cm.Items.Add('锁定/解锁自动切换')
$i13.Add_Click({
  $lp = Join-Path $TOKDIR 'model-lock.json'
  $lk = Read-Utf8Json $lp
  $new = -not [bool]($lk -and $lk.locked)
  $obj = @{ locked = $new; at = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz') }
  [IO.File]::WriteAllText($lp, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  Write-Log ('auto-select lock=' + $new)
})
$i4=$cm.Items.Add('退出');            $i4.Add_Click({ $f.Close() })
$f.ContextMenuStrip = $cm
$list.ContextMenuStrip = $cm

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120000
$timer.Add_Tick({ [void](Build-Rows) })
$timer.Start()

$script:timer2 = New-Object System.Windows.Forms.Timer
$script:timer2.Interval = 25000
$script:timer2.Add_Tick({ $script:timer2.Stop(); Start-BaizhiDailyBackground; [void](Build-Rows) })
# key 到期提醒：任一线路 expires_at 在 7 天内（或已过期）时，每天弹一次
function Show-ExpiryReminders {
  try{
    $st = Read-Utf8Json (Join-Path $TOKDIR 'expiry-reminder.json')
    $today = [DateTime]::Now.ToString('yyyy-MM-dd')
    if($st -and $st.last -eq $today){ return }
    $tk = Read-Utf8Json $TOKJSON
    if(-not $tk -or -not $tk.tokens){ return }
    $now = [DateTimeOffset]::Now
    $due = @()
    foreach($x in $tk.tokens){
      if(-not $x.expires_at){ continue }
      if(-not ([string]$x.status).StartsWith('active')){ continue }
      try{
        $exp = [DateTimeOffset]::Parse([string]$x.expires_at, [Globalization.CultureInfo]::InvariantCulture)
      }catch{ continue }
      $days = ($exp - $now).TotalDays
      if($days -le 7){
        $nm = [string]$x.id
        if($x.provider){ $nm = (([string]$x.provider -split '[ ,（(]')[0]) }
        $d10 = ([string]$x.expires_at).Substring(0,10)
        if($days -lt 0){ $due += ('{0}：key 已过期 ({1})' -f $nm, $d10) }
        else{ $due += ('{0}：key 还有 {1} 天到期 ({2})' -f $nm, [int][Math]::Ceiling($days), $d10) }
      }
    }
    if($due.Count -eq 0){ return }
    [IO.File]::WriteAllText((Join-Path $TOKDIR 'expiry-reminder.json'),
      (@{ last = $today; lines = $due } | ConvertTo-Json),
      (New-Object Text.UTF8Encoding($false)))
    Write-Log ('expiry-reminder: ' + ($due -join ' / '))
    $msg = "以下 key 快到期了，请提前换新：`n`n" + ($due -join "`n") + "`n`n"
    $msg += "要换的三处：`n"
    $msg += "1. opencode.json  → 对应 provider 的 options.apiKey`n"
    $msg += "2. hermes config.yaml → 对应 base_url 那条 api_key`n"
    $msg += "3. tokens/TOKENS.json → 该线路的 expires_at（改成新 key 的 +30 天）"
    $msg += "`n`n（当天只弹这一次；到期后 select_model.py 会自动把它踢出候选）"
    [Windows.Forms.MessageBox]::Show($msg, 'ALEN 额度条 · key 到期提醒',
      [Windows.Forms.MessageBoxButtons]::OK,
      [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
  }catch{ Write-Log ('expiry-reminder failed: ' + $_.Exception.Message) }
}

$script:timer2.Start()
$script:timer2.Add_Tick({ Show-ExpiryReminders })

$script:expTimer = New-Object System.Windows.Forms.Timer
$script:expTimer.Interval = 3600000
$script:expTimer.Add_Tick({ Show-ExpiryReminders })
$script:expTimer.Start()

# 每 30 分钟检查一次；脚本内部按日期去重，当天成功领过会直接跳过
$script:bzTimer = New-Object System.Windows.Forms.Timer
$script:bzTimer.Interval = 1800000
$script:bzTimer.Add_Tick({ Start-BaizhiDailyBackground; [void](Build-Rows) })
$script:bzTimer.Start()

$rows = Build-Rows
Write-Log ('shown rows=' + $rows)
[System.Windows.Forms.Application]::Run($f)
Write-Log 'closed'
