param(
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$LatencyMs = 80,
    [int]$Cameras = 1,
    [switch]$Health,
    [switch]$NoDiscovery,
    [switch]$DirectToObs,
    [switch]$Ndi
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

if (-not $DirectToObs) {
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
}

$ndiAvailable = $false
if ($Ndi -and -not $DirectToObs) {
    $muxersOutput = & $ffmpegPath -muxers 2>&1 | Out-String
    $ndiAvailable = $muxersOutput -match 'libndi_newtek'
    if ($ndiAvailable) {
        Write-Host "[Receiver] NDI: enabled"
    } else {
        Write-Host "[Receiver] NDI: disabled (need NDI-enabled ffmpeg)"
        Write-Host "           Get: github.com/valnoxy/ndi-ffmpeg-build"
    }
}

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try {
        $tailscaleOutput = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) {
            $tailscaleIp = ($tailscaleOutput | Select-Object -First 1)
        }
    } catch { $tailscaleIp = $null }
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

# Telemetry firewall rule (port 7075).
$fwTeleRule = "Project-O-Stream Telemetry 7075"
if (-not (Get-NetFirewallRule -DisplayName $fwTeleRule -ErrorAction SilentlyContinue)) {
    try {
        New-NetFirewallRule -DisplayName $fwTeleRule -Direction Inbound `
            -Protocol UDP -LocalPort 7075 -Action Allow -ErrorAction Stop | Out-Null
        Write-Host "[Receiver] Firewall: opened port 7075 UDP (telemetry)."
    } catch {
        Write-Host "[Receiver] Firewall: could not open 7075: $($_.Exception.Message)"
    }
}

$latencyUs = $LatencyMs * 1000
$slotsJson  = ($slots | Select-Object index, srtPort, obsUdpPort | ConvertTo-Json -Compress)

if ($Health) {
    [pscustomobject]@{
        service          = "project-o-stream-receiver"
        version          = "4.0"
        tailscaleIp      = $tailscaleIp
        cameras          = $Cameras
        slots            = $slots
        latencyMs        = $LatencyMs
        ffmpeg           = if ($DirectToObs) { $null } else { $ffmpegPath }
        discoveryEnabled = -not $NoDiscovery
        directToObs      = [bool]$DirectToObs
        ndi              = [bool]($Ndi -and $ndiAvailable)
    } | ConvertTo-Json -Depth 4
    return
}

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
Write-Host " Stream Receiver  ($camWord)"
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
        Write-Host " OBS Input${label}: udp://127.0.0.1:$($slot.obsUdpPort)"
        if ($Ndi -and $ndiAvailable) {
            Write-Host " NDI${label}       : Project-O-Camera-$($slot.index + 1)  (NDI Virtual Input webcam)"
        }
    }
}
if (-not $NoDiscovery) {
    Write-Host ""
    Write-Host " Discovery : UDP 7071 probes, UDP 7072 offers"
}
Write-Host "========================================"
Write-Host ""
if ($Ndi -and $ndiAvailable) {
    Write-Host "[Receiver] NDI active. Use NDI Virtual Input or OBS NDI plugin to receive NDI feeds."
    Write-Host "           Tools: ndi.video/tools  |  obsproject.com/forum/resources/obs-ndi.528/"
    Write-Host ""
}

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
    if ($Ndi -and $ndiAvailable) {
        $ndiName = "Project-O-Camera-$($slot.index + 1)"
        $ffmpegArgs += @('-map', '0', '-vf', 'format=uyvy422', '-c:a', 'pcm_s16le', '-f', 'libndi_newtek', $ndiName)
    }
    $ndiNote = if ($Ndi -and $ndiAvailable) { " + NDI: Project-O-Camera-$($slot.index + 1)" } else { "" }
    Write-Host "[Receiver] Cam $($slot.index + 1) waiting on SRT $($slot.srtPort) -> UDP $($slot.obsUdpPort)$ndiNote"
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
