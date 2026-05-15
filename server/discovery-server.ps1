param(
    [int]$DiscoveryPort = 7071,
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$ClientDiscoveryPort = 7072
)

$ErrorActionPreference = "Continue"

Write-Host "[Discovery] Initializing..."

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try {
        $out = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) { $script:tailscaleIp = ($out | Select-Object -First 1) }
    } catch { }
}

$lanIp = $null
try {
    $script:lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|100\.)' -and $_.PrefixOrigin -in @('Dhcp', 'Manual') } |
        Sort-Object PrefixLength -Descending | Select-Object -First 1).IPAddress
} catch { }

$udp = [System.Net.Sockets.UdpClient]::new($DiscoveryPort)
$udp.EnableBroadcast = $true
$udp.Client.ReceiveTimeout = 300
$pulseUdp = [System.Net.Sockets.UdpClient]::new()
$hostname = [System.Net.Dns]::GetHostName()

$conflictUdp = $null
try {
    $conflictUdp = [System.Net.Sockets.UdpClient]::new()
    $conflictUdp.ExclusiveAddressUse = $false
    $conflictUdp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $conflictUdp.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $ClientDiscoveryPort))
    $conflictUdp.Client.ReceiveTimeout = 50
} catch { }

function New-DiscoveryPayload {
    param([string]$ProbeSourceIp)
    try {
        $adv = if ($script:tailscaleIp -and $ProbeSourceIp -and $ProbeSourceIp -match '^100\.') { $script:tailscaleIp }
               elseif ($script:lanIp) { $script:lanIp }
               elseif ($script:tailscaleIp) { $script:tailscaleIp }
               else { $ProbeSourceIp }
        if (-not $adv) { $adv = "0.0.0.0" }
        
        $payload = @{
            service = "project-o-stream"
            version = 1
            host = $adv
            hostname = $hostname
            srtPort = $SrtPort
            discoveryPort = $DiscoveryPort
            clientDiscoveryPort = $ClientDiscoveryPort
            obsUdpPort = $ObsUdpPort
            transport = "srt"
            capabilities = @{ duplicateReceiverDetection = $true; tailscalePreferred = [bool]$script:tailscaleIp; obsUdpForward = $true; protocolVersion = "3.0" }
        }
        return ($payload | ConvertTo-Json -Compress)
    } catch {
        Write-Host "[Discovery] Error in New-DiscoveryPayload: $($_.Exception.Message)"
        return "{}"
    }
}

function Get-TailscalePeers {
    if (-not $script:tailscaleIp) { return @() }
    try {
        $statusStr = & tailscale status --json 2>$null
        if (-not $statusStr) { return @() }
        $s = $statusStr | ConvertFrom-Json
        if ($s -and $s.Peer) {
            $peersObj = $s.Peer
            # In PowerShell, accessing properties of a dynamic object from JSON can be tricky
            return $peersObj.PSObject.Properties | 
                Where-Object { $_.Value -and $_.Value.Online -and $_.Value.TailscaleIPs } | 
                ForEach-Object { $_.Value.TailscaleIPs | Where-Object { $_ -match '^100\.' } }
        }
    } catch { 
        Write-Host "[Discovery] Error in Get-TailscalePeers: $($_.Exception.Message)"
    }
    return @()
}

Write-Host "[Discovery] Listening on UDP $DiscoveryPort"
$lastPulse = (Get-Date).AddSeconds(-10)

while ($true) {
    try {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $null
        try {
            $bytes = $udp.Receive([ref]$ep)
        } catch [System.Net.Sockets.SocketException] {
            # Timeout is expected
        }

        if ($bytes) {
            $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($msg -eq "PROJECTO_STREAM_DISCOVER") {
                $probe = if ($ep -and $ep.Address) { $ep.Address.ToString() } else { "0.0.0.0" }
                $json = New-DiscoveryPayload -ProbeSourceIp $probe
                $data = [System.Text.Encoding]::UTF8.GetBytes($json)
                [void]$udp.Send($data, $data.Length, $ep)
            }
        }
    } catch {
        Write-Host "[Discovery] Main Loop Error: $($_.Exception.Message) at $($_.ScriptStackTrace)"
    }

    if ($conflictUdp) {
        try {
            $cep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $cbytes = $null
            try { $cbytes = $conflictUdp.Receive([ref]$cep) } catch { }
            if ($cbytes) {
                $offerJson = [System.Text.Encoding]::UTF8.GetString($cbytes)
                $offer = $offerJson | ConvertFrom-Json
                if ($offer -and $offer.service -eq "project-o-stream" -and $script:tailscaleIp -and $offer.host -ne $script:tailscaleIp) {
                    Write-Host "[Discovery] Conflict detected with $($offer.hostname)"
                }
            }
        } catch { }
    }

    if (((Get-Date) - $lastPulse).TotalMilliseconds -ge 2000) {
        if ($pulseUdp) {
            $jsonPulse = New-DiscoveryPayload -ProbeSourceIp "100.0.0.1"
            $pdata = [System.Text.Encoding]::UTF8.GetBytes($jsonPulse)
            $peers = Get-TailscalePeers
            foreach ($pip in $peers) {
                if ($pip) {
                    try { [void]$pulseUdp.Send($pdata, $pdata.Length, $pip, $ClientDiscoveryPort) } catch { }
                }
            }
        }
        $lastPulse = Get-Date
    }
    Start-Sleep -Milliseconds 50
}
