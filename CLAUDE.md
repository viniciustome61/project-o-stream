# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Project O Stream streams a phone camera into OBS Studio with zero IP configuration. The mobile app hardware-encodes H.264/H.265 and sends it via SRT over a Tailscale tunnel to a Windows PC receiver, which remuxes to UDP for OBS.

```
Phone camera → native encoder → SRT (port 7070) → receiver.py → UDP 127.0.0.1:15000 → OBS
```

Discovery uses a UDP probe/offer pattern: phone broadcasts on 7071, PC responds on 7072. Telemetry (battery, thermal, RTT) flows back from the phone to port 7075.

## Branches

- **`main`** — mobile Flutter app only. All camera, streaming, and iOS/Android changes go here.
- **`desktop/tauri-svelte`** — Windows desktop controller (Tauri + Svelte + Rust). Never make mobile changes here.

The repo root is the Flutter project root — all CI assumes this.

## Build & Lint Commands

```bash
flutter pub get          # install deps
flutter analyze          # lint (enforced: single quotes, no print())
flutter build apk --debug
flutter build ios --release --no-codesign
flutter clean && flutter pub get
```

iOS requires a physical device target (not simulator) — native camera/SRT code doesn't run on simulator.

**Desktop (on `desktop/tauri-svelte` branch):**
```powershell
cd desktop && npm install
npm run tauri dev    # dev server
npm run tauri build  # Windows MSI
```

**Receiver (Windows):**
```powershell
.\server\start-receiver.ps1          # start Python TUI receiver
.\ops\doctor.ps1                     # pre-flight health check
python ship.py                       # commit → push → wait CI → download IPA
```

**Always run `ship.py` after completing any feature or fix.**

## Code Architecture

### Flutter side (`lib/`)

Six files, each with a single responsibility:

- **`main.dart`** — `SenderScreen` stateful widget: camera preview, go-live button, settings panel, debug overlay, telemetry subscription, auto-reconnect loop, lock screen overlay, fallback streaming logic
- **`native_streamer.dart`** — method/event channel bridge. All native calls go through here (`startStream`, `startPreview`, `setTorch`, `saveEndpoint`, etc.)
- **`stream_config.dart`** — `SenderConfig` immutable value type + named profiles (`stable1080p60`, etc.)
- **`discovery.dart`** — `ReceiverDiscovery.find()` static method: sends UDP probes, receives JSON offer, probes LAN vs Tailscale latency, picks best endpoint with fallback. `DiscoveredReceiver` carries `preferredHost`/`fallbackHost`/transport.
- **`camera_state.dart`** — `CameraState` ChangeNotifier for non-native preview path only. When `_useNativePreview = true` (iOS default), `_controller` is null — torch and lens must go through `NativeStreamer`, not `CameraState`.
- **`app_metadata.dart`** — version constants

### Native bridge

On iOS, `NativeStreamer` calls into HaishinKit 2.2.0 (Swift SRT sender, CocoaPods via Podfile). On Android it calls StreamPack 3.1.2. The Flutter layer never touches AVFoundation or MediaCodec directly.

### Server side (`server/`)

`receiver.py` is a self-contained Textual TUI. Key internals:
- **`SlotState`** — per-camera slot: SRT port, OBS UDP port, FFmpeg process handle, telemetry fields
- **`SlotAssigner`** — IP-keyed hashtable with TTL; auto-grows slots when all occupied (`_grow_slot`)
- **`Receiver`** — data model + daemon threads: `_discovery_worker`, `_telemetry_worker`, `_relay_worker`, `_lan_offer_worker`, `_tailnet_offer_worker`
- **`_relay_worker_slot`** — restarts FFmpeg on exit with 3 s flat retry; updates `slot.ffmpeg_status` in-place (never floods the log)
- **`_webcam_worker_slot`** — reads the relay's UDP output, decodes via FFmpeg rawvideo pipe, pushes frames into pyvirtualcam (Unity Capture backend). One device per slot: `"Unity Video Capture"`, `"Unity Video Capture (1)"`, etc.
- **`ReceiverApp`** — Textual `App[None]` with DataTable + RichLog. UI updates from worker threads use `call_from_thread()`. Bindings: `c` copy OBS URL, `s` copy log, `l` cycle lens, `k` kill slot, `q` quit. All log messages are also written to `server.log` next to the script.

Slot ports: SRT `7070 + i*3`, OBS UDP `15000 + i*3`.

`discovery-server.ps1` is a separate PowerShell discovery daemon (legacy; `receiver.py` now includes its own discovery worker).

### Releases (`releases/server-win/`)

Self-contained Windows package. `server.bat` is the user-facing entry point — it installs Python deps, optionally registers `UnityCaptureFilter64.dll` for virtual webcam, then launches `receiver.py`. Keep `releases/server-win/receiver.py` as an exact copy of `server/receiver.py` at all times.

## Key Constraints

- **Hardware encoding only** — no software encode path
- **`_useNativePreview = true` on iOS** means `CameraState._controller` is null; torch/lens must use `NativeStreamer`
- **`pyvirtualcam` needs Unity Capture driver registered** before virtual webcam works; `server.bat` handles this automatically when `UnityCaptureFilter64.dll` is present. Falls back to OBS Virtual Camera for slot 0 if Unity Capture isn't available
- **Flutter version locked to 3.41.8** in CI (`mobile-build.yml`, `combined-release.yml`)
- **Dart null safety** — `receiver?.method()` returns `T?`; chain `?.toUpperCase()` not `.toUpperCase()`

## CI

`mobile-build.yml` triggers on every push to `main` — builds unsigned iOS IPA and Android APK. `combined-release.yml` triggers on `v*` tags and also builds the Tauri Windows MSI.

`ship.py` requires `GITHUB_TOKEN` in `.env.ship`. Run it after any change; it commits (via Gemini CLI for message), pushes, waits for CI, downloads the IPA artifact.

## Port Reference

| Port | Protocol | Purpose |
|------|----------|---------|
| 7070 + i×3 | UDP/TCP (SRT) | Camera slot i ingest |
| 7071 | UDP | Discovery probe listener |
| 7072 | UDP | Discovery offer push |
| 7075 | UDP | Telemetry from phone |
| 7076 | UDP | Remote control to phone |
| 15000 + i×3 | UDP | OBS Media Source for slot i |
