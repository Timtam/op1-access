#requires -Version 5
<#
verify-attach.ps1 - task #2 verification harness.

Watches the UE4SS log in the game's Win64 folder for the OP1Access load
marker. Run this in one terminal, then launch the game (Steam -> Play, or
double-click the Shipping exe). Once the marker appears we know:
  1. UE4SS injected into the Shipping build (4.18) successfully.
  2. The OP1Access mod was discovered and its Lua loaded.
  3. RegisterHook is callable - we will see "RegisterHook ClientRestart: true".

Press Ctrl+C to stop watching.
#>

$ErrorActionPreference = 'Stop'

$gameW64 = 'C:\Program Files (x86)\Steam\steamapps\common\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64'
$logPath = Join-Path $gameW64 'UE4SS.log'

if (-not (Test-Path $gameW64)) {
    Write-Host "[verify] Game folder not found at: $gameW64" -ForegroundColor Red
    exit 1
}

if (Test-Path $logPath) {
    Remove-Item $logPath -Force
    Write-Host "[verify] Cleared previous UE4SS.log" -ForegroundColor DarkGray
}

Write-Host "[verify] Watching $logPath" -ForegroundColor Cyan
Write-Host "[verify] Now launch Octopath Traveler from Steam." -ForegroundColor Cyan
Write-Host "[verify] Looking for [OP1Access] markers... (Ctrl+C to stop)" -ForegroundColor Cyan
Write-Host ""

while (-not (Test-Path $logPath)) {
    Start-Sleep -Milliseconds 500
}

Write-Host "[verify] Log appeared - UE4SS injected successfully." -ForegroundColor Green
Write-Host ""

Get-Content -Path $logPath -Wait -Tail 0 | ForEach-Object {
    if ($_ -match '\[OP1Access\]') {
        Write-Host $_ -ForegroundColor Green
    } elseif ($_ -match '(?i)error|failed|exception') {
        Write-Host $_ -ForegroundColor Red
    } else {
        Write-Host $_ -ForegroundColor DarkGray
    }
}
