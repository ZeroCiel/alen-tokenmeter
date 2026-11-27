param([switch]$Force,[switch]$Verify,[switch]$Quiet,[switch]$NoClose)
# 百智云「每日领积分 +100」自动点击（UIA，复用已登录的 Edge 窗口，不需要 key/密码）
# 注意：站点可能弹验证码。点了按钮不等于领成功，必须读到积分增加或"领取成功"文案才算数。
# v1.7.2: 站点规则——当日已领则页面不再显示领取按钮，所以"在控制台页且无按钮"即判已领；
#         余额读数兼容 "99.42" 与 "积分" 拆成两个元素的渲染。
# v1.7.3: 领取成功后自动关掉百智页（只关活动标签, 不关整个窗口; -NoClose 可禁用）。
#         复用已有百智标签时若不在 console 页, 会补开一个控制台标签; 标签不是 TabItem 时用窗口标题兜底。
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class BzWin{[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();}'

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$TOKDIR = if($env:TOKENS_DIR){ $env:TOKENS_DIR } else { 'D:\Backup\Documents\deepseek-harness\default-workspace\tokens' }
$STATUS = Join-Path $TOKDIR 'baizhi-daily-claim.json'
$CREDIT = Join-Path $TOKDIR 'baizhi-credits.json'
$LOG = Join-Path $base 'tokenmeter.log'
$URL = 'https://baizhi.cloud/console/apps'
$today = [DateTime]::Now.ToString('yyyy-MM-dd')
function WLog([string]$m){ try{ "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) [baizhi-daily] $m" | Out-File -FilePath $LOG -Append -Encoding UTF8 }catch{} }
function Say([string]$m){ if(-not $Quiet){ Write-Output $m } }
function Save-Status($ok,$msg,$remaining,$captcha){
  $o = @{ date=$today; ok=[bool]$ok; at=[DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); remaining=$remaining; need_captcha=[bool]$captcha; message=$msg; source='UIA自动点击' }
  [IO.File]::WriteAllText($STATUS, ($o | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
}
function Front($w){ try{ $h=[IntPtr]$w.Current.NativeWindowHandle; [void][BzWin]::ShowWindow($h,9); [void][BzWin]::SetForegroundWindow($h) }catch{} }
# 找百智页窗口: 先比窗口标题(等于活动标签标题), 再退一步找含"百智"标签页的浏览器窗口并切过去
function Find-ConsoleWindow($root){
  try{
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($w in $wins){ try{ if($w.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $w.Current.Name -like '*百智*'){ return $w } }catch{} }
    foreach($w in $wins){
      try{
        if($w.Current.ClassName -ne 'Chrome_WidgetWin_1'){ continue }
        $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        foreach($e in $all){
          try{
            if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and ([string]$e.Current.Name -like '*百智*')){
              try{
                $sel = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if(-not $sel.Current.IsSelected){ $sel.Select(); Start-Sleep -Milliseconds 800; WLog 'reuse: 切到已有的百智标签' }
              }catch{}
              return $w
            }
          }catch{}
        }
      }catch{}
    }
  }catch{}
  return $null
}
function AllEl($w){ return $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
function Find-Text($w,[string]$pat){
  foreach($e in (AllEl $w)){ try{ $n=[string]$e.Current.Name; if($n -match $pat){ return $e } }catch{} }
  return $null
}
function Find-Button($w,[string]$pat){
  foreach($e in (AllEl $w)){ try{ if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and [string]$e.Current.Name -match $pat){ return $e } }catch{} }
  return $null
}
# v1.7.1: 页面上的「每日领积分 +100」未必是 Button 控件(实测可能是 Hyperlink/Text),
# 所以按名字找, 优先可 Invoke 的 Button; 领取后该元素会整个消失, 由调用方据此判定已领
function Find-Claim($w){
  $best = $null
  foreach($e in (AllEl $w)){
    try{
      $n = [string]$e.Current.Name
      if($n -match '领积分|每日领积分|\+\s*100'){
        if(-not $e.Current.IsEnabled){ continue }
        if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button){ return $e }
        if(-not $best){ $best = $e }
      }
    }catch{}
  }
  return $best
}
function Test-LoginWall($w){
  $e = Find-Text $w '^\s*(登录|立即登录|登录\s*/\s*注册)\s*$'
  return ($null -ne $e)
}
# 地址栏 URL: 用来确认当前确实在 console/apps 页; 首页卡片也有"积分"字样, 不能当余额依据
function Get-PageUrl($w){
  try{
    foreach($e in (AllEl $w)){
      try{
        if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit){
          $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
          $v = [string]$vp.Current.Value
          if($v -match '^https?://'){ return $v }
        }
      }catch{}
    }
  }catch{}
  return ''
}
function Read-Credit($w){
  $els = @()
  foreach($e in (AllEl $w)){ $els += $e }
  # ① 整块就是一个文本: "99.42 积分"
  $fallback = $null
  foreach($e in $els){
    try{
      $n=[string]$e.Current.Name
      if($n -match '^\s*(\d{1,7}(?:\.\d{1,2})?)\s*积分\s*$'){
        $v = [decimal]$Matches[1]
        try{ $pt = $e.GetClickablePoint(); if($pt.Y -lt 200){ return $v } }catch{}
        if($null -eq $fallback){ $fallback = $v }
      }
    }catch{}
  }
  if($null -ne $fallback){ return $fallback }
  # ② 拆开渲染: "99.42" 与 "积分" 是两个元素 —— 在顶部栏(y<200)找"积分"标签,
  #    再取同一行、紧贴其左侧的纯数字元素。这样不会命中卡片里的"调用次数 231"
  $labels = @()
  foreach($e in $els){
    try{
      if(([string]$e.Current.Name).Trim() -eq '积分'){
        $r = $e.Current.BoundingRectangle
        if($r.Top -ge 0 -and $r.Top -lt 200){ $labels += ,@($r.Top,$r.Left) }
      }
    }catch{}
  }
  foreach($p in $labels){
    $best = $null; $bestD = 9999
    foreach($e in $els){
      try{
        $n = ([string]$e.Current.Name).Trim()
        if($n -notmatch '^\d{1,7}(?:\.\d{1,2})?$'){ continue }
        $r = $e.Current.BoundingRectangle
        if([math]::Abs($r.Top - $p[0]) -gt 16){ continue }
        $dx = $p[1] - $r.Right
        if($dx -lt -10 -or $dx -gt 140){ continue }
        if($dx -lt $bestD){ $bestD = $dx; $best = [decimal]$n }
      }catch{}
    }
    if($null -ne $best){ return $best }
  }
  return $null
}

# 关掉百智页: 自己 Start-Process 拉起的窗口直接关窗口; 复用用户窗口时只关当前选中的百智标签。
# 安全阀: Ctrl+W 前必须确认前台就是目标窗口, 否则会误关别的窗口/标签。
function Close-Console($w){
  try{
    # 只关标签, 不关整个窗口: Edge 已运行时 Start-Process 只是给现有窗口加标签,
    # 误判"自己开的窗口"会连带关掉用户全部标签(实际踩过一次)。
    $target = $null
    foreach($e in (AllEl $w)){
      try{
        if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and ([string]$e.Current.Name -like '*百智*')){
          $sel = $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
          if($sel.Current.IsSelected){ $target = $e; break }
        }
      }catch{}
    }
    if(-not $target){
      # Chromium 有时不把 TabItem 暴露给 UIA; 此时用窗口标题兜底(Edge 标题=活动标签标题)
      $tn = @()
      foreach($e in (AllEl $w)){ try{ if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem){ $tn += ([string]$e.Current.Name) } }catch{} }
      WLog ('close: target=null tabs=[' + ($tn -join ' | ') + '] winTitle=' + $w.Current.Name)
      if([string]$w.Current.Name -like '*百智*'){ WLog 'close: 按窗口标题判定活动标签' }
      else { WLog 'close: skip (当前没有选中的百智标签)'; return $false }
    }
    if($target){
      try{
        foreach($c in $target.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
          try{
            if($c.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and ([string]$c.Current.Name -match '关闭|Close')){
              $c.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); WLog 'close: tab button'; return $true
            }
          }catch{}
        }
      }catch{}
    }
    Front $w; Start-Sleep -Milliseconds 500
    $fg = [BzWin]::GetForegroundWindow()
    if($fg -ne [IntPtr]$w.Current.NativeWindowHandle){ WLog 'close: skip (前台不是浏览器, 不发 Ctrl+W)'; return $false }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.SendKeys]::SendWait('^w'); WLog 'close: ctrl+w'; return $true
  }catch{ WLog ('close failed: '+$_.Exception.Message); return $false }
}

# 当天已成功领过就跳过（除非 -Force / -Verify）
$prev = $null
if(Test-Path $CREDIT){ try{ $c=Get-Content $CREDIT -Raw -Encoding UTF8|ConvertFrom-Json; if($null -ne $c.remaining){$prev=[decimal]$c.remaining} }catch{} }
if(-not $Force -and -not $Verify -and (Test-Path $STATUS)){
  try{ $st=Get-Content $STATUS -Raw -Encoding UTF8|ConvertFrom-Json; if($st.date -eq $today -and $st.ok){ WLog ('skip: already claimed '+$today); Say 'already'; exit 0 } }catch{}
}

$win = $null
$root = [System.Windows.Automation.AutomationElement]::RootElement
$win = Find-ConsoleWindow $root
# 复用的百智标签不一定是控制台页(实测有 model-square/dashboard 等), 不是就补开一个控制台标签
if($win -and -not $Verify){
  $u0 = Get-PageUrl $win
  if($u0 -notlike '*baizhi.cloud/console*'){
    WLog ('reuse: 当前标签不是控制台页(url=' + $u0 + '), 新开 ' + $URL)
    try{ Start-Process $URL | Out-Null }catch{}
    Start-Sleep -Seconds 5
  }
}
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
if(-not $win -and -not $Verify){
  try{ Start-Process $URL | Out-Null }catch{}
  for($i=0;$i -lt 30 -and -not $win;$i++){
    Start-Sleep -Seconds 1
    $wins=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($w in $wins){ try{ if($w.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $w.Current.Name -like '*百智*'){ $win=$w; break } }catch{} }
  }
}
if(-not $win){ WLog 'fail: 找不到百智云浏览器窗口'; if(-not $Verify){Save-Status $false '找不到浏览器窗口' $null $false}; Say 'no-window'; exit 2 }

# ---- Verify 模式：只确认上次点击的结果，不重复点击 ----
if($Verify){
  $okTxt = Find-Text $win '成功领取|领取成功|已领取'
  $cap   = Find-Text $win '请选中验证|验证图片'
  for($i=0;$i -lt 15 -and -not $okTxt -and $cap;$i++){ Start-Sleep -Seconds 1; $okTxt=Find-Text $win '成功领取|领取成功|已领取' }
  $confirm = Find-Button $win '确定|知道了'
  if($confirm){ try{ $confirm.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }catch{} }
  $rem = Read-Credit $win
  if($null -ne $rem){
    $o=@{ remaining=$rem; checked_at=[DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); source='控件自动领取' }
    [IO.File]::WriteAllText($CREDIT,($o|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
  }
  $gained = ($null -ne $rem -and $null -ne $prev -and $rem -gt $prev)
  if($okTxt -or $gained){
    Save-Status $true ('领取成功' + $(if($rem){"，余额 $rem"}else{''})) $rem $false
    WLog ('verify ok: remaining='+$rem)
    if(-not $NoClose){ [void](Close-Console $win) }
    Say ('ok: remaining='+$rem); exit 0
  }
  if($cap){ Front $win; Save-Status $false '验证码待人工完成，已把浏览器切到前台' $rem $true; WLog 'verify: captcha pending'; Say 'captcha'; exit 5 }
  Save-Status $false '未能确认领取结果（请手动核对页面）' $rem $false
  WLog 'verify uncertain'; Say 'uncertain'; exit 6
}

# ---- 点击模式 ----
$btn = Find-Claim $win
if(-not $btn){
  # 刚切过来的标签/首次加载可能还没渲染完, 再等一会重查; 不重复开页面, 否则会多出一个百智标签
  for($i=0;$i -lt 12 -and -not $btn;$i++){ Start-Sleep -Seconds 1; $btn=Find-Claim $win }
}
if(-not $btn){
  # 页面无按钮有三种可能: ①今日已领(按钮消失) ②登录态失效 ③页面没加载出活动入口。
  # 站点规则(用户实测): 当日领取后按钮就消失, 所以"确认在控制台页 + 无按钮"即可判已领;
  # 余额增长只是辅助证据(拆开渲染时可能读不到)。
  $rem0 = Read-Credit $win
  if($null -eq $rem0){ Start-Sleep -Seconds 2; $rem0 = Read-Credit $win }
  $wall = Test-LoginWall $win
  $url0 = Get-PageUrl $win
  $onConsole = ($null -ne (Find-Text $win '^\s*应用服务\s*$')) -or ($null -ne (Find-Text $win '每日领积分|领积分')) -or ($url0 -like '*baizhi.cloud/console*')
  if($null -ne $rem0){
    $o0=@{ remaining=$rem0; checked_at=[DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); source='控件自动领取' }
    [IO.File]::WriteAllText($CREDIT,($o0|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
  }
  $grew = ($null -ne $rem0 -and $null -ne $prev -and [decimal]$rem0 -gt [decimal]$prev)
  if($wall){
    Front $win; WLog ('fail: 需要登录(loginWall=True, url=' + $url0 + ')'); Save-Status $false '需要登录百智云控制台' $rem0 $false; Say 'login-wall'; exit 3
  }
  if($onConsole -or $grew){
    $why = if($grew){ '余额由 ' + $prev + ' 增至 ' + $rem0 } else { '页面无领取按钮' }
    Save-Status $true ($why + '，按站点规则判定今日已领取') $rem0 $false
    WLog ('already-absent: ' + $why + ', remaining=' + $rem0 + ', url=' + $url0)
    # 已领状态: 手动/l领积分按钮触发时也算"领取完成", 关掉百智页
    if(-not $NoClose){ [void](Close-Console $win) }
    Say 'already-absent'; exit 0
  }
  WLog ('fail: 无领取按钮且不在控制台页(remaining=' + $rem0 + ', prev=' + $prev + ', loginWall=' + $wall + ', url=' + $url0 + ')')
  Save-Status $false '未找到领积分按钮（页面未加载/活动未开放）' $rem0 $false
  Say 'no-button'; exit 3
}
try{
  $nameBefore=[string]$btn.Current.Name
  if(-not $btn.Current.IsEnabled){
    Save-Status $true '按钮已置灰，判定今日已领' $null $false
    WLog 'already-disabled'
    if(-not $NoClose){ [void](Close-Console $win) }
    Say 'already-disabled'; exit 0
  }
  $clicked = $false
  try{ $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $clicked = $true }catch{}
  if(-not $clicked){ try{ $btn.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern).DoDefaultAction(); $clicked = $true }catch{} }
  if(-not $clicked){ throw '该控件不支持 Invoke/默认动作，需要在浏览器里手动点' }
  Start-Sleep -Seconds 3
  WLog ('clicked: ' + $nameBefore + ' (' + $btn.Current.ControlType.ProgrammaticName + ')')
}catch{
  WLog ('click failed: '+$_.Exception.Message); Save-Status $false ('点击失败: '+$_.Exception.Message) $null $false; Say 'click-failed'; exit 4
}

# 点完可能弹验证码，等它自己跑一会；跑不过就交给用户人工处理
$okTxt = Find-Text $win '成功领取|领取成功|已领取'
$cap = Find-Text $win '请选中验证|验证图片'
for($i=0;$i -lt 15 -and -not $okTxt -and $cap;$i++){ Start-Sleep -Seconds 1; $okTxt=Find-Text $win '成功领取|领取成功|已领取'; $cap=Find-Text $win '请选中验证|验证图片' }
$confirm = Find-Button $win '确定|知道了'
if($confirm){ try{ $confirm.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }catch{} }
$rem = Read-Credit $win
if($null -ne $rem){
  $o=@{ remaining=$rem; checked_at=[DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); source='控件自动领取' }
  [IO.File]::WriteAllText($CREDIT,($o|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
}
$gained = ($null -ne $rem -and $null -ne $prev -and $rem -gt $prev)
if($okTxt -or $gained){
  Save-Status $true ('领取成功' + $(if($rem){"，余额 $rem"}else{''})) $rem $false
  WLog ('ok: remaining='+$rem)
  if(-not $NoClose){ [void](Close-Console $win) }
  Say ('ok: remaining='+$rem); exit 0
}
if($cap){ Front $win; Save-Status $false '验证码待人工完成，已把浏览器切到前台' $rem $true; WLog 'captcha pending'; Say 'captcha'; exit 5 }
Save-Status $false '点击后未能确认领取结果' $rem $false
WLog 'uncertain after click'; Say 'uncertain'; exit 6
