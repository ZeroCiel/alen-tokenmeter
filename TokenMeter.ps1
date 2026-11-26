# ALEN TokenMeter 额度条 v1.1.0 —— 线路可展开模型明细（剩余额度 / 免费 / 不启用）
# 数据源: tokens\TOKENS.json (台账, 含 model_details) + FREE-LINES-status.json (探活) + TOKEN-STATUS.json (钥匙巡检)
# 交互: 点线路行展开/收起模型; 按住拖动移动窗口; 右键菜单
# 必须保存为 UTF-8 BOM; 启动: powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File TokenMeter.ps1
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $base 'tokenmeter.log'
function Write-Log([string]$m){ try{ "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $m" | Out-File -FilePath $log -Append -Encoding UTF8 }catch{} }

$mutex = New-Object System.Threading.Mutex($false, 'ALENTokenMeterMutex')
if(-not $mutex.WaitOne(0, $false)){ Write-Log 'already running - exit'; exit }

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
  'moma-deepseek'='MoMA 移动云'; 'qiniu-conatus'='七牛活动'; 'free-amd'='AMD 云'; 'modelscope'='魔搭'
  'zhipu'='智谱'; 'magpie-zen'='Magpie Zen'; 'opencode-zen-builtin'='Zen 内置'; 'deepseek-official'='DS 官方'
  'groq'='Groq'; 'openai-gemini'='OAI/Gem'; 'scnet-maas'='SCNet按量'; 'scnet-tokenplan'='SCNet套餐'
  'gitcode-codingplan'='GitCode Lite'
}
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
}

$W=380; $HDR=40; $ROWH=32; $MODELH=24; $GAP=3
$ROWX=8; $ROWW=$W-20

$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.BackColor=$C.bg
$f.Size=New-Object Drawing.Size($W,240)
$f.TopMost=$true; $f.ShowInTaskbar=$false; $f.StartPosition='Manual'; $f.Text='ALEN额度条'
$f.Opacity=0.97

$title = New-Object System.Windows.Forms.Label
$title.Text='◆ ALEN 额度条'; $title.AutoSize=$false
$title.Size=New-Object Drawing.Size(160,24); $title.Location=New-Object Drawing.Point(12,9)
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

function New-ProviderRow([string]$id,[string]$name,[string]$right,[double]$frac,$dotC,$fillC,[string]$tip,[int]$y,[bool]$expandable,[bool]$expanded){
  $rp = New-Object System.Windows.Forms.Panel
  $rp.Size=New-Object Drawing.Size($ROWW,$ROWH); $rp.Location=New-Object Drawing.Point($ROWX,$y)
  $rp.BackColor=$C.row

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

  $track = New-Object System.Windows.Forms.Panel
  $track.Size=New-Object Drawing.Size(110,8); $track.Location=New-Object Drawing.Point(132,12)
  $track.BackColor=$C.track
  $fillP = New-Object System.Windows.Forms.Panel
  $fw = [int][Math]::Max(3, [Math]::Min(1.0,$frac)*110)
  $fillP.Size=New-Object Drawing.Size($fw,8); $fillP.Location=New-Object Drawing.Point(0,0)
  $fillP.BackColor=$fillC
  $track.Controls.Add($fillP)

  $rl = New-Object System.Windows.Forms.Label
  $rl.Text=$right; $rl.AutoSize=$false; $rl.Size=New-Object Drawing.Size(106,20)
  $rl.Location=New-Object Drawing.Point(246,6); $rl.ForeColor=$C.dim
  $rl.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $rl.TextAlign='MiddleRight'
  $rl.BackColor=[Drawing.Color]::Transparent

  foreach($ctl in @($ind,$dotL,$nm,$track,$rl)){ $rp.Controls.Add($ctl) }
  foreach($ctl in @($rp,$ind,$dotL,$nm,$track,$fillP,$rl)){ Add-Mouse $ctl $id }
  if($tip){ $tipTip.SetToolTip($rp,$tip); $tipTip.SetToolTip($nm,$tip) }
  $list.Controls.Add($rp)
  $script:rowCtl += $rp
}

function New-ModelRow([string]$name,[string]$right,[double]$frac,$fillC,[string]$tip,[int]$y,[bool]$usable,$rightColor){
  $rw = $ROWW - 24
  $rp = New-Object System.Windows.Forms.Panel
  $rp.Size=New-Object Drawing.Size($rw,$MODELH); $rp.Location=New-Object Drawing.Point(($ROWX+24),$y)
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

  $track = New-Object System.Windows.Forms.Panel
  $track.Size=New-Object Drawing.Size(80,6); $track.Location=New-Object Drawing.Point(186,9)
  $track.BackColor=$C.track
  $fillP = New-Object System.Windows.Forms.Panel
  $fw = [int][Math]::Max(2, [Math]::Min(1.0,$frac)*80)
  $fillP.Size=New-Object Drawing.Size($fw,6); $fillP.Location=New-Object Drawing.Point(0,0)
  $fillP.BackColor=$fillC
  $track.Controls.Add($fillP)

  $rl = New-Object System.Windows.Forms.Label
  $rl.Text=$right; $rl.AutoSize=$false; $rl.Size=New-Object Drawing.Size(70,18)
  $rl.Location=New-Object Drawing.Point(266,3)
  $rl.ForeColor = $rightColor
  $rl.Font=New-Object Drawing.Font('Microsoft YaHei UI',8.25); $rl.TextAlign='MiddleRight'
  $rl.BackColor=[Drawing.Color]::Transparent

  foreach($ctl in @($nm,$track,$rl)){ $rp.Controls.Add($ctl) }
  foreach($ctl in @($rp,$nm,$track,$fillP,$rl)){ Add-Mouse $ctl '' }
  if($tip){ $tipTip.SetToolTip($rp,$tip); $tipTip.SetToolTip($nm,$tip) }
  $list.Controls.Add($rp)
  $script:rowCtl += $rp
}

function Build-Rows{
  foreach($r in $script:rowCtl){ try{ $r.Dispose() }catch{} }
  $script:rowCtl = @()
  $script:provIds = @()

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
    foreach($t in $tok.tokens){
      if($t.id -eq 'scnet-token-plan'){ continue }
      if($t.status -like 'removed*'){ continue }
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

      $mdl = @()
      if($t.model_details){ $mdl = @($t.model_details) }
      elseif($t.models){ foreach($m in @($t.models)){ $mdl += [pscustomobject]@{ name=[string]$m; tier='?'; usable=$true; quota=$null; note='' } } }

      $provOk = ($t.status -eq 'active')
      if($provOk -and $mdl.Count -gt 0){
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

      New-ProviderRow $t.id $nm $right $frac $dot $fill $tip $y ($mdl.Count -gt 0) $exp
      $y += $ROWH + $GAP

      if($exp -and $mdl.Count -gt 0){
        foreach($m in $mdl){
          $usable = $provOk
          if($null -ne $m.usable){ $usable = $usable -and [bool]$m.usable }
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
          New-ModelRow ([string]$m.name) $mright $mfrac $mfill $mtip $y $usable $mrc
          $y += $MODELH + 2
        }
      }
      $n++
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
  return $n
}

$cm = New-Object System.Windows.Forms.ContextMenuStrip
$i1=$cm.Items.Add('立即刷新');        $i1.Add_Click({ [void](Build-Rows) })
$i2=$cm.Items.Add('置顶 开/关');      $i2.Add_Click({ $f.TopMost = -not $f.TopMost })
$i5=$cm.Items.Add('全部展开');        $i5.Add_Click({ foreach($id in $script:provIds){ $script:expanded[$id]=$true }; [void](Build-Rows) })
$i6=$cm.Items.Add('全部收起');        $i6.Add_Click({ $script:expanded=@{}; [void](Build-Rows) })
$i3=$cm.Items.Add('打开台账目录');    $i3.Add_Click({ Start-Process explorer.exe $TOKDIR })
$i4=$cm.Items.Add('退出');            $i4.Add_Click({ $f.Close() })
$f.ContextMenuStrip = $cm
$list.ContextMenuStrip = $cm

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120000
$timer.Add_Tick({ [void](Build-Rows) })
$timer.Start()

$rows = Build-Rows
Write-Log ('shown rows=' + $rows)
[System.Windows.Forms.Application]::Run($f)
Write-Log 'closed'
