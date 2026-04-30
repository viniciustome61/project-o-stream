# Protocol

## Selected Transport

SRT over Tailscale.

Tailscale provides authenticated private addressing and NAT traversal. SRT carries the media stream.

## Receiver

The PC receiver listens on:

```text
srt://0.0.0.0:7070
```

Recommended SRT options:

```text
mode=listener
transtype=live
latency=80000
rcvlatency=80000
peerlatency=80000
tlpktdrop=1
pkt_size=1316
```

## Duplicate Receiver Detection

Receiver offers are also used as split-receiver detection. Every receiver
listens on UDP `7072` for offers from other Project O receivers. If an offer
arrives from a different Tailscale IP, the receiver prints the peer name,
peer address, and shutdown reason, then exits cleanly. The supervising
`start-receiver.ps1` script then stops the associated ffmpeg process.

This keeps the tailnet in a single-receiver state. If two receivers find each
other, both exit and the owner should restart only the intended receiver.

## Mobile Sender

The mobile app discovers the receiver automatically over Tailscale before it
starts media transport.

Discovery paths:

```text
mobile -> PC UDP 7071: PROJECTO_STREAM_DISCOVER
PC -> mobile UDP 7072: project-o-stream JSON offer
```

The receiver offer contains the Tailscale host, SRT port, OBS UDP output port,
and protocol version. After discovery, the mobile app connects to:

```text
srt://<pc-tailscale-ip>:7070
```

Payload should be MPEG-TS containing hardware-encoded H.264 or H.265 plus AAC audio.

## OBS

Default receiver output is local MPEG-TS over UDP:

```text
udp://127.0.0.1:15000
```

OBS should use a Media Source pointed at that URL with minimal buffering.
