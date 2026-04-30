# Server

PC receiver for the native mobile streaming path.

## Start

```powershell
.\server\start-receiver.ps1
```

The receiver listens on:

```text
srt://0.0.0.0:7070
```

The mobile app discovers this receiver automatically:

```text
UDP 7071 probe replies
UDP 7072 Tailscale peer offers
```

The receiver forwards to OBS at:

```text
udp://127.0.0.1:15000
```

## Parameters

```powershell
.\server\start-receiver.ps1 -SrtPort 7070 -ObsUdpPort 15000 -LatencyMs 80
```
