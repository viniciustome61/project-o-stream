# Mobile App

Flutter mobile sender for Project O Stream.

## Features

- Native preview surface.
- Portrait-locked UI.
- Zero-input receiver discovery over Tailscale.
- Profiles: 1080p30, 4K30, 4K60.
- Bitrate, codec, microphone, torch, zoom, and camera switch controls.
- Android camera, hardware encoder, and SRT sender through StreamPack.
- iOS camera preview and Flutter channel wiring.

## Android

Android uses StreamPack:

```text
Camera -> hardware encoder -> SRT -> PC receiver
```

Before building, create `android/local.properties`:

```properties
flutter.sdk=C:\\src\\flutter
```

Then:

```powershell
flutter pub get
flutter build apk
```

## iOS

iOS must be built on macOS with Xcode. The native camera preview and channel wiring are present under `ios/Runner`.

The SRT transport layer requires linking a libsrt XCFramework and connecting it inside `CameraController.startStream(config:)`.

## Receiver Discovery

The app resolves the PC receiver without user-entered IPs:

```text
mobile -> PC UDP 7071 probes
PC -> mobile UDP 7072 offers
```
