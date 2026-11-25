# ALEN TokenMeter - start hidden
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'TokenMeter.ps1'
if (-not (Test-Path $script)) { throw "TokenMeter.ps1 not found: $script" }
Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $script
) -WindowStyle Hidden
Write-Host 'TokenMeter started (hidden).'
