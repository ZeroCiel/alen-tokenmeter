# ALEN TokenMeter - stop all running instances
$ErrorActionPreference = 'Continue'
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*TokenMeter.ps1*' }
if (-not $procs) { Write-Host 'TokenMeter is not running.'; return }
foreach ($p in $procs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host "stopped PID $($p.ProcessId)" }
    catch { Write-Host "failed PID $($p.ProcessId): $($_.Exception.Message)" }
}
