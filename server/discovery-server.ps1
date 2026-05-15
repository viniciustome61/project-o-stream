param(
    [int]$DiscoveryPort = 7071,
    [string]$SlotsJson = '[{"index":0,"srtPort":7070,"obsUdpPort":15000}]',
    [int]$ClientDiscoveryPort = 7072
)

$ErrorActionPreference = "Continue"

$slots            = $SlotsJson | ConvertFrom-Json
$slotAssignments  = @{}   # key: phoneIp, value: @{slotIndex; assignedAt}
$slotTtlSeconds   = 120

$tailscale   = Get-Command tailscale -ErrorAction SilentlyContinue
$tailscaleIp = $null
if ($tailscale) {
    try {
        $out = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) { $tailscaleIp = ($out | Select-Object -First 1) }
    } catch { $tailscaleIp = $null }
}

$script:lanIps = @()
try {
    $script:lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.|100\.)'
        } | Sort-Object InterfaceMetric,PrefixLength | Select-Object -ExpandProperty IPAddress -Unique)
} catch { }
$lanIp = if ($script:lanIps.Count -gt 0) { [string]$script:lanIps[0] } else { $null }

$udp = [System.Net.Sockets.UdpClient]::new($DiscoveryPort)
$udp.EnableBroadcast = $true
$udp.Client.ReceiveTimeout = 300
$pulseUdp  = [System.Net.Sockets.UdpClient]::new()
$endpoint  = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
$hostname  = [System.Net.Dns]::GetHostName()

$conflictUdp      = $null
$conflictEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
try {
    $conflictUdp = [System.Net.Sockets.UdpClient]::new()
    $conflictUdp.ExclusiveAddressUse = $false
    $conflictUdp.Client.SetSocketOption(
        [System.Net.Sockets.SocketOptionLevel]::Socket,
        [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $conflictUdp.Client.Bind(
        [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $ClientDiscoveryPort))
    $conflictUdp.Client.ReceiveTimeout = 50
} catch { $conflictUdp = $null }

# Returns the slot assigned to $PhoneIp, assigning a free one if needed.
function Get-SlotForPhone {
    param([string]$PhoneIp)
    $now = Get-Date

    # Expire stale assignments
    $toRemove = @($script:slotAssignments.Keys | Where-Object {
        ($now - $script:slotAssignments[$_].assignedAt).TotalSeconds -gt $script:slotTtlSeconds
    })
    foreach ($k in $toRemove) { $script:slotAssignments.Remove($k) }

    # Renew existing assignment for this phone
    if ($script:slotAssignments.ContainsKey($PhoneIp)) {
        $script:slotAssignments[$PhoneIp] = @{
            slotIndex  = $script:slotAssignments[$PhoneIp].slotIndex
            assignedAt = $now
        }
        return $script:slots[$script:slotAssignments[$PhoneIp].slotIndex]
    }

    # Find first free slot
    $usedIndices = @($script:slotAssignments.Values | ForEach-Object { $_.slotIndex })
    $freeIndex   = 0..($script:slots.Count - 1) |
                   Where-Object { $usedIndices -notcontains $_ } |
                   Select-Object -First 1

    # All slots taken — evict least-recently-used
    if ($null -eq $freeIndex) {
        $lru = ($script:slotAssignments.GetEnumerator() |
                Sort-Object { $_.Value.assignedAt })[0]
        $freeIndex = $lru.Value.slotIndex
        $script:slotAssignments.Remove($lru.Key)
    }

    $script:slotAssignments[$PhoneIp] = @{ slotIndex = [int]$freeIndex; assignedAt = $now }
    return $script:slots[[int]$freeIndex]
}

function Get-TransportForHost {
    param([string]$HostIp)
    if (Test-TailscaleIp -Ip $HostIp) {
        return "tailscale"
    }
    if (Test-LanIp -Ip $HostIp) {
        return "lan"
    }
    return "srt"
}

function Test-TailscaleIp {
    param([string]$Ip)
    return $Ip -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
}

function Test-LanIp {
    param([string]$Ip)
    return $Ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
}

function Test-SameLanLayer {
    param([string]$Left, [string]$Right)
    if (-not (Test-LanIp -Ip $Left) -or -not (Test-LanIp -Ip $Right)) { return $false }
    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    if ($leftParts.Count -ne 4 -or $rightParts.Count -ne 4) { return $false }
    return ($leftParts[0] -eq $rightParts[0] -and
            $leftParts[1] -eq $rightParts[1] -and
            $leftParts[2] -eq $rightParts[2])
}

function Get-BestLanIpForClient {
    param([string]$ClientIp)
    foreach ($candidate in $script:lanIps) {
        if (Test-SameLanLayer -Left $ClientIp -Right $candidate) { return $candidate }
    }
    if ($script:lanIps.Count -gt 0) { return [string]$script:lanIps[0] }
    return $null
}

function New-DiscoveryPayload {
    param([string]$ProbeSourceIp)
    $slot = Get-SlotForPhone -PhoneIp $ProbeSourceIp
    $lanAdvertiseHost = Get-BestLanIpForClient -ClientIp $ProbeSourceIp

    # Tailscale peers get Tailscale IP; LAN phones get LAN IP.
    $advertiseHost = if ($tailscaleIp -and (Test-TailscaleIp -Ip $ProbeSourceIp)) {
        $tailscaleIp
    } elseif ((Test-LanIp -Ip $ProbeSourceIp) -and $lanAdvertiseHost) {
        $lanAdvertiseHost
    } elseif ($lanAdvertiseHost) {
        $lanAdvertiseHost
    } elseif ($tailscaleIp) {
        $tailscaleIp
    } else {
        $ProbeSourceIp
    }

    @{
        service             = "project-o-stream"
        version             = 1
        host                = $advertiseHost
        lanIp               = $lanAdvertiseHost  # route-aware LAN/hotspot address for this client
        lanIps              = $script:lanIps     # all local network layers, including hotspot/tether adapters
        tailscaleIp         = $tailscaleIp  # always included
        hostname            = $hostname
        srtPort             = [int]$slot.srtPort
        obsUdpPort          = [int]$slot.obsUdpPort
        slotIndex           = [int]$slot.index
        totalSlots          = $script:slots.Count
        discoveryPort       = $DiscoveryPort
        clientDiscoveryPort = $ClientDiscoveryPort
        transport           = (Get-TransportForHost -HostIp $advertiseHost)
    } | ConvertTo-Json -Compress
}

function Get-TailscalePeerIps {
    if (-not $tailscale) { return @() }
    try { $status = & tailscale status --json 2>$null | ConvertFrom-Json } catch { return @() }
    $peers = @()
    if ($status.Peer) { $peers = $status.Peer.PSObject.Properties.Value }
    $peers |
        Where-Object { $_.Online -eq $true -and $_.TailscaleIPs } |
        ForEach-Object { $_.TailscaleIPs | Where-Object { $_ -match '^100\.' -and $_ -ne $tailscaleIp } } |
        Select-Object -Unique
}

function Send-OffersToPeers {
    # Each Tailscale peer gets a slot-specific offer so every phone gets its own slot.
    foreach ($peerIp in (Get-TailscalePeerIps)) {
        $payload = [System.Text.Encoding]::UTF8.GetBytes((New-DiscoveryPayload -ProbeSourceIp $peerIp))
        try { [void]$pulseUdp.Send($payload, $payload.Length, $peerIp, $ClientDiscoveryPort) }
        catch { continue }
    }
}

$slotCount = $slots.Count
Write-Host "Discovery listening on UDP 0.0.0.0:$DiscoveryPort ($slotCount slot$(if ($slotCount -gt 1) {'s'}))"
Write-Host "Slot assignment: TTL ${slotTtlSeconds}s, LRU eviction when full"
if ($lanIp)       { Write-Host "LAN IPs      : $($script:lanIps -join ', ')  (local/hotspot phones + LAN-probe ACK)" }
if ($tailscaleIp) { Write-Host "Tailscale IP : $tailscaleIp  (Tailscale peers)" }
if ($conflictUdp) { Write-Host "Conflict detection active on UDP $ClientDiscoveryPort" }

$shouldStop = $false
try {
    $lastPulse           = (Get-Date).AddSeconds(-10)
    $lastConflictWarning = (Get-Date).AddSeconds(-60)
    while (-not $shouldStop) {
        try {
            $bytes   = $udp.Receive([ref]$endpoint)
            $message = [System.Text.Encoding]::UTF8.GetString($bytes)

            if ($message -eq "PROJECTO_STREAM_DISCOVER") {
                # Full discovery — assign slot and reply with complete offer.
                $reply = [System.Text.Encoding]::UTF8.GetBytes(
                    (New-DiscoveryPayload -ProbeSourceIp $endpoint.Address.ToString()))
                [void]$udp.Send($reply, $reply.Length, $endpoint)

            } elseif ($message -eq "PROJECTO_STREAM_LAN_PROBE") {
                # Lightweight LAN reachability check — ACK without touching slot state.
                $ack = [System.Text.Encoding]::UTF8.GetBytes("PROJECTO_STREAM_LAN_ACK")
                [void]$udp.Send($ack, $ack.Length, $endpoint)
            }
        } catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) {
                Write-Host "[Discovery] probe socket error ($($_.Exception.SocketErrorCode)); continuing."
            }
        } catch {
            Write-Host "[Discovery] unexpected error: $($_.Exception.Message)"
        }

        if ($conflictUdp) {
            try {
                $cfBytes = $conflictUdp.Receive([ref]$conflictEndpoint)
                $cfMsg   = [System.Text.Encoding]::UTF8.GetString($cfBytes)
                try {
                    $offer = $cfMsg | ConvertFrom-Json
                    if ($offer -and $offer.service -eq "project-o-stream" `
                            -and $tailscaleIp -and $offer.host `
                            -and $offer.host -ne $tailscaleIp `
                            -and (@($script:lanIps) -notcontains [string]$offer.host)) {
                        if (((Get-Date) - $lastConflictWarning).TotalSeconds -ge 30) {
                            $peerName = if ($offer.hostname) { $offer.hostname } else { $conflictEndpoint.Address.ToString() }
                            Write-Host ""
                            Write-Host "=== RECEIVER CONFLICT WARNING ==="
                            Write-Host "  Another Project O receiver: $peerName ($($conflictEndpoint.Address.ToString()))"
                            Write-Host "  Stop it if mobile connects to the wrong host."
                            Write-Host "================================="
                            $lastConflictWarning = Get-Date
                        }
                    }
                } catch { }
            } catch [System.Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) {
                    Write-Host "[Discovery] conflict socket error ($($_.Exception.SocketErrorCode)); continuing."
                }
            } catch { }
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
