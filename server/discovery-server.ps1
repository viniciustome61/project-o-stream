param(
    [int]$DiscoveryPort = 7071,
    [int]$SrtPort = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$ClientDiscoveryPort = 7072
)

$ErrorActionPreference = "Continue"

$tailscaleIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try {
        $out = & tailscale ip -4 2>$null
        if ($LASTEXITCODE -eq 0) { $tailscaleIp = ($out | Select-Object -First 1) }
    } catch { }
}

$lanIp = $null
try {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
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
    $adv = if ($tailscaleIp -and $ProbeSourceIp -match '^100\.') { $tailscaleIp }
           elseif ($lanIp) { $lanIp }
           else { $tailscaleIp }
    if (-not $adv) { $adv = $ProbeSourceIp }
    @{
        service = "project-o-stream"
        version = 1
        host = $adv
        hostname = $hostname
        srtPort = $SrtPort
        discoveryPort = $DiscoveryPort
        clientDiscoveryPort = $ClientDiscoveryPort
        obsUdpPort = $ObsUdpPort
        transport = "srt"
        capabilities = @{ duplicateReceiverDetection = $true; tailscalePreferred = [bool]$tailscaleIp; obsUdpForward = $true; protocolVersion = "3.0" }
    } | ConvertTo-Json -Compress
}

function Get-TailscalePeers {
    if (-not $tailscaleIp) { return @() }
    try {
        $s = & tailscale status --json | ConvertFrom-Json
        if ($s.Peer) {
            $p = $s.Peer.PSObject.Properties.Value
            return $p | Where-Object { $_.Online -and $_.TailscaleIPs } | ForEach-Object { $_.TailscaleIPs | Where-Object { $_ -match '^100\.' } }
        }
    } catch { }
    return @()
}

Write-Host "Discovery active."
$lastPulse = (Get-Date).AddSeconds(-10)

while ($true) {
    try {
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $udp.Receive([ref]$ep)
        $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($msg -eq "PROJECTO_STREAM_DISCOVER") {
            $probe = if ($ep.Address) { $ep.Address.ToString() } else { "0.0.0.0" }
            $data = [System.Text.Encoding]::UTF8.GetBytes((New-DiscoveryPayload -ProbeSourceIp $probe))
            [void]$udp.Send($data, $data.Length, $ep)
        }
    } catch [System.Net.Sockets.SocketException] { } catch {
        Write-Host "UDP Error: $($_.Exception.Message)"
    }

    if ($conflictUdp) {
        try {
            $cep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $cbytes = $conflictUdp.Receive([ref]$cep)
            $offer = [System.Text.Encoding]::UTF8.GetString($cbytes) | ConvertFrom-Json
            if ($offer.service -eq "project-o-stream" -and $tailscaleIp -and $offer.host -ne $tailscaleIp) {
                Write-Host "Conflict detected."
            }
        } catch { }
    }

    if (((Get-Date) - $lastPulse).TotalMilliseconds -ge 1000) {
        if ($pulseUdp) {
            $pdata = [System.Text.Encoding]::UTF8.GetBytes((New-DiscoveryPayload -ProbeSourceIp "100.0.0.1"))
            foreach ($pip in (Get-TailscalePeers)) {
                if ($pip) {
                    try { [void]$pulseUdp.Send($pdata, $pdata.Length, $pip, $ClientDiscoveryPort) } catch { }
                }
            }
        }
        $lastPulse = Get-Date
    }
    Start-Sleep -Milliseconds 10
}
