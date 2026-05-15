param(
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$LatencyMs = 80,
    [int]$Cameras = 1,
    [switch]$NoDiscovery,
    [switch]$DirectToObs
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot -and $PSCommandPath) {
    $scriptRoot = Split-Path -Parent $PSCommandPath
}
if (-not $scriptRoot -and $MyInvocation.MyCommand.Path) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptRoot) { $scriptRoot = Get-Location }

if (-not $DirectToObs) {
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        $fallback = "C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe"
        if (Test-Path $fallback) {
            $ffmpeg = Get-Item $fallback
        } else {
            Write-Host "ERROR: ffmpeg not found in PATH or at $fallback"
            Write-Host "Install ffmpeg and add it to PATH, or place ffmpeg.exe in this folder."
            exit 1
        }
    }
    $ffmpegPath = if ($ffmpeg.Source) { $ffmpeg.Source } else { $ffmpeg.FullName }
}

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    $tailscaleIp = (& tailscale ip -4 2>$null | Select-Object -First 1)
}

# Build slot table: each camera gets its own SRT port and OBS UDP port (step of 3).
$slots = @()
for ($i = 0; $i -lt $Cameras; $i++) {
    $slots += [pscustomobject]@{
        index      = $i
        srtPort    = $SrtPort + $i * 3
        obsUdpPort = $ObsUdpPort + $i * 3
    }
}

# Ensure Windows Firewall allows inbound traffic on every SRT port.
foreach ($slot in $slots) {
    $fwRuleName = "Project-O-Stream SRT $($slot.srtPort)"
    if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
        try {
            New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound `
                -Protocol UDP -LocalPort $slot.srtPort -Action Allow -ErrorAction Stop | Out-Null
            New-NetFirewallRule -DisplayName "$fwRuleName TCP" -Direction Inbound `
                -Protocol TCP -LocalPort $slot.srtPort -Action Allow -ErrorAction Stop | Out-Null
            Write-Host "[Receiver] Firewall: opened port $($slot.srtPort) UDP+TCP."
        } catch {
            Write-Host "[Receiver] Firewall: could not open $($slot.srtPort): $($_.Exception.Message)"
        }
    }
}

$latencyUs = $LatencyMs * 1000
$slotsJson  = ($slots | Select-Object index, srtPort, obsUdpPort | ConvertTo-Json -Compress)

$discoveryJob         = $null
$discoveryScript      = Join-Path $scriptRoot "discovery-server.ps1"
$lastDiscoveryRestart = (Get-Date).AddSeconds(-10)

function Write-DiscoveryJobOutput {
    param($Job)
    if (-not $Job) { return }
    $messages = Receive-Job $Job -ErrorAction SilentlyContinue 2>&1
    if ($messages) {
        $messages | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
    }
}

function Start-DiscoveryJob {
    if ($NoDiscovery) { return }
    if (-not (Test-Path -LiteralPath $discoveryScript)) {
        Write-Host "[Receiver] Discovery script not found: $discoveryScript"
        return
    }
    try {
        $script:discoveryJob = Start-Job -FilePath $discoveryScript `
            -ArgumentList 7071, $slotsJson, 7072
        $script:lastDiscoveryRestart = Get-Date
    } catch {
        Write-Host "[Receiver] Discovery server failed to start: $($_.Exception.Message)"
        $script:lastDiscoveryRestart = Get-Date
    }
}

function Ensure-DiscoveryRunning {
    if ($NoDiscovery) { return }
    if ($script:discoveryJob -and $script:discoveryJob.State -eq 'Running') {
        Write-DiscoveryJobOutput $script:discoveryJob
        return
    }
    if ($script:discoveryJob) {
        Write-DiscoveryJobOutput $script:discoveryJob
        Write-Host "[Receiver] Discovery stopped ($($script:discoveryJob.State)); restarting."
        Remove-Job $script:discoveryJob -Force -ErrorAction SilentlyContinue
        $script:discoveryJob = $null
    }
    if (((Get-Date) - $script:lastDiscoveryRestart).TotalSeconds -lt 2) { return }
    Start-DiscoveryJob
}

Start-DiscoveryJob

$camWord = if ($Cameras -gt 1) { "$Cameras cameras" } else { "1 camera" }
Write-Host ""
Write-Host "========================================"
Write-Host " Project O Stream - Receiver  ($camWord)"
Write-Host " Latency   : $LatencyMs ms"
if ($tailscaleIp) { Write-Host " Tailscale : $tailscaleIp" }
foreach ($slot in $slots) {
    $label = if ($Cameras -gt 1) { " [Cam $($slot.index + 1)]" } else { "" }
    Write-Host ""
    Write-Host " SRT$label      : srt://0.0.0.0:$($slot.srtPort)"
    if ($DirectToObs) {
        Write-Host " OBS URL$label  : srt://0.0.0.0:$($slot.srtPort)?mode=listener&latency=$($latencyUs)&pkt_size=1316"
        Write-Host "                  [x] Restart playback when source becomes inactive"
    } else {
        Write-Host " OBS Input$label: udp://127.0.0.1:$($slot.obsUdpPort)"
    }
}
if (-not $NoDiscovery) {
    Write-Host ""
    Write-Host " Discovery : UDP 7071 probes, UDP 7072 offers"
}
Write-Host "========================================"
Write-Host ""

if ($DirectToObs) {
    Write-Host "[Receiver] Direct-to-OBS mode. Phones connect directly to OBS via SRT."
    Write-Host "[Receiver] Discovery running. Press Ctrl+C to stop."
    try {
        while ($true) {
            Start-Sleep -Milliseconds 500
            Ensure-DiscoveryRunning
        }
    } finally {
        if ($discoveryJob) {
            Write-DiscoveryJobOutput $discoveryJob
            Stop-Job $discoveryJob -ErrorAction SilentlyContinue
            Remove-Job $discoveryJob -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

# --- Relay mode: one ffmpeg process per camera slot ---
function Start-SlotRelay {
    param([int]$SlotIndex)
    $slot = $slots[$SlotIndex]
    $inputUrl = "srt://0.0.0.0:$($slot.srtPort)?mode=listener&transtype=live&latency=$latencyUs&rcvlatency=$latencyUs&peerlatency=$latencyUs&tlpktdrop=1&pkt_size=1316"
    $target   = "udp://127.0.0.1:$($slot.obsUdpPort)?pkt_size=1316"
    $ffmpegArgs = @(
        '-hide_banner', '-loglevel', 'info',
        '-fflags', 'nobuffer', '-flags', 'low_delay',
        '-probesize', '32k', '-analyzeduration', '0',
        '-i', $inputUrl,
        '-map', '0', '-c', 'copy', '-f', 'mpegts', $target
    )
    Write-Host "[Receiver] Cam $($slot.index + 1) waiting on SRT $($slot.srtPort) -> UDP $($slot.obsUdpPort)"
    return Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgs -PassThru -NoNewWindow
}

$procs = [object[]]::new($slots.Count)
try {
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $procs[$i] = Start-SlotRelay -SlotIndex $i
    }
    while ($true) {
        Ensure-DiscoveryRunning
        for ($i = 0; $i -lt $procs.Count; $i++) {
            if ($procs[$i] -and $procs[$i].HasExited) {
                $code = $procs[$i].ExitCode
                Write-Host "[Receiver] Cam $($i + 1) exited ($code); restarting in 1s..."
                Start-Sleep -Seconds 1
                $procs[$i] = Start-SlotRelay -SlotIndex $i
            }
        }
        Start-Sleep -Milliseconds 400
    }
} finally {
    foreach ($proc in $procs) {
        if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null }
    }
    if ($discoveryJob) {
        Write-DiscoveryJobOutput $discoveryJob
        Stop-Job $discoveryJob -ErrorAction SilentlyContinue
        Remove-Job $discoveryJob -Force -ErrorAction SilentlyContinue
    }
}
