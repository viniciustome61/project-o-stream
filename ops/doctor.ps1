$ErrorActionPreference = "Continue"

Write-Host "== Project O Stream 3.0 Doctor =="
Write-Host "Mobile branch: main"
Write-Host "Desktop branch: desktop/tauri-svelte"
Write-Host ""

Write-Host "== Tools =="
foreach ($tool in @("ffmpeg", "ffprobe", "tailscale", "flutter", "dart")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "$tool`t$($cmd.Source)"
    } else {
        Write-Host "$tool`tNOT FOUND"
    }
}

Write-Host ""
Write-Host "== Tailscale =="
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    tailscale ip -4
    tailscale status --self
} else {
    Write-Host "Tailscale not installed."
}

Write-Host ""
Write-Host "== Ports =="
Write-Host "TCP:"
Get-NetTCPConnection -LocalPort 7070,7071,15000 -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess
Write-Host "UDP:"
Get-NetUDPEndpoint -LocalPort 7070,7071,7072,15000 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess

Write-Host ""
Write-Host "== Receiver Health =="
$receiver = Join-Path (Split-Path -Parent $PSScriptRoot) "server\start-receiver.ps1"
if (Test-Path $receiver) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $receiver -Health
}
