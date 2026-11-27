param([switch]$Force,[switch]$Verify,[switch]$Quiet)
# 百智云「每日领积分 +100」自动点击（UIA，复用已登录的 Edge 窗口，不需要 key/密码）
# 注意：站点可能弹验证码。点了按钮不等于领成功，必须读到积分增加或"领取成功"文案才算数。
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class BzWin{[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);}'

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
function AllEl($w){ return $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
function Find-Text($w,[string]$pat){
  foreach($e in (AllEl $w)){ try{ $n=[string]$e.Current.Name; if($n -match $pat){ return $e } }catch{} }
  return $null
}
function Find-Button($w,[string]$pat){
  foreach($e in (AllEl $w)){ try{ if($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and [string]$e.Current.Name -match $pat){ return $e } }catch{} }
  return $null
}
function Read-Credit($w){
  foreach($e in (AllEl $w)){
    try{
      $n=[string]$e.Current.Name
      if($n -match '(\d+)\s*积分|积分\s*(\d+)'){
        $v = if($Matches[1]){ [int]$Matches[1] }else{ [int]$Matches[2] }
        return $v
      }
    }catch{}
  }
  return $null
}

# 当天已成功领过就跳过（除非 -Force / -Verify）
$prev = $null
if(Test-Path $CREDIT){ try{ $c=Get-Content $CREDIT -Raw -Encoding UTF8|ConvertFrom-Json; if($null -ne $c.remaining){$prev=[int]$c.remaining} }catch{} }
if(-not $Force -and -not $Verify -and (Test-Path $STATUS)){
  try{ $st=Get-Content $STATUS -Raw -Encoding UTF8|ConvertFrom-Json; if($st.date -eq $today -and $st.ok){ WLog ('skip: already claimed '+$today); Say 'already'; exit 0 } }catch{}
}

$win = $null
$root = [System.Windows.Automation.AutomationElement]::RootElement
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
foreach($w in $wins){ try{ if($w.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $w.Current.Name -like '*百智*'){ $win=$w; break } }catch{} }
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
    WLog ('verify ok: remaining='+$rem); Say ('ok: remaining='+$rem); exit 0
  }
  if($cap){ Front $win; Save-Status $false '验证码待人工完成，已把浏览器切到前台' $rem $true; WLog 'verify: captcha pending'; Say 'captcha'; exit 5 }
  Save-Status $false '未能确认领取结果（请手动核对页面）' $rem $false
  WLog 'verify uncertain'; Say 'uncertain'; exit 6
}

# ---- 点击模式 ----
$btn = Find-Button $win '领积分'
if(-not $btn){
  try{ Start-Process $URL | Out-Null }catch{}
  for($i=0;$i -lt 20 -and -not $btn;$i++){ Start-Sleep -Seconds 1; $btn=Find-Button $win '领积分' }
}
if(-not $btn){ WLog 'fail: 页面上没找到「每日领积分」按钮'; Save-Status $false '未找到领积分按钮（检查登录态）' $null $false; Say 'no-button'; exit 3 }
try{
  $nameBefore=[string]$btn.Current.Name
  if(-not $btn.Current.IsEnabled){ Save-Status $true '按钮已置灰，判定今日已领' $null $false; Say 'already-disabled'; exit 0 }
  $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Seconds 3
  WLog ('clicked: '+$nameBefore)
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
  WLog ('ok: remaining='+$rem); Say ('ok: remaining='+$rem); exit 0
}
if($cap){ Front $win; Save-Status $false '验证码待人工完成，已把浏览器切到前台' $rem $true; WLog 'captcha pending'; Say 'captcha'; exit 5 }
Save-Status $false '点击后未能确认领取结果' $rem $false
WLog 'uncertain after click'; Say 'uncertain'; exit 6
