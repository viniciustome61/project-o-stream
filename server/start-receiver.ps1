param(
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$LatencyMs = 80,
    [switch]$NoDiscovery
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot -and $PSCommandPath) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if (-not $scriptRoot -and $MyInvocation.MyCommand.Path) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptRoot) {
    $candidate = Join-Path (Get-Location) "server"
    if (Test-Path (Join-Path $candidate "discovery-server.ps1")) {
        $scriptRoot = $candidate
    } else {
        $scriptRoot = Get-Location
    }
}

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    $fallback = "C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe"
    if (Test-Path $fallback) {
        $ffmpeg = Get-Item $fallback
    } else {
        throw "ffmpeg not found in PATH or at $fallback"
    }
}
$ffmpegPath = if ($ffmpeg.Source) { $ffmpeg.Source } else { $ffmpeg.FullName }

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    $tailscaleIp = (& tailscale ip -4 2>$null | Select-Object -First 1)
}

$latencyUs = $LatencyMs * 1000
$inputUrl = "srt://0.0.0.0:$($SrtPort)?mode=listener&transtype=live&latency=$latencyUs&rcvlatency=$latencyUs&peerlatency=$latencyUs&tlpktdrop=1&pkt_size=1316"

$target = "udp://127.0.0.1:$($ObsUdpPort)?pkt_size=1316"
$obsInput = "udp://127.0.0.1:$ObsUdpPort"

$discoveryJob = $null
if (-not $NoDiscovery) {
    $discoveryScript = Join-Path $scriptRoot "discovery-server.ps1"
    $discoveryJob = Start-Job -FilePath $discoveryScript -ArgumentList 7071, $SrtPort, $ObsUdpPort, 7072
}

Write-Host ""
Write-Host "========================================"
Write-Host " Stream Receiver"
Write-Host " SRT listen : srt://0.0.0.0:$SrtPort"
if ($tailscaleIp) {
    Write-Host " Advertise  : srt://$($tailscaleIp):$SrtPort"
}
Write-Host " Output     : $target"
Write-Host " OBS Input  : $obsInput"
Write-Host " Latency    : $LatencyMs ms"
if (-not $NoDiscovery) {
    Write-Host " Discovery  : UDP 7071 probes, UDP 7072 offers"
}
Write-Host "========================================"
Write-Host ""

$ffmpegArgs = @(
    '-hide_banner', '-loglevel', 'info',
    '-fflags', 'nobuffer', '-flags', 'low_delay',
    '-probesize', '32k', '-analyzeduration', '0',
    '-i', $inputUrl,
    '-map', '0', '-c', 'copy', '-f', 'mpegts', $target
)

$proc = Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgs -PassThru -NoNewWindow
try {
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 400

        if ($discoveryJob -and $discoveryJob.State -ne 'Running') {
            $out = Receive-Job $discoveryJob -ErrorAction SilentlyContinue
            Write-Host ""
            if ($out) { $out | Where-Object { $_ } | ForEach-Object { Write-Host $_ } }
            Write-Host "[Receiver] Discovery server stopped — halting receiver."
            if (-not $proc.HasExited) { $proc.Kill() }
            break
        }
    }
    if (-not $proc.HasExited) { $proc.WaitForExit(3000) | Out-Null }
} finally {
    if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null }
    if ($discoveryJob) {
        $out = Receive-Job $discoveryJob -ErrorAction SilentlyContinue
        if ($out) { $out | Where-Object { $_ } | ForEach-Object { Write-Host $_ } }
        Stop-Job $discoveryJob -ErrorAction SilentlyContinue
        Remove-Job $discoveryJob -Force -ErrorAction SilentlyContinue
    }
}
