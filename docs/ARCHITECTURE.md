# Architecture

## Goal

Low-latency, high-quality phone camera ingest into OBS over a private Tailscale network.

## Components

- `lib/`, `android/`, `ios/`: Flutter UI plus native Android/iOS camera and encoder bridges.
- `server/`: PC receiver that accepts SRT over the Tailscale interface and forwards local MPEG-TS to OBS.
- `ops/`: scripts for launching OBS, checking the workstation, and starting the receiver.
- `vendor/obs-portable/`: local OBS runtime used by this workstation.

## Media Path

```text
Mobile camera
  -> hardware H.264/H.265 encoder
  -> SRT over Tailscale
  -> receiver remux
  -> udp://127.0.0.1:15000
  -> OBS Media Source
```

## Discovery Path

```text
mobile UDP probe on 7071
PC UDP offer pulse on 7072 to online Tailscale peers
```

## Design Rules

- Use native camera APIs exclusively.
- Use hardware encoding on device.
- Keep Tailscale as the private network layer only.
- Keep one production media path: SRT in, MPEG-TS UDP out.
- Prefer native sensor orientation and encoder configuration over frame transforms.
