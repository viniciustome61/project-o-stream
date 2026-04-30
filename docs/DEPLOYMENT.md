# Deployment

## Workstation Requirements

- Tailscale installed, logged in, and connected.
- ffmpeg available in PATH or at `C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe`.
- OBS available under `vendor/obs-portable/`.

## Mobile Requirements

- Android or iOS device logged into the same Tailscale tailnet.
- Native app installed from the Flutter project root.

## Receiver

```powershell
.\ops\start-receiver.ps1
```

Receiver listens on:

```text
srt://0.0.0.0:7070
```

Mobile discovery is automatic:

```text
mobile -> PC UDP 7071 probes
PC -> mobile UDP 7072 offers
```

After discovery, the app streams to the receiver SRT port.

## OBS

Launch:

```powershell
.\ops\launch-obs.ps1
```

Add a Media Source with input:

```text
udp://127.0.0.1:15000
```

Set buffering/cache as low as OBS allows.
