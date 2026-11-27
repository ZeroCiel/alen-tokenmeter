# =====================================================================
# ALEN TokenMeter · 线路异常提醒小窗 (alert panel)
#   由 TokenMeter.ps1 dot-source 进来（共享脚本作用域，用得到 $C/$shortNames/$TOKDIR）
#
#   数据源: tokens\TOKENS.json → tokens[].model_details[].probe
#           probe 由 probe_models.py 或 select_model.py 写入 {at, ok, status, ms, error}
#   分级:  红 red    = 当前主力线路 0 个模型可用（断了，必须看）
#          橙 orange = 非主力线路刚全挂（上次还有可用）/ 主力线路部分模型不通
#          灰 gray   = 一直不可用（默认折叠，不打扰；菜单里可看）
#   窗口: 贴额度条正上方的无边框侧边条, 不抢焦点(WS_EX_NOACTIVATE), 无红橙自动隐藏
#   防扰: 点「知道了」写入 alert-state.json 的 ack, 同样的异常不再响; 新异常才再响一次
# =====================================================================

$script:alertForm       = $null
$script:alertOwner      = $null
$script:alertLines      = @()
$script:alertRowCtls    = @()
$script:alertHidden     = $false
$script:alertHiddenIds  = @()
$script:alertExpanded   = $false
$script:alertSig        = ''
$script:alertAck        = @()
$script:alertPinged     = @()
$script:alertProbing    = $false
$script:alertProbeTimer = $null
$script:alertEnabled    = $true
$script:alertChatAt     = [DateTime]::MinValue
$script:alertForceShow  = $false
$script:alertAW         = 300
$AC = $C                    # 颜色表别名: 防止函数内 foreach($c..) 把 $C 遮蔽成 $null
$script:alertStatePath  = Join-Path $TOKDIR 'alert-state.json'

# ---- 无激活窗体: Show 时不抢焦点（贴边提醒的关键）----
if(-not ('ALENNoActivateForm' -as [type])){
  try{
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class ALENNoActivateForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000; return cp; }
    }
}
'@ -ReferencedAssemblies @('System.Windows.Forms','System.Drawing')
  }catch{
    try{ Write-Log ('alert: NoActivateForm 编译失败, 退回普通窗口: ' + $_.Exception.Message) }catch{}
  }
}

# ================= 文本/原因解析 =================
function Get-AlertErrMsg([string]$raw){
  if(-not $raw){ return '' }
  $s = $raw.Trim()
  if($s.StartsWith('{') -or $s.StartsWith('[')){
    try{
      $j = ConvertFrom-Json $s
      if($j.error){
        if($j.error -is [string]){ return [string]$j.error }
        if($j.error.message){ return [string]$j.error.message }
        if($j.error.error -and $j.error.error.message){ return [string]$j.error.error.message }
      }
      if($j.detail -and $j.detail.error -and $j.detail.error.message){ return [string]$j.detail.error.message }
      if($j.detail -and $j.detail.message){ return [string]$j.detail.message }
      if($j.message){ return [string]$j.message }
    }catch{}
  }
  return $s
}

function Get-AlertReason([string]$err,[int]$status){
  $m = Get-AlertErrMsg $err
  $low = ''
  if($m){ $low = $m.ToLower() }
  if($low -match 'errno 2|10061|connection refused|actively refused|积极拒绝|由于目标计算机'){ return '本地网关没起来' }
  if($low -match 'model_not_found|model not found|does not exist|no such model|已下线'){ return '模型不存在/已下线' }
  if($status -eq 401 -or $low -match 'unauthorized|invalid.{0,12}key|authentication'){ return 'key 无效/过期' }
  if($status -eq 403){ return '无权限 403' }
  if($low -match 'subscription_required|余额不足|insufficient balance|billing|top-up|订购|充值'){ return '需开通或充值' }
  if($status -eq 429 -or $low -match 'rate.?limit|at capacity|usage limit|quota|限流'){ return '限流/额度用尽' }
  if($low -match 'timed? ?out|超时|timeout'){ return '超时无响应' }
  if($status -gt 0){
    $t = $m; if($t -and $t.Length -gt 22){ $t = $t.Substring(0,22) + '…' }
    return ('HTTP ' + $status + ' ' + $t)
  }
  $t = $m; if($t -and $t.Length -gt 26){ $t = $t.Substring(0,26) + '…' }
  if($t){ return $t }
  return '未知失败'
}

function Format-AlertWhen([string]$iso){
  if(-not $iso){ return '' }
  $t = [DateTimeOffset]::MinValue
  if(-not [DateTimeOffset]::TryParse($iso, [ref]$t)){ return '' }
  $d = [DateTimeOffset]::Now - $t
  if($d.TotalMinutes -lt 1){ return '刚刚' }
  if($d.TotalMinutes -lt 60){ return ('{0} 分钟前' -f [int]$d.TotalMinutes) }
  if($d.TotalHours -lt 24){ return ('{0} 小时前' -f [int]$d.TotalHours) }
  return ('{0} 天前' -f [int]$d.TotalDays)
}

function Read-AlertState {
  $snap = @{}; $ack = @(); $mute = [DateTimeOffset]::MinValue
  $st = Read-Utf8Json $script:alertStatePath
  if($st){
    try{ if($st.snap){ foreach($p in $st.snap.PSObject.Properties){ $snap[[string]$p.Name] = [int]$p.Value } } }catch{}
    try{ if($st.ack){ $ack = @($st.ack | ForEach-Object { [string]$_ }) } }catch{}
    try{ if($st.muteUntil){ $mute = [DateTimeOffset]::Parse([string]$st.muteUntil) } }catch{}
  }
  return @{ snap=$snap; ack=$ack; mute=$mute }
}

function Save-AlertState($snap,$ack,$mute){
  try{
    $o = [ordered]@{
      updated   = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
      snap      = $snap
      ack       = @($ack)
      muteUntil = [string]$mute
    }
    [IO.File]::WriteAllText($script:alertStatePath, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  }catch{}
}

# 告警去重键：探活类用 id|ok/total；对话失败类用 chat:...|最后发生时间（同一错误不重复叫）
function Get-AlertAckKey($l){
  if($l -and $l.ackKey){ return [string]$l.ackKey }
  return ("$($l.id)|$($l.ok)/$($l.total)")
}

# ================= 数据聚合 =================
function Get-AlertData {
  $tk = Read-Utf8Json $TOKJSON
  if(-not $tk -or -not $tk.tokens){ return @() }
  $cur = ''
  try{
    $sl = Read-Utf8Json (Join-Path $TOKDIR 'selected-line.json')
    if($sl -and $sl.line){ $cur = [string]$sl.line }
  }catch{}
  $rs   = Read-AlertState
  $snap = $rs.snap
  $out  = @()
  foreach($t in $tk.tokens){
    $id = [string]$t.id
    if($id -eq 'zcode-context'){ continue }
    if([string]$t.status -like 'removed*'){ continue }   # 已废弃的线路不再进告警(额度条也不显示)
    $probed = @()
    foreach($m in @($t.model_details)){
      if($m -and $m.probe -and $m.probe.at){ $probed += $m }
    }
    if($probed.Count -eq 0){ continue }
    $okN = 0; $bad = @()
    foreach($m in $probed){
      if([bool]$m.probe.ok){ $okN++ } else { $bad += $m }
    }
    $prev = -1
    if($snap.ContainsKey($id)){ $prev = [int]$snap[$id] }
    $isCur = ($id -eq $cur)

    $sev = $null
    if($okN -eq 0){
      if($isCur){ $sev = 'red' }
      elseif($prev -gt 0){ $sev = 'orange' }
      else{ $sev = 'gray' }
    }
    elseif($isCur -and $okN -lt $probed.Count){ $sev = 'orange' }
    if(-not $sev){ continue }

    $reason = ''; $whenIso = ''; $detail = ''
    if($bad.Count -gt 0){
      $latest = $bad[0]
      foreach($b in $bad){ try{ if([string]$b.probe.at -gt [string]$latest.probe.at){ $latest = $b } }catch{} }
      $reason  = Get-AlertReason ([string]$latest.probe.error) ([int]$latest.probe.status)
      $whenIso = [string]$latest.probe.at
      $detail  = "$($latest.name): " + [string]$latest.probe.error
      if($detail.Length -gt 900){ $detail = $detail.Substring(0,900) + '…' }
    }
    $nm = $shortNames[$id]; if(-not $nm){ $nm = $id }
    $out += [pscustomobject]@{
      id=$id; name=$nm; ok=$okN; total=$probed.Count; sev=$sev; isCur=$isCur
      reason=$reason; when=(Format-AlertWhen $whenIso); detail=$detail
    }
  }

  # ---- 真实「回话失败」：opencode.db 里 assistant 消息带的 error（由 chat_errors.py 抽出）----
  $ce = Read-Utf8Json (Join-Path $TOKDIR 'chat-errors.json')
  if($ce -and $ce.errors){
    $nowO = [DateTimeOffset]::Now
    foreach($e in @($ce.errors)){
      $lastT = [DateTimeOffset]::MinValue
      if($e.last){ try{ $lastT = [DateTimeOffset]::Parse([string]$e.last) }catch{} }
      if($lastT -eq [DateTimeOffset]::MinValue){ continue }
      if(($nowO - $lastT).TotalMinutes -gt 30){ continue }   # 只提醒半小时内发生过的
      $prov = [string]$e.provider
      # 只有「红/橙」的探活条目才算重复; 灰线(长期不可用)不吞掉「刚刚真实失败」
      $already = @($out | Where-Object { $_.id -like "*$prov*" -and $_.sev -ne 'gray' }).Count -gt 0
      if($already){ continue }                                # 探活已经报过这家, 不重复
      $isCurC = ($prov -eq $cur) -or ($cur -like "$prov*")
      $sevC2  = if($isCurC){ 'red' } else { 'orange' }
      $out += [pscustomobject]@{
        id      = ('chat:' + $prov + '/' + $e.model + '/' + $e.status)
        name    = ('对话 · ' + $prov + '/' + $e.model)
        ok      = 0
        total   = [int]$e.count
        sev     = $sevC2
        isCur   = $isCurC
        reason  = (Get-AlertReason ([string]$e.msg) ([int]$e.status))
        when    = (Format-AlertWhen ([string]$e.last))
        detail  = ("模型 $($e.model) · HTTP $($e.status) · $($e.type)`n$($e.msg)`n近 6 小时出现 $($e.count) 次，最后 $($e.last)")
        ackKey  = ('chat:' + $prov + '|' + $e.model + '|' + $e.status + '|' + $e.last)
        isChat  = $true
      }
    }
  }

  $rank = @{ red=0; orange=1; gray=2 }
  $out = @($out | Sort-Object -Property @{Expression={ $rank[[string]$_.sev] }},
                                        @{Expression={ if($_.isCur){0}else{1} }},
                                        @{Expression={ [string]$_.name }})
  return $out
}

# ================= 窗体 =================
function New-AlertForm {
  if($script:alertForm){ return }
  $tt = 'ALENNoActivateForm' -as [type]
  if($tt){ $af = New-Object $tt } else { $af = New-Object System.Windows.Forms.Form }
  $af.FormBorderStyle = 'None'
  $af.StartPosition   = 'Manual'
  $af.BackColor       = $AC.bg
  $af.TopMost         = $true
  $af.ShowInTaskbar   = $false
  $af.Size            = New-Object Drawing.Size($script:alertAW,140)
  $af.Text            = 'ALEN 线路异常'
  $af.Add_Paint({
    param($s,$e)
    $g = $e.Graphics
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(70,76,90))
    $g.DrawRectangle($pen, 0, 0, ($s.Width-1), ($s.Height-1))
    $pen2 = New-Object Drawing.Pen([Drawing.Color]::FromArgb(42,47,56))
    [void]$g.DrawLine($pen2, 0, 28, ($s.Width-1), 28)
    $pen.Dispose(); $pen2.Dispose()
  })
  $script:alertForm = $af
}

function Build-AlertUI {
  $af = $script:alertForm
  if(-not $af){ return }
  foreach($ctl in $script:alertRowCtls){ try{ $ctl.Dispose() }catch{} }
  $script:alertRowCtls = @()

  $W    = $script:alertAW
  $hot  = @($script:alertLines | Where-Object { $_.sev -ne 'gray' })
  $cold = @($script:alertLines | Where-Object { $_.sev -eq 'gray' })
  $ids  = @($hot | ForEach-Object { (Get-AlertAckKey $_) })
  $allAck = ($ids.Count -gt 0) -and (@($ids | Where-Object { $script:alertAck -notcontains $_ }).Count -eq 0)

  $hasRed = @($hot | Where-Object { $_.sev -eq 'red' }).Count -gt 0
  $headC  = if($hasRed){ $AC.red } elseif($hot.Count -gt 0){ $AC.orange } else { $AC.dim }

  $hd = New-Object System.Windows.Forms.Label
  $hd.AutoSize  = $false
  $hd.Size      = New-Object Drawing.Size(($W-38), 20)
  $hd.Location  = New-Object Drawing.Point(10, 5)
  $hd.BackColor = [Drawing.Color]::Transparent
  $hd.ForeColor = $headC
  $hd.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
  if($hot.Count -gt 0){
    $hd.Text = if($allAck){ ('● 线路异常 {0} 条（已知）' -f $hot.Count) } else { ('⚠ 线路异常 {0} 条' -f $hot.Count) }
  }else{
    $hd.Text = ('✓ 主力线路正常 · {0} 条长期不可用' -f $cold.Count)
  }
  $af.Controls.Add($hd); $script:alertRowCtls += $hd

  $btnX = New-Object System.Windows.Forms.Button
  $btnX.Text      = '×'
  $btnX.Size      = New-Object Drawing.Size(22, 20)
  $btnX.Location  = New-Object Drawing.Point(($W-26), 4)
  $btnX.FlatStyle = 'Flat'
  $btnX.FlatAppearance.BorderSize = 0
  $btnX.TabStop = $false
  $btnX.BackColor = $AC.bg
  $btnX.ForeColor = $AC.dim
  $btnX.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 10)
  $btnX.Add_Click({
    $script:alertHidden    = $true
    $script:alertHiddenIds = @($script:alertLines | Where-Object { $_.sev -ne 'gray' } | ForEach-Object { (Get-AlertAckKey $_) })
    $script:alertForceShow = $false
    if($script:alertForm){ $script:alertForm.Hide() }
  })
  $af.Controls.Add($btnX); $script:alertRowCtls += $btnX

  $y = 32
  $shown = 0
  foreach($l in $hot){
    if($shown -ge 5){ break }
    $sevC = if($l.sev -eq 'red'){ $AC.red } else { $AC.orange }
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Size      = New-Object Drawing.Size(($W-8), 34)
    $pnl.Location  = New-Object Drawing.Point(4, $y)
    $pnl.BackColor = $AC.row
    $pnl.Tag       = $sevC
    $pnl.Add_Paint({
      param($s,$e)
      $g = $e.Graphics
      $b = New-Object Drawing.SolidBrush([System.Drawing.Color]$s.Tag)
      $g.FillRectangle($b, 0, 0, 3, $s.Height)
      $g.FillEllipse($b, 9, 6, 6, 6)
      $b.Dispose()
    })

    $t1 = New-Object System.Windows.Forms.Label
    $t1.AutoSize  = $false
    $t1.Size      = New-Object Drawing.Size(($W-40), 16)
    $t1.Location  = New-Object Drawing.Point(20, 2)
    $t1.BackColor = [Drawing.Color]::Transparent
    $t1.ForeColor = $AC.txt
    $t1.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 8.5, [Drawing.FontStyle]::Bold)
    $t1.AutoEllipsis = $true
    $mark = if($l.isCur){ ' · 主力' } else { '' }
    if($l.isChat){ $t1.Text = ('{0}{1}   {2} 次失败' -f $l.name, $mark, $l.total) }
    else { $t1.Text = ('{0}{1}   {2}/{3} 可用' -f $l.name, $mark, $l.ok, $l.total) }
    $pnl.Controls.Add($t1)

    $t2 = New-Object System.Windows.Forms.Label
    $t2.AutoSize  = $false
    $t2.Size      = New-Object Drawing.Size(($W-40), 15)
    $t2.Location  = New-Object Drawing.Point(20, 17)
    $t2.BackColor = [Drawing.Color]::Transparent
    $t2.ForeColor = $AC.dim
    $t2.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.75)
    $t2.Text = ('{0} · {1}' -f $l.reason, $l.when)
    $pnl.Controls.Add($t2)

    try{ $tipTip.SetToolTip($pnl, [string]$l.detail) }catch{}
    $af.Controls.Add($pnl); $script:alertRowCtls += $pnl
    $y += 38; $shown++
  }
  if($hot.Count -gt $shown){
    $more = New-Object System.Windows.Forms.Label
    $more.AutoSize  = $false
    $more.Size      = New-Object Drawing.Size(($W-16), 16)
    $more.Location  = New-Object Drawing.Point(12, $y)
    $more.BackColor = [Drawing.Color]::Transparent
    $more.ForeColor = $AC.dim
    $more.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.75)
    $more.Text = ('另有 {0} 条异常（右键菜单可看全部）' -f ($hot.Count - $shown))
    $af.Controls.Add($more); $script:alertRowCtls += $more
    $y += 18
  }

  if($cold.Count -gt 0){
    $gl = New-Object System.Windows.Forms.Label
    $gl.AutoSize  = $false
    $gl.Size      = New-Object Drawing.Size(($W-16), 18)
    $gl.Location  = New-Object Drawing.Point(12, ($y+2))
    $gl.BackColor = [Drawing.Color]::Transparent
    $gl.ForeColor = $AC.dim
    $gl.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.75)
    $gl.Text = if($script:alertExpanded){ ('− 收起长期不可用（{0} 条）' -f $cold.Count) } else { ('+ {0} 条长期不可用 ▸' -f $cold.Count) }
    $gl.Cursor = [Windows.Forms.Cursors]::Hand
    $gl.Add_Click({
      $script:alertExpanded = -not $script:alertExpanded
      $script:alertSig = ''
      Update-AlertPanel $script:alertOwner
    })
    $af.Controls.Add($gl); $script:alertRowCtls += $gl
    $y += 22
    if($script:alertExpanded){
      foreach($l in $cold){
        $cl = New-Object System.Windows.Forms.Label
        $cl.AutoSize  = $false
        $cl.Size      = New-Object Drawing.Size(($W-24), 15)
        $cl.Location  = New-Object Drawing.Point(16, $y)
        $cl.BackColor = [Drawing.Color]::Transparent
        $cl.ForeColor = $AC.gray
        $cl.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.75)
        $cl.Text = ('{0} · {1} · {2}' -f $l.name, $l.reason, $l.when)
        try{ $tipTip.SetToolTip($cl, [string]$l.detail) }catch{}
        $af.Controls.Add($cl); $script:alertRowCtls += $cl
        $y += 16
      }
    }
  }

      # ---- 底部按钮：用 Label 自绘，避免 Button 抢焦点/画焦点虚线框 ----
  $y += 4
  $mkBtn = {
    param($text,$x,$w,$fg)
    $b = New-Object System.Windows.Forms.Label
    $b.Text      = $text
    $b.TextAlign = 'MiddleCenter'
    $b.AutoSize  = $false
    $b.Size      = New-Object Drawing.Size($w, 21)
    $b.Location  = New-Object Drawing.Point($x, $y)
    $b.BackColor = [Drawing.Color]::FromArgb(46,50,58)
    $b.ForeColor = $fg
    $b.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.75)
    $b.Cursor    = [Windows.Forms.Cursors]::Hand
    $b.Add_MouseEnter({ param($s,$e) $s.BackColor = [Drawing.Color]::FromArgb(62,68,80) })
    $b.Add_MouseLeave({ param($s,$e) $s.BackColor = [Drawing.Color]::FromArgb(46,50,58) })
    return $b
  }

  $bOk = & $mkBtn $(if($allAck){ '已确认' } else { '知道了' }) 8 58 $(if($allAck){ $AC.dim } else { $AC.txt })
  $bOk.Add_Click({
    $cur  = @($script:alertLines | Where-Object { $_.sev -ne 'gray' } | ForEach-Object { (Get-AlertAckKey $_) })
    $snap = @{}
        foreach($l in $script:alertLines){ $snap[$l.id] = [int]$l.ok }
    $rs = Read-AlertState
    Save-AlertState $snap $cur $rs.mute
    $script:alertAck = $cur
    # 确认即收起: 记住这批 id, 只有出现「新的」异常才再弹出来
    $script:alertHiddenIds = @($cur)
    $script:alertHidden = $true
    $script:alertSig = ''
    Update-AlertPanel $script:alertOwner
  })
  $af.Controls.Add($bOk); $script:alertRowCtls += $bOk

  $bProbe = & $mkBtn $(if($script:alertProbing){ '探测中…' } else { '重测' }) 70 50 ([Drawing.Color]::FromArgb(124,156,255))
  $bProbe.Add_Click({ Start-AlertProbe })
  $af.Controls.Add($bProbe); $script:alertRowCtls += $bProbe

  $bLog = & $mkBtn '日志' 124 46 $AC.dim
  $bLog.Add_Click({ try{ Start-Process notepad.exe (Join-Path $base 'tokenmeter.log') }catch{} })
  $af.Controls.Add($bLog); $script:alertRowCtls += $bLog

  $stamp = New-Object System.Windows.Forms.Label
  $stamp.AutoSize  = $false
  $stamp.Size      = New-Object Drawing.Size(96, 21)
  $stamp.Location  = New-Object Drawing.Point(($W-104), $y)
  $stamp.BackColor = [Drawing.Color]::Transparent
  $stamp.ForeColor = $AC.gray
  $stamp.Font      = New-Object Drawing.Font('Microsoft YaHei UI', 7.5)
  $stamp.TextAlign = 'MiddleRight'
  $tk = Read-Utf8Json $TOKJSON
  $stamp.Text = ''
  if($tk -and $tk.updated_at){
    $u = [string]$tk.updated_at
    if($u.Length -ge 16){ $stamp.Text = ('探活 ' + $u.Substring(5,11).Replace('T',' ')) }
  }
  $af.Controls.Add($stamp); $script:alertRowCtls += $stamp

  $y += 26
  $af.Height = [int]$y
  if($af.Height -lt 60){ $af.Height = 60 }
}

# ================= 定位 / 显隐 / 刷新 =================
# 同层置顶(不改变激活状态): 防止告警窗被额度条盖住
if(-not ('ALENZOrder' -as [type])){
  try{
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ALENZOrder {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static void Top(IntPtr h){
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }
}
"@
  }catch{ }
}
function Sync-AlertPanel($owner){
  $af = $script:alertForm
  if(-not $af){ return }
  if(-not $af.Visible){ return }
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $x  = $wa.Right - $af.Width - 8
  $y  = $wa.Top + 8
  if($owner){
    # 1) 首选: 额度条正上方
    $x = $owner.Left
    $y = $owner.Top - $af.Height - 8
    if($y -lt ($wa.Top + 8)){
      # 2) 上方放不下(额度条很高) → 贴额度条左侧
      $lx = $owner.Left - $af.Width - 8
      if($lx -ge ($wa.Left + 8)){
        $x = $lx; $y = $owner.Top
      }else{
        # 3) 左侧也贴边 → 放右侧
        $rx = $owner.Right + 8
        if(($rx + $af.Width) -le ($wa.Right - 8)){ $x = $rx; $y = $owner.Top }
        else{ $y = $wa.Top + 8 }
      }
    }
  }
  if(($x + $af.Width) -gt $wa.Right){ $x = $wa.Right - $af.Width - 8 }
  if($x -lt $wa.Left){ $x = $wa.Left + 8 }
  if($y -lt ($wa.Top + 8)){ $y = $wa.Top + 8 }
  if(($y + $af.Height) -gt $wa.Bottom){ $y = $wa.Bottom - $af.Height - 8 }
  $af.Location = New-Object Drawing.Point($x, $y)
  # 万一与额度条重叠, 把告警窗提到同层最前(不抢焦点)
  try{ [void][ALENZOrder]::Top($af.Handle) }catch{}
}

function Update-AlertPanel($owner){
  $script:alertOwner = $owner
  if(-not $script:alertForm){ New-AlertForm }
  if(-not $script:alertForm){ return }

  # 每 5 分钟扫一次 opencode 会话库里的「回话失败」（chat_errors.py）
  if(([DateTime]::Now - $script:alertChatAt).TotalSeconds -gt 300){
    $script:alertChatAt = [DateTime]::Now
    $cep = Join-Path $base 'chat_errors.py'
    if(Test-Path $cep){ try{ Start-Process -FilePath 'python' -ArgumentList @($cep) -WindowStyle Hidden | Out-Null }catch{} }
  }

  $data = @(Get-AlertData)
  $script:alertLines = $data
  $hot = @($data | Where-Object { $_.sev -ne 'gray' })

  $rs = Read-AlertState
  $script:alertAck = @($rs.ack)

  # 关掉了提醒但出现新的红/橙 → 再叫一次
  if($script:alertHidden -and $hot.Count -gt 0){
    $nowIds = @($hot | ForEach-Object { (Get-AlertAckKey $_) })
    $fresh  = @($nowIds | Where-Object { $script:alertHiddenIds -notcontains $_ })
    if($fresh.Count -gt 0){ $script:alertHidden = $false; $script:alertPinged = @() }
  }

  # 新异常提示音（只在未确认、未静音、且非自己触发探测时响）
  if($script:alertEnabled -and -not $script:alertProbing -and $hot.Count -gt 0){
    $nowIds   = @($hot | ForEach-Object { (Get-AlertAckKey $_) })
    $unacked  = @($nowIds | Where-Object { $script:alertAck -notcontains $_ })
    $freshSnd = @($unacked | Where-Object { $script:alertPinged -notcontains $_ })
    if($freshSnd.Count -gt 0 -and [DateTimeOffset]::Now -gt $rs.mute){
      try{ [System.Media.SystemSounds]::Asterisk.Play() }catch{}
      foreach($i in $freshSnd){ $script:alertPinged += $i }
    }
  }

  # 只有「还没确认过」的异常才自动弹窗; 已确认的走右键「查看全部线路状态」
  $unackedAll = @($hot | ForEach-Object { (Get-AlertAckKey $_) } | Where-Object { $script:alertAck -notcontains $_ })
  $vis = $script:alertEnabled -and ($script:alertForceShow -or $unackedAll.Count -gt 0) -and (-not $script:alertHidden)
  if($vis){
    $sig = (@($data | ForEach-Object { ((Get-AlertAckKey $_) + ':' + $_.sev + ':' + $_.reason) }) -join '|') +
           ('|exp=' + [string]$script:alertExpanded + '|ack=' + ($script:alertAck -join ',') + '|prb=' + [string]$script:alertProbing)
    if($sig -ne $script:alertSig){
      $script:alertSig = $sig
      Build-AlertUI
    }
    if(-not $script:alertForm.Visible){ $script:alertForm.Show() }
    Sync-AlertPanel $owner
  }else{
    if($script:alertForm.Visible){ $script:alertForm.Hide() }
  }

  # 记录本轮快照, 供下次判「刚挂」
  $snap = @{}
  foreach($l in $data){ $snap[$l.id] = [int]$l.ok }
  Save-AlertState $snap $script:alertAck $rs.mute
}

# ================= 手动重测 =================
function Start-AlertProbe {
  if($script:alertProbing){ return }
  $py = Join-Path $base 'probe_models.py'
  if(-not (Test-Path $py)){ return }
  $script:alertProbing = $true
  $script:alertSig = ''
  $start = [DateTimeOffset]::Now
  try{
    Start-Process -FilePath 'python' -ArgumentList @($py) -WindowStyle Hidden | Out-Null
    try{ Write-Log 'alert: probe_models.py 已启动' }catch{}
  }catch{
    $script:alertProbing = $false
    return
  }
  Update-AlertPanel $script:alertOwner

  $ticks = 0
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = 4000
  $t.Add_Tick({
    $ticks++
    $done = $false
    $tk = Read-Utf8Json $TOKJSON
    if($tk -and $tk.updated_at){
      try{
        $u = [DateTimeOffset]::Parse([string]$tk.updated_at)
        if($u -gt $start.AddSeconds(-3)){ $done = $true }
      }catch{}
    }
    if($done -or $ticks -ge 45){
      $t.Stop(); $t.Dispose()
      $script:alertProbing = $false
      $script:alertSig = ''
      try{ Write-Log ('alert: probe ' + $(if($done){'done'}else{'timeout'}) + ' after ' + ($ticks*4) + 's') }catch{}
      if($script:alertOwner){ [void](Build-Rows) }
    }
  })
  $t.Start()
  $script:alertProbeTimer = $t
}

function Init-AlertPanel($owner){
  $script:alertOwner = $owner
  if(-not $script:alertForm){ New-AlertForm }
}
