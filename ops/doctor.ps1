$ErrorActionPreference = "Continue"

Write-Host "== Project O Stream -- Doctor =="
Write-Host ""

# ── Tools ─────────────────────────────────────────────────────────────────────
Write-Host "== Tools =="
foreach ($tool in @("ffmpeg", "ffprobe", "python", "tailscale")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  OK  $tool`t$($cmd.Source)"
    } else {
        Write-Host " MISS $tool"
    }
}

# mobile tools are optional on a server-only machine
foreach ($tool in @("flutter", "dart")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  OK  $tool`t$($cmd.Source)"
    } else {
        Write-Host "  --  $tool`t(optional — mobile build only)"
    }
}

# ── Tailscale ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== Tailscale =="
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    $ip = tailscale ip -4 2>&1
    Write-Host "  IP  $ip"
    tailscale status --peers 2>&1 | Select-Object -First 10
} else {
    Write-Host "  MISS  Tailscale not installed."
}

# ── Python packages ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== Python Packages =="
foreach ($pkg in @("textual", "rich", "pyvirtualcam")) {
    $ver = python -c "import importlib.metadata; print(importlib.metadata.version('$pkg'))" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK  ${pkg}==$ver"
    } else {
        Write-Host " MISS $pkg"
    }
}

# ── Ports ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== Ports =="
Write-Host "TCP:"
Get-NetTCPConnection -LocalPort 7070,7073,7076 -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Host "UDP:"
Get-NetUDPEndpoint -LocalPort 7070,7071,7072,7073,7075,15000 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize

# ── Receiver process ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== Receiver =="
$pyProcs = Get-WmiObject Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "receiver\.py" }
if ($pyProcs) {
    foreach ($p in $pyProcs) {
        Write-Host "  RUNNING  PID $($p.ProcessId)  $($p.CommandLine)"
    }
} else {
    $exeProcs = Get-Process server -ErrorAction SilentlyContinue
    if ($exeProcs) {
        foreach ($p in $exeProcs) {
            Write-Host "  RUNNING  server.exe  PID $($p.Id)"
        }
    } else {
        Write-Host "  --  receiver not running"
    }
}

# last 10 lines of server.log
$logPath = Join-Path (Split-Path -Parent $PSScriptRoot) "server\server.log"
if (Test-Path $logPath) {
    Write-Host ""
    Write-Host "server.log (last 10 lines):"
    Get-Content $logPath -Tail 10 | ForEach-Object { Write-Host "  $_" }
}
