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
