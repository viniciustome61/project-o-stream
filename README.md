# Stream

Production native mobile camera streaming stack for OBS.

## Overview

Stream sends a hardware-encoded phone camera feed to a PC over a private Tailscale network, then exposes it locally to OBS.

```text
Flutter mobile app
  -> native camera capture
  -> native H.264/H.265 hardware encoder
  -> SRT over Tailscale
  -> PC receiver
  -> udp://127.0.0.1:15000
  -> OBS Media Source
```

Tailscale provides authenticated private connectivity. SRT carries the media stream.

## Repository Layout

```text
mobile/              Flutter app and native sender code
server/              PC SRT receiver
ops/                 Operator scripts
docs/                Architecture, protocol, and deployment notes
vendor/obs-portable/ Local OBS runtime
```

## Requirements

- Tailscale connected on the PC and mobile device.
- ffmpeg available in `PATH` or at `C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe`.
- OBS runtime under `vendor/obs-portable/`.
- Flutter SDK for mobile app development.
- Android Studio for Android builds.
- macOS/Xcode for iOS builds and signing.

## Quick Start

Check the workstation:

```powershell
.\ops\doctor.ps1
```

Start the PC receiver:

```powershell
.\ops\start-receiver.ps1
```

The receiver listens on:

```text
srt://0.0.0.0:7070
```

Discovery is automatic. The PC receiver replies to mobile probes on UDP `7071`
and sends receiver offers to online Tailscale peers on UDP `7072`. The mobile
app uses that to resolve the SRT target without typing an IP address.

The resolved media path is:

```text
srt://<pc-tailscale-ip>:7070
```

OBS should use a Media Source with:

```text
udp://127.0.0.1:15000
```

Launch bundled OBS:

```powershell
.\ops\launch-obs.ps1
```

## Receiver Options

```powershell
.\server\start-receiver.ps1 -SrtPort 7070 -ObsUdpPort 15000 -LatencyMs 80
```

Defaults:

```text
SRT listen port : 7070
Discovery probes: 7071/udp
Discovery offers: 7072/udp
OBS UDP output  : 15000
SRT latency     : 80 ms
```

## Mobile App

The Flutter app source is under `mobile/`.

```powershell
cd mobile
flutter pub get
flutter run
```

Android SRT sending is implemented through StreamPack. iOS has the native preview/channel layer and requires libsrt XCFramework linkage on macOS for transport completion.

## Documentation

- `docs/ARCHITECTURE.md`
- `docs/PROTOCOL.md`
- `docs/DEPLOYMENT.md`
