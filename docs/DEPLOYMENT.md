# Deployment

## Workstation Requirements

- Tailscale installed, logged in, and connected.
- ffmpeg available in PATH or at `C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe`.
- OBS available under `vendor/obs-portable/`.

## Mobile Requirements

- Android or iOS device logged into the same Tailscale tailnet.
- Native app installed from the Flutter project root.

## iOS Update Delivery

For project updates, the default iOS delivery path is automated:

```powershell
python ship.py
```

`ship.py` pushes changes, triggers the GitHub Actions iOS build, downloads the newest unsigned IPA artifact, and saves it in `releases/`. The local Sideloadly MCP server is configured to use `releases/` as the source of truth for the latest IPA.

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
