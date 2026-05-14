param(
    [int]$DiscoveryPort = 7071,
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$ClientDiscoveryPort = 7072
)

$ErrorActionPreference = "Continue"

$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
$tailscaleIp = $null
if ($tailscale) {
    try {
        $tailscaleOutput = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) {
            $tailscaleIp = ($tailscaleOutput | Select-Object -First 1)
        }
    } catch {
        $tailscaleIp = $null
    }
}

# Server's own LAN IP — what LAN phones should connect to for SRT.
# Excludes loopback, APIPA, and Tailscale (100.x) addresses.
$lanIp = $null
try {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.|100\.)' -and
            $_.PrefixOrigin -in @('Dhcp', 'Manual')
        } | Sort-Object PrefixLength -Descending | Select-Object -First 1).IPAddress
} catch { }

$udp = [System.Net.Sockets.UdpClient]::new($DiscoveryPort)
$udp.EnableBroadcast = $true
$udp.Client.ReceiveTimeout = 300
$pulseUdp = [System.Net.Sockets.UdpClient]::new()
$endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
$hostname = [System.Net.Dns]::GetHostName()

# Listen on the offer port so we detect other running receivers on the Tailnet
$conflictUdp = $null
$conflictEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
try {
    $conflictUdp = [System.Net.Sockets.UdpClient]::new()
    $conflictUdp.ExclusiveAddressUse = $false
    $conflictUdp.Client.SetSocketOption(
        [System.Net.Sockets.SocketOptionLevel]::Socket,
        [System.Net.Sockets.SocketOptionName]::ReuseAddress,
        $true
    )
    $conflictUdp.Client.Bind(
        [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $ClientDiscoveryPort)
    )
    $conflictUdp.Client.ReceiveTimeout = 50
} catch {
    $conflictUdp = $null
}

function New-DiscoveryPayload {
    param([string]$ProbeSourceIp)

    # Phone on Tailscale (100.x) -> advertise Tailscale IP so SRT goes over Tailnet.
    # Phone on LAN -> advertise LAN IP so SRT goes direct without Tailscale on the phone.
    $advertiseHost = if ($tailscaleIp -and $ProbeSourceIp -match '^100\.') {
        $tailscaleIp
    } elseif ($lanIp) {
        $lanIp
    } elseif ($tailscaleIp) {
        $tailscaleIp
    } else {
        $ProbeSourceIp
    }

    @{
        service = "project-o-stream"
        version = 1
        host = $advertiseHost
        hostname = $hostname
        srtPort = $SrtPort
        discoveryPort = $DiscoveryPort
        clientDiscoveryPort = $ClientDiscoveryPort
        obsUdpPort = $ObsUdpPort
        transport = "srt"
        capabilities = @{
            duplicateReceiverDetection = $true
            tailscalePreferred = [bool]$tailscaleIp
            obsUdpForward = $true
            protocolVersion = "3.0"
        }
    } | ConvertTo-Json -Compress
}

function Get-TailscalePeerIps {
    if (-not $tailscale) {
        return @()
    }

    try {
        $status = & tailscale status --json 2>$null | ConvertFrom-Json
    } catch {
        return @()
    }

    $peers = @()
    if ($status.Peer) {
        $peers = $status.Peer.PSObject.Properties.Value
    }

    $peers |
        Where-Object { $_.Online -eq $true -and $_.TailscaleIPs } |
        ForEach-Object { $_.TailscaleIPs | Where-Object { $_ -match '^100\.' -and $_ -ne $tailscaleIp } } |
        Select-Object -Unique
}

function Send-OffersToPeers {
    # Peers are on the Tailnet so they should always connect via Tailscale IP.
    $payload = [System.Text.Encoding]::UTF8.GetBytes((New-DiscoveryPayload -ProbeSourceIp "100.0.0.1"))
    foreach ($peerIp in (Get-TailscalePeerIps)) {
        try {
            [void]$pulseUdp.Send($payload, $payload.Length, $peerIp, $ClientDiscoveryPort)
        } catch {
            continue
        }
    }
}

Write-Host "Discovery listening on UDP 0.0.0.0:$DiscoveryPort"
Write-Host "Discovery offers sent to Tailscale peers on UDP $ClientDiscoveryPort"
if ($lanIp)       { Write-Host "Advertising LAN IP      $lanIp (for phones on WiFi)" }
if ($tailscaleIp) { Write-Host "Advertising Tailscale IP $tailscaleIp (for Tailscale peers)" }
if ($conflictUdp) { Write-Host "Conflict detection active on UDP $ClientDiscoveryPort (warn only)" }

$shouldStop = $false
try {
    $lastPulse = (Get-Date).AddSeconds(-10)
    $lastConflictWarning = (Get-Date).AddSeconds(-60)
    while (-not $shouldStop) {
        try {
            $bytes = $udp.Receive([ref]$endpoint)
            $message = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($message -eq "PROJECTO_STREAM_DISCOVER") {
                $payload = New-DiscoveryPayload -ProbeSourceIp $endpoint.Address.ToString()
                $reply = [System.Text.Encoding]::UTF8.GetBytes($payload)
                [void]$udp.Send($reply, $reply.Length, $endpoint)
            }
        } catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) {
                Write-Host "[Discovery] probe socket error ($($_.Exception.SocketErrorCode)); continuing."
            }
        } catch {
            Write-Host "[Discovery] probe socket unexpected error: $($_.Exception.Message)"
        }

        if ($conflictUdp) {
            try {
                $cfBytes = $conflictUdp.Receive([ref]$conflictEndpoint)
                $cfMsg = [System.Text.Encoding]::UTF8.GetString($cfBytes)
                try {
                    $offer = $cfMsg | ConvertFrom-Json
                    if ($offer -and $offer.service -eq "project-o-stream" `
                            -and $tailscaleIp `
                            -and $offer.host `
                            -and $offer.host -ne $tailscaleIp) {
                        if (((Get-Date) - $lastConflictWarning).TotalSeconds -ge 30) {
                            $peerName = if ($offer.hostname) { $offer.hostname } else { $conflictEndpoint.Address.ToString() }
                            Write-Host ""
                            Write-Host "=== RECEIVER CONFLICT WARNING ==="
                            Write-Host "  Another Project O receiver advertised on this Tailnet:"
                            Write-Host "  Peer     : $peerName ($($conflictEndpoint.Address.ToString()))"
                            Write-Host "  Action   : Keeping this receiver alive; stop the other one if mobile selects the wrong host."
                            Write-Host "================================="
                            $lastConflictWarning = Get-Date
                        }
                    }
                } catch { }
            } catch [System.Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) {
                    Write-Host "[Discovery] conflict socket error ($($_.Exception.SocketErrorCode)); continuing."
                }
            } catch {
                Write-Host "[Discovery] conflict socket unexpected error: $($_.Exception.Message)"
            }
        }

        if (-not $shouldStop -and ((Get-Date) - $lastPulse).TotalMilliseconds -ge 1000) {
            Send-OffersToPeers
            $lastPulse = Get-Date
        }
    }
} finally {
    $udp.Close()
    $pulseUdp.Close()
    if ($conflictUdp) { $conflictUdp.Close() }
}
