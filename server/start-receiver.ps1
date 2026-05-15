param(
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$LatencyMs = 80,
    [switch]$Health,
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

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try {
        $tailscaleOutput = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) {
            $tailscaleIp = ($tailscaleOutput | Select-Object -First 1)
        }
    } catch {
        $tailscaleIp = $null
    }
}

# Ensure Windows Firewall allows inbound traffic on the SRT port.
$fwRuleName = "Project-O-Stream SRT $SrtPort"
$fwExists = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if (-not $fwExists) {
    try {
        New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound `
            -Protocol UDP -LocalPort $SrtPort -Action Allow -ErrorAction Stop | Out-Null
        New-NetFirewallRule -DisplayName "$fwRuleName TCP" -Direction Inbound `
            -Protocol TCP -LocalPort $SrtPort -Action Allow -ErrorAction Stop | Out-Null
        Write-Host "[Receiver] Firewall: opened port $SrtPort UDP+TCP for SRT."
    } catch {
        Write-Host "[Receiver] Firewall: could not add rule (run as Administrator to open port $SrtPort): $($_.Exception.Message)"
    }
}

$latencyVal = $LatencyMs

if ($Health) {
    [pscustomobject]@{
        service          = "project-o-stream-receiver"
        version          = "3.0"
        tailscaleIp      = $tailscaleIp
        srtPort          = $SrtPort
        obsUdpPort       = $ObsUdpPort
        latencyMs        = $LatencyMs
        ffmpeg           = if ($DirectToObs) { $null } else { $ffmpegPath }
        discoveryEnabled = -not $NoDiscovery
        directToObs      = [bool]$DirectToObs
        obsInput         = if ($DirectToObs) {
            "srt://0.0.0.0:$($SrtPort)?mode=listener&latency=$($latencyVal)&pkt_size=1316"
        } else {
            "udp://127.0.0.1:$ObsUdpPort"
        }
    } | ConvertTo-Json -Depth 4
    return
}

$discoveryJob = $null
$discoveryScript = Join-Path $scriptRoot "discovery-server.ps1"
$lastDiscoveryRestart = (Get-Date).AddSeconds(-10)
$discoveryDisabledForRun = $false
$discoveryPort = 7071
$clientDiscoveryPort = 7072

function Test-UdpPortBindable {
    param([int]$Port)

    $client = $null
    try {
        $client = [System.Net.Sockets.UdpClient]::new()
        $client.ExclusiveAddressUse = $false
        $client.Client.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress,
            $true
        )
        $client.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $Port))
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Close()
        }
    }
}

function Get-UdpPortOwners {
    param([int]$Port)

    $ownerPids = @()
    try {
        $ownerPids = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique
    } catch {
        $ownerPids = @()
    }

    foreach ($ownerPid in $ownerPids) {
        if (-not $ownerPid) { continue }
        $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Pid  = [int]$ownerPid
            Name = if ($process) { $process.ProcessName } else { "Unknown" }
            Path = if ($process -and $process.Path) { $process.Path } else { "" }
        }
    }
}

function Ensure-DiscoveryPortAvailable {
    param([int]$Port)

    if (Test-UdpPortBindable -Port $Port) {
        return $true
    }

    Write-Host "[Receiver] UDP $Port is blocked. Discovery cannot start while this port is unavailable."
    $owners = @(Get-UdpPortOwners -Port $Port)

    if ($owners.Count -eq 0) {
        Write-Host "[Receiver] Windows did not report a process owner for UDP $Port."
        Write-Host "[Receiver] This can be a reserved/excluded Windows port. Check with:"
        Write-Host "           netsh int ipv4 show excludedportrange protocol=udp"
        return $false
    }

    foreach ($owner in $owners) {
        $detail = if ($owner.Path) { " ($($owner.Path))" } else { "" }
        Write-Host "[Receiver] UDP $Port is owned by $($owner.Name) PID $($owner.Pid)$detail"

        if ($owner.Pid -le 4 -or $owner.Pid -eq $PID) {
            Write-Host "[Receiver] Not safe to kill PID $($owner.Pid). Close that service manually."
            continue
        }

        $answer = Read-Host "[Receiver] Kill $($owner.Name) PID $($owner.Pid) so discovery can use UDP $Port? [y/N]"
        if ($answer -match '^(y|yes|s|sim)$') {
            try {
                Stop-Process -Id $owner.Pid -Force -ErrorAction Stop
                Write-Host "[Receiver] Killed $($owner.Name) PID $($owner.Pid)."
            } catch {
                Write-Host "[Receiver] Could not kill PID $($owner.Pid): $($_.Exception.Message)"
            }
        } else {
            Write-Host "[Receiver] Keeping $($owner.Name) PID $($owner.Pid). Discovery disabled for this run."
            return $false
        }
    }

    Start-Sleep -Milliseconds 500
    if (Test-UdpPortBindable -Port $Port) {
        return $true
    }

    Write-Host "[Receiver] UDP $Port is still blocked after cleanup. Discovery disabled for this run."
    return $false
}

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
    if ($script:discoveryDisabledForRun) { return }
    if (-not (Test-Path -LiteralPath $discoveryScript)) {
        Write-Host "[Receiver] Discovery script not found: $discoveryScript"
        return
    }

    if (-not (Ensure-DiscoveryPortAvailable -Port $script:discoveryPort)) {
        $script:discoveryDisabledForRun = $true
        $script:lastDiscoveryRestart = Get-Date
        return
    }

    try {
        $script:discoveryJob = Start-Job -FilePath $discoveryScript -ArgumentList $script:discoveryPort, $SrtPort, $ObsUdpPort, $script:clientDiscoveryPort
        $script:lastDiscoveryRestart = Get-Date
    } catch {
        Write-Host "[Receiver] Discovery server failed to start: $($_.Exception.Message)"
        $script:lastDiscoveryRestart = Get-Date
    }
}

function Ensure-DiscoveryRunning {
    if ($NoDiscovery) { return }
    if ($script:discoveryDisabledForRun) { return }
    if ($script:discoveryJob -and $script:discoveryJob.State -eq 'Running') {
        Write-DiscoveryJobOutput $script:discoveryJob
        return
    }

    if ($script:discoveryJob) {
        Write-DiscoveryJobOutput $script:discoveryJob
        Write-Host "[Receiver] Discovery server stopped ($($script:discoveryJob.State)); restarting discovery only."
        Remove-Job $script:discoveryJob -Force -ErrorAction SilentlyContinue
        $script:discoveryJob = $null
    }

    if (((Get-Date) - $script:lastDiscoveryRestart).TotalSeconds -lt 2) {
        return
    }

    Start-DiscoveryJob
}

Start-DiscoveryJob

Write-Host ""
Write-Host "========================================"
Write-Host " Stream Receiver"
Write-Host " SRT listen : srt://0.0.0.0:$SrtPort"
if ($tailscaleIp) {
    Write-Host " Advertise  : srt://$($tailscaleIp):$SrtPort"
}
Write-Host " Latency    : $LatencyMs ms"
if ($DirectToObs) {
    Write-Host ""
    Write-Host " >> OBS Media Source URL (paste as-is):"
    Write-Host "    srt://0.0.0.0:$($SrtPort)?mode=listener&latency=$($latencyVal)&pkt_size=1316"
    Write-Host ""
    Write-Host " >> OBS Media Source settings:"
    Write-Host "    [x] Restart playback when source becomes inactive"
} else {
    Write-Host " Output     : udp://127.0.0.1:$($ObsUdpPort)?pkt_size=1316"
    Write-Host " OBS Input  : udp://127.0.0.1:$ObsUdpPort"
}
if ($script:discoveryDisabledForRun) {
    Write-Host " Discovery  : disabled (UDP $discoveryPort blocked)"
} elseif (-not $NoDiscovery) {
    Write-Host " Discovery  : UDP $discoveryPort probes, UDP $clientDiscoveryPort offers"
}
Write-Host "========================================"
Write-Host ""

if ($DirectToObs) {
    Write-Host "[Receiver] Direct-to-OBS mode. Phone connects directly to OBS via SRT."
    Write-Host "[Receiver] OBS owns the SRT listener here, so this console will not show connection frames."
    Write-Host "[Receiver] Watch the OBS Media Source output/status for the live connection."
    Write-Host "[Receiver] For console connection logs, run start-receiver.ps1 without -DirectToObs and use OBS input udp://127.0.0.1:$ObsUdpPort."
    if ($script:discoveryDisabledForRun) {
        Write-Host "[Receiver] Discovery disabled for this run. Restart after freeing UDP $discoveryPort."
    } else {
        Write-Host "[Receiver] Discovery running. Press Ctrl+C to stop."
    }
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

# --- Legacy relay mode (ffmpeg → UDP → OBS) ---
$inputUrl = "srt://0.0.0.0:$($SrtPort)?mode=listener&transtype=live&latency=$latencyVal&rcvlatency=$latencyVal&peerlatency=$latencyVal&tlpktdrop=1&pkt_size=1316"
$target = "udp://127.0.0.1:$($ObsUdpPort)?pkt_size=1316"

$ffmpegArgs = @(
    '-hide_banner', '-loglevel', 'info',
    '-fflags', 'nobuffer', '-flags', 'low_delay',
    '-probesize', '32k', '-analyzeduration', '0',
    '-i', $inputUrl,
    '-map', '0', '-c', 'copy', '-f', 'mpegts', $target
)

$proc = $null
try {
    while ($true) {
        Ensure-DiscoveryRunning

        Write-Host "[Receiver] Waiting for SRT caller on UDP $SrtPort..."
        $proc = Start-Process -FilePath $ffmpegPath -ArgumentList $ffmpegArgs -PassThru -NoNewWindow

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 400
            Ensure-DiscoveryRunning
        }

        $exitCode = $proc.ExitCode
        $proc = $null
        Write-Host "[Receiver] ffmpeg exited with code $exitCode. Restarting listener in 1s..."
        Start-Sleep -Seconds 1
    }
    if ($proc -and -not $proc.HasExited) { $proc.WaitForExit(3000) | Out-Null }
} finally {
    if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null }
    if ($discoveryJob) {
        Write-DiscoveryJobOutput $discoveryJob
        Stop-Job $discoveryJob -ErrorAction SilentlyContinue
        Remove-Job $discoveryJob -Force -ErrorAction SilentlyContinue
    }
}
