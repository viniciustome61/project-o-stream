# Project O Stream

> **Send your phone camera to OBS in real-time — hardware-encoded, over a private Tailscale network, with zero IP configuration.**

Project O Stream is a production-grade native mobile camera ingest stack for OBS Studio. It captures video and audio directly from an Android or iOS device using the hardware encoder, transmits it over SRT on your private Tailscale network, and presents it to OBS as a local UDP media source — all without punching holes in firewalls or typing a single IP address.

---

## How It Works

```
┌────────────────────────────────────────────────────────────────┐
│  Mobile Device (Android / iOS)                                 │
│                                                                │
│  Camera sensor                                                 │
│    └─► Hardware H.264 / H.265 encoder                          │
│           └─► SRT sender  ──────────────────────────────────┐  │
└─────────────────────────────────────────────────────────────│──┘
                                                              │
                    Tailscale private network                 │
                    (encrypted WireGuard tunnel)              │
                                                              │
┌─────────────────────────────────────────────────────────────│──┐
│  PC Workstation                                             │  │
│                                                             ▼  │
│  ffmpeg SRT receiver  (srt://0.0.0.0:7070)                     │
│    └─► MPEG-TS remux                                           │
│           └─► udp://127.0.0.1:15000                            │
│                  └─► OBS Media Source                          │
└────────────────────────────────────────────────────────────────┘
```

The receiver script (`start-receiver.ps1`) starts ffmpeg in SRT listener mode and simultaneously launches a discovery daemon. The mobile app needs no manual configuration — it finds the receiver automatically and begins streaming with one tap.

---

## Zero-Input Discovery

The system uses a two-channel UDP discovery mechanism so the mobile app never needs a typed IP address.

**Probe path** (mobile → PC): on startup the app sends `PROJECTO_STREAM_DISCOVER` datagrams to the broadcast address and any cached subnet on **UDP 7071**. The PC discovery daemon replies with a JSON offer containing its Tailscale IP and SRT port.

**Offer path** (PC → mobile): the daemon also sends unsolicited offer pulses once per second to every online Tailscale peer on **UDP 7072**. The mobile app listens on 7072 and accepts the first valid offer, which makes discovery near-instant when the PC is already running.

```json
{
  "service": "project-o-stream",
  "version": 1,
  "host": "100.x.y.z",
  "hostname": "DESKTOP-XYZ",
  "srtPort": 7070,
  "discoveryPort": 7071,
  "clientDiscoveryPort": 7072,
  "obsUdpPort": 15000,
  "transport": "srt"
}
```

The last discovered receiver is cached in app preferences so subsequent launches skip the full scan.

---

## Duplicate Receiver Detection

Running two receiver instances on the same Tailnet simultaneously causes the mobile app to split sessions unpredictably. To prevent this, each discovery daemon also listens on port 7072 for incoming server offers. If a valid offer arrives from a **different** Tailscale IP, the daemon prints a conflict report and shuts itself down — which immediately halts the associated ffmpeg process via the monitoring loop in `start-receiver.ps1`.

```
=== RECEIVER CONFLICT DETECTED ===
  Another Project O receiver is active on this network:
  Peer     : DESKTOP-ABC (100.x.y.z)
  Reason   : Duplicate receivers split incoming sessions on the same Tailnet.
  Action   : Shutting down. Keep only one receiver active at a time.
===================================
```

Both peers detect each other and both exit. Only restart one.

---

## Repository Layout

```
project-o-stream/                ← Flutter project root (pubspec.yaml here)
│
├── lib/                         Dart source
│   ├── main.dart                UI — camera preview, stream controls, settings
│   ├── discovery.dart           Zero-input receiver discovery (UDP)
│   ├── native_streamer.dart     Flutter ↔ native method/event channel bridge
│   └── stream_config.dart       Stream profiles and SenderConfig model
│
├── android/                     Android native (Kotlin + StreamPack 3.1.2)
│
├── ios/                         iOS native (Swift + AVFoundation)
│   ├── Runner.xcodeproj/
│   ├── Runner.xcworkspace/
│   ├── Flutter/                 xcconfig files (Generated.xcconfig excluded)
│   ├── Podfile
│   └── Runner/
│       ├── AppDelegate.swift
│       ├── CameraController.swift
│       └── PreviewFactory.swift
│
├── server/                      PC receiver scripts
│   ├── start-receiver.ps1       Main entry point — launches ffmpeg + discovery
│   └── discovery-server.ps1     Discovery daemon (UDP 7071 probes / 7072 offers)
│
├── ops/                         Operator convenience scripts
│   ├── start-receiver.ps1       Wrapper → server/start-receiver.ps1
│   ├── start-discovery.ps1      Standalone discovery daemon launcher
│   ├── launch-obs.ps1           Launches vendor OBS portable
│   └── doctor.ps1               Pre-flight health check
│
├── releases/
│   └── server-win/              Self-contained distributable for Windows
│       ├── start-receiver.ps1
│       ├── discovery-server.ps1
│       └── launch.bat           Double-click launcher (no PowerShell window needed)
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── CI.md
│   ├── PROTOCOL.md
│   └── DEPLOYMENT.md
│
├── pubspec.yaml
├── codemagic.yaml
└── vendor/obs-portable/         OBS runtime — NOT in git (user provides)
```

---

## Requirements

### PC Workstation

| Requirement                              | Notes                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Windows 10/11                            | PowerShell 5.1+ included                                                                                |
| [Tailscale](https://tailscale.com/download) | Must be connected and authenticated                                                                     |
| [ffmpeg](https://ffmpeg.org/download.html)  | In `PATH`, **or** place `ffmpeg.exe` at `C:\Users\kings\Downloads\moviesLab\mpv\ffmpeg.exe` |
| OBS Studio                               | Portable build under `vendor/obs-portable/`, or any installed OBS                                     |

### Mobile Device

| Requirement      | Android                        | iOS                                                         |
| ---------------- | ------------------------------ | ----------------------------------------------------------- |
| OS version       | Android 8.0+ (API 26)          | iOS 13.0+                                                   |
| Tailscale app    | Same tailnet as PC             | Same tailnet as PC                                          |
| Hardware encoder | H.264 required, H.265 optional | H.264 required (H.265 optional)                             |
| SRT transport    | StreamPack 3.1.2 (bundled)     | Requires `libsrt.xcframework` — see [iOS Build](#ios-build) |

### Development (to build the mobile app)

| Tool                                                          | Required for              |
| ------------------------------------------------------------- | ------------------------- |
| [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.4+ | All mobile builds         |
| Android Studio + Android SDK                                  | Android builds            |
| macOS + Xcode 14+                                             | iOS builds only           |
| CocoaPods                                                     | iOS dependency management |

---

## Quick Start

### 1. Health check

Verify all workstation dependencies before starting:

```powershell
.\ops\doctor.ps1
```

This checks for ffmpeg, tailscale, and correct port availability.

### 2. Start the PC receiver

```powershell
.\ops\start-receiver.ps1
```

Or use the distributable package directly (no repo needed):

```batch
releases\server-win\launch.bat
```

The console shows the receiver address and confirms discovery is active:

```
========================================
 Stream Receiver
 SRT listen : srt://0.0.0.0:7070
 Advertise  : srt://100.x.y.z:7070
 Output     : udp://127.0.0.1:15000
 OBS Input  : udp://127.0.0.1:15000
 Latency    : 80 ms
 Discovery  : UDP 7071 probes, UDP 7072 offers
========================================
```

### 3. Configure OBS

Add a **Media Source** with the following URL:

```
udp://127.0.0.1:15000
```

Recommended OBS Media Source settings:

- **Buffering**: `0 ms` (or as low as possible)
- **Use hardware decoding when available**: ✓ (optional but reduces CPU)
- **Restart playback when source becomes active**: ✓

### 4. Launch OBS (optional — uses bundled portable build)

```powershell
.\ops\launch-obs.ps1
```

### 5. Open the mobile app

Install the Flutter app on your device (see [Mobile Build](#mobile-build)). On launch it automatically:

1. Starts the camera preview
2. Sends discovery probes on UDP 7071 to find the receiver
3. Listens on UDP 7072 for the PC's unsolicited offer pulse
4. Caches the receiver address for future sessions

Tap the red circle button to go live. The top bar shows connection status and stream stats.

---

## Receiver Options

```powershell
.\server\start-receiver.ps1 [-SrtPort <int>] [-ObsUdpPort <int>] [-LatencyMs <int>] [-NoDiscovery]
```

| Parameter        | Default   | Description                                   |
| ---------------- | --------- | --------------------------------------------- |
| `-SrtPort`     | `7070`  | UDP port the SRT listener binds to            |
| `-ObsUdpPort`  | `15000` | Local UDP port forwarded to OBS               |
| `-LatencyMs`   | `80`    | SRT end-to-end latency budget in milliseconds |
| `-NoDiscovery` | off       | Skip launching the discovery daemon           |

**Example — lower latency on a reliable LAN:**

```powershell
.\server\start-receiver.ps1 -LatencyMs 40
```

**Example — custom ports:**

```powershell
.\server\start-receiver.ps1 -SrtPort 7080 -ObsUdpPort 15010
```

---

## Network Ports

| Port  | Protocol      | Direction        | Purpose                                        |
| ----- | ------------- | ---------------- | ---------------------------------------------- |
| 7070  | UDP (SRT)     | Mobile → PC     | Live video/audio stream                        |
| 7071  | UDP           | Mobile → PC     | Discovery probe (`PROJECTO_STREAM_DISCOVER`) |
| 7072  | UDP           | PC → Mobile     | Receiver offer pulse (JSON)                    |
| 15000 | UDP (MPEG-TS) | PC → PC (local) | OBS media source input                         |

All traffic between devices travels inside the Tailscale WireGuard tunnel — no router port-forwarding needed.

---

## Stream Profiles

The mobile app offers three built-in profiles selectable from the settings panel:

| Profile                      | Resolution   | FPS | Video bitrate | Audio bitrate |
| ---------------------------- | ------------ | --- | ------------- | ------------- |
| **1080p30**            | 1080 × 1920 | 30  | 12 Mbps       | 128 kbps      |
| **4K30** *(default)* | 2160 × 3840 | 30  | 50 Mbps       | 128 kbps      |
| **4K60**               | 2160 × 3840 | 60  | 90 Mbps       | 128 kbps      |

Additional toggles per session:

- **HEVC** — switch encoder from H.264 to H.265 (reduces bitrate for same quality)
- **Mic** — include device microphone audio in the stream
- **SRT latency** — slider from 40 ms to 240 ms (adjust to match network conditions)
- **Zoom** — 1× to 8× optical/digital zoom
- **Torch** — rear flash
- **Camera** — front/rear toggle

---

## Mobile Build

Codemagic should use `codemagic.yaml` from the repository root. A `mobile/`
symlink compatibility path is present only for Codemagic UI workflows that still
run from `/clone/mobile`.

### Android

```powershell
flutter pub get
flutter run          # deploy to connected device
# or
flutter build apk --release
```

Android streaming uses **StreamPack 3.1.2** (`io.github.thibaultbee.streampack`), which drives the device's hardware encoder and SRT output natively. No extra native libraries needed.

Minimum SDK: Android 8.0 (API 26).
Target SDK: 35.

### iOS Build

iOS build requires **macOS with Xcode 14+**. The Xcode project is included in the repo — no `flutter create` needed.

```bash
flutter pub get                  # generates Flutter/Generated.xcconfig
cd ios
pod install
open Runner.xcworkspace          # open in Xcode — do NOT open .xcodeproj directly
```

Then in Xcode: select your device → Build & Run (`⌘R`).

> **SRT streaming on iOS requires `libsrt.xcframework`.**
> The camera preview, discovery, and UI all work immediately. To enable actual video streaming:
>
> 1. Download `libsrt.xcframework` from the [SRT Alliance releases](https://github.com/Haivision/srt/releases) or build from source on macOS.
> 2. In Xcode: select the **Runner** target → **General** → **Frameworks, Libraries, and Embedded Content** → **+** → add `libsrt.xcframework`.
> 3. Implement `captureOutput(_:didOutput:from:)` in `CameraController.swift` to feed sample buffers into the SRT muxer.
>
> Without the framework, tapping the stream button shows a clear error: *"iOS SRT transport requires linking libsrt.xcframework in the iOS build."*

---

## Distributable Server Package

`releases/server-win/` is a self-contained folder you can copy to any Windows machine without cloning the repo:

```
releases/server-win/
├── start-receiver.ps1      Main receiver + discovery supervisor
├── discovery-server.ps1    UDP discovery daemon
└── launch.bat              Double-click to start — no PowerShell window required
```

Requirements on the target machine: **Tailscale** + **ffmpeg in PATH** (or ffmpeg.exe placed in the same folder).

---

## Troubleshooting

**Discovery times out / "Searching receiver" stays on screen**

- Confirm both devices are on the same Tailscale tailnet (`tailscale status`).
- Check that UDP 7071 and 7072 are not blocked by Windows Firewall on the PC.
- Run `.\ops\doctor.ps1` to verify all services are reachable.
- Tap the radar icon in the app's settings panel to retry discovery manually.

**OBS shows a black frame or no signal**

- Confirm the receiver is running and shows "waiting for connection" in ffmpeg output.
- Check the Media Source URL is exactly `udp://127.0.0.1:15000`.
- Try restarting the OBS Media Source (right-click → Restart).
- If the stream was stopped and restarted, close and reopen the Media Source.

**Video is choppy or dropping frames**

- Increase SRT latency: `-LatencyMs 120` or higher for spotty Wi-Fi.
- Switch from 4K60 to 4K30 or 1080p30 on the mobile app.
- Ensure the phone is on Wi-Fi rather than cellular — SRT tolerates loss but still needs bandwidth.

**"Receiver conflict detected" — receiver shuts down immediately**

- Another instance of `start-receiver.ps1` is running on a different machine in the same tailnet.
- Only one receiver should be active at a time. Shut down the other instance first.

**ffmpeg not found**

- Install ffmpeg and add it to your system `PATH`, or place `ffmpeg.exe` in `releases/server-win/`.
- Verify with `ffmpeg -version` in a new PowerShell window.

---

## Documentation

| Doc                                           | Contents                                                  |
| --------------------------------------------- | --------------------------------------------------------- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Component map, media path, design rules                   |
| [`docs/CI.md`](docs/CI.md)                     | Codemagic workflow and Android CI build notes             |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md)         | SRT parameters, discovery payload schema, OBS integration |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)     | Step-by-step deployment for workstation and mobile        |

---

## License

Private project. All rights reserved.
