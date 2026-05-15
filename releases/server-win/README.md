# Server

PC receiver for the native mobile streaming path.

## Branch Scope

- `main` remains the mobile app branch.
- `desktop/tauri-svelte` is desktop-only for the Tauri + Svelte controller.

These receiver scripts are shared workstation support, but desktop shell changes should stay on `desktop/tauri-svelte`.

## 3.0 Features

- SRT listener for mobile camera input.
- MPEG-TS UDP forwarding to OBS.
- UDP discovery replies on 7071 and unsolicited Tailscale offers on 7072.
- Duplicate receiver detection across the Tailnet.
- Structured health output:

```powershell
.\server\start-receiver.ps1 -Health
```

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
