#!/usr/bin/env python3
"""
Project-O Stream Receiver
Textual TUI receiver with rich per-device telemetry.

Requires: pip install textual
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Optional

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import DataTable, Footer, Header, RichLog

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DISC_PORT       = 7071
DISC_PUSH_PORT  = 7072
TELE_PORT       = 7075
CONTROL_PORT    = 7076
OBS_STATE_HOST  = "127.0.0.1"
OBS_STATE_PORT  = 7077
SLOT_TTL        = 120
TELE_FRESH      = 20
PROBE_BYTES     = b"PROJECTO_STREAM_DISCOVER"
LAN_PROBE_BYTES = b"PROJECTO_STREAM_LAN_PROBE"
LAN_ACK_BYTES   = b"PROJECTO_STREAM_LAN_ACK"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _add_lan_candidate(candidates: list[str], ip: Optional[str]) -> None:
    if _is_lan_ip(ip) and ip not in candidates:
        candidates.append(ip or "")


def _default_route_ip() -> Optional[str]:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def _windows_lan_ips() -> list[str]:
    try:
        result = subprocess.run(
            [
                "powershell", "-NoProfile", "-Command",
                "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | "
                "Where-Object { $_.IPAddress -notmatch '^(127\\.|169\\.254\\.|100\\.)' "
                "} | "
                "Sort-Object InterfaceMetric,PrefixLength | "
                "Select-Object -ExpandProperty IPAddress",
            ],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return []
    except Exception:
        return []
    ips: list[str] = []
    for line in result.stdout.splitlines():
        _add_lan_candidate(ips, line.strip())
    return ips


def _lan_ips() -> list[str]:
    ips: list[str] = []
    _add_lan_candidate(ips, _default_route_ip())
    for ip in _windows_lan_ips():
        _add_lan_candidate(ips, ip)
    # Windows Mobile Hotspot/ICS commonly binds the host to 192.168.137.1.
    # Keep it as a low-priority candidate because some Windows builds do not
    # expose the hotspot adapter through the normal address query quickly.
    if os.name == "nt":
        _add_lan_candidate(ips, "192.168.137.1")
    try:
        for result in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            _add_lan_candidate(ips, result[4][0])
    except Exception:
        pass
    return ips


def _lan_ip() -> str:
    ips = _lan_ips()
    return ips[0] if ips else "127.0.0.1"


def _tailscale_ip() -> Optional[str]:
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            return result.stdout.strip().splitlines()[0].strip()
    except Exception:
        pass
    return None


def _is_tailscale_ip(ip: Optional[str]) -> bool:
    try:
        addr = ipaddress.ip_address(ip or "")
        return addr in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


def _is_lan_ip(ip: Optional[str]) -> bool:
    try:
        addr = ipaddress.ip_address(ip or "")
        return addr.version == 4 and addr.is_private and not addr.is_loopback and not addr.is_link_local
    except ValueError:
        return False


def _infer_transport(ip: str) -> str:
    try:
        addr = ipaddress.ip_address(ip)
        if _is_tailscale_ip(ip):
            return "tailscale"
        if addr.is_private:
            return "lan"
        return "wan"
    except ValueError:
        return "lan"


def _same_lan_layer(left: str, right: str) -> bool:
    try:
        left_addr = ipaddress.ip_address(left)
        right_addr = ipaddress.ip_address(right)
    except ValueError:
        return False
    if left_addr.version != 4 or right_addr.version != 4:
        return False
    if not _is_lan_ip(left) or not _is_lan_ip(right):
        return False
    return left.split(".")[:3] == right.split(".")[:3]


def _best_lan_ip_for_client(client_ip: str, lan_ips: list[str]) -> Optional[str]:
    for lan_ip in lan_ips:
        if _same_lan_layer(client_ip, lan_ip):
            return lan_ip
    return lan_ips[0] if lan_ips else None


def _directed_broadcast(ip: str) -> Optional[str]:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if addr.version != 4 or not _is_lan_ip(ip):
        return None
    parts = ip.split(".")
    if len(parts) != 4:
        return None
    return f"{parts[0]}.{parts[1]}.{parts[2]}.255"


def _lan_offer_targets(lan_ips: list[str]) -> list[tuple[str, str]]:
    targets: list[tuple[str, str]] = []

    def add(host: str, lan_ip: str) -> None:
        target = (host, lan_ip)
        if target not in targets:
            targets.append(target)

    for lan_ip in lan_ips:
        broadcast = _directed_broadcast(lan_ip)
        if broadcast:
            add(broadcast, lan_ip)
        add("255.255.255.255", lan_ip)
    return targets


def _copy_to_clipboard(text: str) -> None:
    if os.name == "nt":
        subprocess.run(["clip"], input=text, text=True, check=True, timeout=2)
        return

    for cmd in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"]):
        try:
            subprocess.run(cmd, input=text, text=True, check=True, timeout=2)
            return
        except Exception:
            continue
    raise RuntimeError("No clipboard command found")


def _advertise_host(probe_source_ip: str, lan_ips: list[str], tailscale_ip: Optional[str]) -> str:
    lan_ip = _best_lan_ip_for_client(probe_source_ip, lan_ips)
    if _is_lan_ip(probe_source_ip) and lan_ip:
        return lan_ip
    if _is_tailscale_ip(probe_source_ip) and tailscale_ip:
        return tailscale_ip
    if lan_ip:
        return lan_ip
    if tailscale_ip:
        return tailscale_ip
    return probe_source_ip


def _tailscale_peer_ips(self_ip: Optional[str]) -> list[str]:
    if not self_ip:
        return []
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return []
        status = json.loads(result.stdout)
    except Exception:
        return []

    peer_ips: list[str] = []
    for peer in (status.get("Peer") or {}).values():
        if not peer.get("Online"):
            continue
        for peer_ip in peer.get("TailscaleIPs") or []:
            if _is_tailscale_ip(peer_ip) and peer_ip != self_ip and peer_ip not in peer_ips:
                peer_ips.append(peer_ip)
    return peer_ips


def _batt_bar(pct: float, width: int = 8) -> str:
    filled = round(pct * width)
    return "▮" * filled + "▯" * (width - filled)


def _open_firewall(port: int, proto: str = "UDP") -> None:
    rule_name = f"Project-O-Stream-{proto}-{port}"
    try:
        r = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={rule_name}"],
            capture_output=True, text=True, timeout=5
        )
        if r.returncode == 0:
            return
        subprocess.run([
            "netsh", "advfirewall", "firewall", "add", "rule",
            f"name={rule_name}", "dir=in", f"protocol={proto.lower()}",
            f"localport={port}", "action=allow"
        ], capture_output=True, timeout=5)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Slot state
# ---------------------------------------------------------------------------

class SlotState:
    def __init__(self, index: int, srt_port: int, obs_port: int):
        self.index       = index
        self.srt_port    = srt_port
        self.obs_port    = obs_port
        self.ip: Optional[str] = None
        self.hostname:  Optional[str]   = None
        self.lens:      Optional[str]   = None
        self.control_port: int          = CONTROL_PORT
        self.battery:   Optional[float] = None
        self.charging:  bool            = False
        self.thermal:   Optional[str]   = None
        self.rtt_ms:    Optional[float] = None
        self.transport: Optional[str]   = None
        self.tele_ts:       float           = 0.0
        self.ffmpeg_status: str            = "idle"
        self.proc:          Optional[subprocess.Popen] = None  # type: ignore[type-arg]
        self.zoom_level:    float          = 1.0
        self.torch_on:      bool           = False
        self.relay_mode:    str            = "srt"  # "obs" = UDP relay via FFmpeg | "srt" = OBS connects directly
        self.phone_slot_index: int         = 0      # slotIndex the phone expects in control commands (from telemetry)
        self.live:          bool           = False

    @property
    def connected(self) -> bool:
        return (time.time() - self.tele_ts) < TELE_FRESH and self.ip is not None

    @property
    def tele_fresh(self) -> bool:
        return (time.time() - self.tele_ts) < TELE_FRESH


# ---------------------------------------------------------------------------
# Slot assigner (IP-keyed, TTL, auto-grow)
# ---------------------------------------------------------------------------

class SlotAssigner:
    def __init__(self, slot_count_fn: "Callable[[], int]", grow_fn: "Callable[[], int]"):
        self._count = slot_count_fn
        self._grow  = grow_fn
        self._table: dict[str, tuple[int, float]] = {}
        self._lock  = threading.Lock()

    def get(self, ip: str) -> int:
        now = time.time()
        with self._lock:
            if ip in self._table:
                slot, _ = self._table[ip]
                self._table[ip] = (slot, now)
                return slot
            self._table = {k: v for k, v in self._table.items() if now - v[1] < SLOT_TTL}
            used = {v[0] for v in self._table.values()}
            for idx in range(self._count()):
                if idx not in used:
                    self._table[ip] = (idx, now)
                    return idx
            new_idx = self._grow()
            self._table[ip] = (new_idx, now)
            return new_idx

    def lookup(self, ip: str) -> Optional[int]:
        with self._lock:
            entry = self._table.get(ip)
            if entry and (time.time() - entry[1]) < SLOT_TTL:
                return entry[0]
            return None

    def bind(self, ip: str, slot: int) -> None:
        if slot < 0 or slot >= self._count():
            return
        with self._lock:
            self._table[ip] = (slot, time.time())

    def remap(self, ip: str, new_slot: int) -> None:
        with self._lock:
            self._table[ip] = (new_slot, time.time())


# ---------------------------------------------------------------------------
# Receiver — data model + workers
# ---------------------------------------------------------------------------

class Receiver:
    def __init__(self, args: argparse.Namespace):
        self.args     = args
        self.start_ts = time.time()
        self.stopping = False

        self.lan_ips: list[str] = []
        self.lan_ip = "127.0.0.1"
        self._refresh_lan_ips()
        self.tailscale_ip = _tailscale_ip()

        self.slots: list[SlotState] = []
        for i in range(args.cameras):
            slot = SlotState(
                index    = i,
                srt_port = args.port + i * 3,
                obs_port = args.obs_port + i * 3,
            )
            self.slots.append(slot)

        self.assigner = SlotAssigner(
            slot_count_fn=lambda: len(self.slots),
            grow_fn=self._grow_slot,
        )

        self.ffmpeg_path = args.ffmpeg or "ffmpeg"

        self._log_lock = threading.Lock()
        self._log: list[tuple[str, str]] = []
        self._app: Optional["ReceiverApp"] = None
        if getattr(sys, 'frozen', False):
            script_dir = os.path.dirname(sys.executable)
        else:
            script_dir = os.path.dirname(os.path.abspath(__file__))
        log_path = os.path.join(script_dir, "server.log")
        self._log_file = open(log_path, "a", encoding="utf-8", buffering=1)  # noqa: SIM115

        for slot in self.slots:
            _open_firewall(slot.srt_port, "UDP")
            _open_firewall(slot.srt_port, "TCP")
        _open_firewall(DISC_PORT, "UDP")
        _open_firewall(TELE_PORT, "UDP")

    # ------------------------------------------------------------------ grow

    def _grow_slot(self) -> int:
        i = len(self.slots)
        slot = SlotState(index=i, srt_port=self.args.port + i * 3, obs_port=self.args.obs_port + i * 3)
        self.slots.append(slot)
        _open_firewall(slot.srt_port, "UDP")
        _open_firewall(slot.srt_port, "TCP")
        self._log_msg(f"Camera {i + 1} added automatically (SRT :{slot.srt_port} → UDP :{slot.obs_port})")
        return i

    # ------------------------------------------------------------------ log

    def _log_msg(self, msg: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        with self._log_lock:
            self._log.append((ts, msg))
            if len(self._log) > 200:
                self._log.pop(0)
            try:
                self._log_file.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
            except Exception:
                pass
        if self._app is not None:
            try:
                self._app.call_from_thread(self._app.push_log, ts, msg)
            except Exception:
                pass

    # ------------------------------------------------------------------ workers

    def _refresh_lan_ips(self) -> None:
        lan_ips = _lan_ips()
        if lan_ips:
            self.lan_ips = lan_ips
            self.lan_ip = lan_ips[0]

    def _slot_offer(
        self,
        slot_idx: int,
        advertise_host: str,
        hostname: str,
        lan_ip: Optional[str],
    ) -> dict[str, object]:
        slot = self.slots[slot_idx]
        return {
            "service":     "project-o-stream",
            "host":        advertise_host,
            "hostname":    hostname,
            "srtPort":     slot.srt_port,
            "obsUdpPort":  slot.obs_port,
            "transport":   _infer_transport(advertise_host),
            "lanIp":       lan_ip,
            "lanIps":      self.lan_ips,
            "tailscaleIp": self.tailscale_ip,
            "slotIndex":   slot_idx,
            "totalSlots":  len(self.slots),
        }

    def _discovery_offer(self, client_ip: str, hostname: str) -> tuple[dict[str, object], int]:
        self._refresh_lan_ips()
        slot_idx = self.assigner.get(client_ip)
        lan_ip = _best_lan_ip_for_client(client_ip, self.lan_ips)
        advertise_host = _advertise_host(client_ip, self.lan_ips, self.tailscale_ip)
        return self._slot_offer(slot_idx, advertise_host, hostname, lan_ip), slot_idx

    def _discovery_worker(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(1.0)
        try:
            sock.bind(("", DISC_PORT))
        except OSError as e:
            self._log_msg(f"Discovery bind failed: {e}")
            return
        self._log_msg(f"Discovery listening on UDP {DISC_PORT}")
        hostname = socket.gethostname()

        while not self.stopping:
            try:
                data, addr = sock.recvfrom(256)
            except socket.timeout:
                continue
            except Exception:
                continue

            client_ip = addr[0]

            if data == LAN_PROBE_BYTES:
                try:
                    sock.sendto(LAN_ACK_BYTES, addr)
                except Exception:
                    pass
                continue

            if data == PROBE_BYTES:
                offer, slot_idx = self._discovery_offer(client_ip, hostname)
                slot = self.slots[slot_idx]
                transport = _infer_transport(client_ip)
                try:
                    sock.sendto(json.dumps(offer).encode(), addr)
                except Exception:
                    pass
                if slot.ip != client_ip:
                    old_ip = slot.ip
                    slot.ip        = client_ip
                    slot.transport = transport
                    slot.tele_ts   = 0.0  # clear stale telemetry
                    slot.live      = False
                    if old_ip:
                        # new phone taking over a stale slot — restart FFmpeg cleanly
                        if slot.proc and slot.proc.poll() is None:
                            try:
                                slot.proc.kill()
                            except Exception:
                                pass
                        self._log_msg(
                            f"Slot {slot_idx + 1}: {old_ip} replaced by {client_ip} (SRT :{slot.srt_port})"
                        )
                    else:
                        self._log_msg(f"Slot {slot_idx + 1} assigned to {client_ip} (SRT :{slot.srt_port})")

        sock.close()

    def _lan_offer_worker(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        hostname = socket.gethostname()
        last_target_label = ""
        while not self.stopping:
            self._refresh_lan_ips()
            targets = _lan_offer_targets(self.lan_ips)
            target_label = ", ".join(host for host, _ in targets)
            if target_label and target_label != last_target_label:
                self._log_msg(
                    "LAN/hotspot backup offers on UDP "
                    f"{DISC_PUSH_PORT}: {target_label}"
                )
                last_target_label = target_label
            for host, lan_ip in targets:
                offer = self._slot_offer(0, lan_ip, hostname, lan_ip)
                try:
                    sock.sendto(json.dumps(offer).encode(), (host, DISC_PUSH_PORT))
                except Exception:
                    continue
            for _ in range(10):
                if self.stopping:
                    break
                time.sleep(0.1)
        sock.close()

    def _tailnet_offer_worker(self) -> None:
        if not self.tailscale_ip:
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        hostname = socket.gethostname()
        self._log_msg(f"Tailscale backup offers on UDP {DISC_PUSH_PORT}")
        while not self.stopping:
            self._refresh_lan_ips()
            for peer_ip in _tailscale_peer_ips(self.tailscale_ip):
                # lookup only — never create a slot just because a peer exists
                known = self.assigner.lookup(peer_ip)
                slot_idx = known if known is not None else 0
                offer = self._slot_offer(slot_idx, self.tailscale_ip, hostname, self.lan_ip)
                try:
                    sock.sendto(json.dumps(offer).encode(), (peer_ip, DISC_PUSH_PORT))
                except Exception:
                    continue
            for _ in range(10):
                if self.stopping:
                    break
                time.sleep(0.1)
        sock.close()

    def _telemetry_worker(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(1.0)
        try:
            sock.bind(("", TELE_PORT))
        except OSError as e:
            self._log_msg(f"Telemetry bind failed: {e}")
            return
        self._log_msg(f"Telemetry listening on UDP {TELE_PORT}")

        while not self.stopping:
            try:
                data, addr = sock.recvfrom(1024)
            except socket.timeout:
                continue
            except Exception:
                continue

            client_ip = addr[0]
            try:
                payload = json.loads(data.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue

            if payload.get("service") != "project-o-stream-telemetry":
                continue

            slot_idx: Optional[int] = None
            phone_slot: Optional[int] = None  # slotIndex the phone reports (its _receiver.slotIndex)
            requested_slot = payload.get("slotIndex")
            if isinstance(requested_slot, (int, float)) and not isinstance(requested_slot, bool):
                phone_slot = int(requested_slot)
                if 0 <= phone_slot < len(self.slots):
                    slot_idx = phone_slot
                    self.assigner.bind(client_ip, slot_idx)
            if slot_idx is None:
                slot_idx = self.assigner.lookup(client_ip)
            if slot_idx is None:
                slot_idx = self.assigner.get(client_ip)

            slot = self.slots[slot_idx]
            if phone_slot is not None:
                slot.phone_slot_index = phone_slot

            # Hostname-based dedup: if another slot already owns this hostname,
            # remap this IP to that canonical slot and evict the duplicate.
            incoming_hostname = payload.get("hostname")
            if incoming_hostname:
                canonical = next(
                    (s for s in self.slots
                     if s.hostname == incoming_hostname and s.index != slot_idx),
                    None,
                )
                if canonical is not None:
                    self.assigner.remap(client_ip, canonical.index)
                    # Evict the duplicate slot so it becomes available again.
                    slot.ip = None
                    slot.hostname = None
                    slot.tele_ts = 0.0
                    slot.live = False
                    self._log_msg(
                        f"Cam {slot_idx + 1}: duplicate IP {client_ip} remapped "
                        f"to Cam {canonical.index + 1} ({incoming_hostname})"
                    )
                    slot = canonical

            slot.ip         = client_ip
            # Evict IP from any other slot (discovery/telemetry race dedup).
            for _other in self.slots:
                if _other.index != slot.index and _other.ip == client_ip:
                    _other.ip = None
                    _other.hostname = None
                    _other.tele_ts = 0.0
                    _other.live = False
            slot.transport  = payload.get("transport") or _infer_transport(client_ip)
            slot.hostname   = incoming_hostname or slot.hostname
            slot.lens       = payload.get("lens") or slot.lens
            if "live" in payload:
                slot.live = bool(payload.get("live"))
            control_port    = payload.get("controlPort")
            if isinstance(control_port, (int, float)) and not isinstance(control_port, bool):
                control_port = int(control_port)
                if 1 <= control_port <= 65535:
                    slot.control_port = control_port
            slot.battery    = payload.get("battery",     slot.battery)
            slot.charging   = bool(payload.get("charging", slot.charging))
            slot.thermal    = payload.get("thermalState", slot.thermal)
            slot.rtt_ms     = payload.get("rttMs",        slot.rtt_ms)
            slot.tele_ts    = time.time()

            batt_pct = f"{slot.battery*100:.0f}%" if slot.battery is not None else "?"
            self._log_msg(
                f"Tele [Cam {slot.index + 1} {slot.hostname or client_ip}] "
                f"batt={batt_pct} thermal={slot.thermal or '?'} rtt={slot.rtt_ms}ms"
            )

        sock.close()

    def _start_ffmpeg(self, slot: SlotState) -> "subprocess.Popen[bytes]":
        latency_us = self.args.latency * 1000
        input_url = (
            f"srt://0.0.0.0:{slot.srt_port}"
            f"?mode=listener&transtype=live"
            f"&latency={latency_us}&rcvlatency={latency_us}&peerlatency={latency_us}"
            f"&tlpktdrop=1&pkt_size=1316"
        )
        obs_target = f"udp://127.0.0.1:{slot.obs_port}?pkt_size=1316"
        cmd = [
            self.ffmpeg_path,
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-probesize", "32k", "-analyzeduration", "0",
            "-i", input_url,
            "-map", "0", "-c", "copy", "-f", "mpegts", obs_target,
        ]
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def _relay_worker_slot(self, slot: SlotState) -> None:
        self._log_msg(f"Cam {slot.index + 1}: waiting on SRT :{slot.srt_port} -> {self.obs_input_url(slot)}")
        while not self.stopping:
            # SRT direct mode: OBS connects to the SRT port itself, no FFmpeg relay needed
            if slot.relay_mode == "srt":
                slot.ffmpeg_status = "srt-direct"
                time.sleep(0.2)
                continue
            try:
                t0 = time.time()
                slot.ffmpeg_status = "listening"
                slot.proc = self._start_ffmpeg(slot)
                slot.proc.wait()
                if self.stopping:
                    break
                # Mode was switched to SRT while FFmpeg ran — skip retry, go idle
                if slot.relay_mode == "srt":
                    slot.ffmpeg_status = "srt-direct"
                    continue
                elapsed = time.time() - t0
                code    = slot.proc.returncode
                stderr_tail = ""
                if slot.proc.stderr:
                    raw  = slot.proc.stderr.read().decode("utf-8", errors="replace").strip()
                    last = [l.strip() for l in raw.splitlines() if l.strip()]
                    if last:
                        stderr_tail = f" ({last[-1][:80]})"
                # Clean SRT caller disconnect: FFmpeg exits 0 after streaming >2s
                if code == 0 and elapsed > 2.0:
                    slot.ffmpeg_status = "idle"
                    self._log_msg(f"Cam {slot.index + 1}: phone disconnected")
                    slot.ip       = None
                    slot.hostname = None
                    slot.tele_ts  = 0.0
                    slot.live     = False
                    slot.battery  = None
                    slot.thermal  = None
                    slot.rtt_ms   = None
                    time.sleep(1)
                    continue
                if elapsed < 3.0:
                    slot.ffmpeg_status = f"err {code}{stderr_tail} - retry 3s"
                else:
                    slot.ffmpeg_status = "restarting"
                    self._log_msg(f"Cam {slot.index + 1}: FFmpeg exited ({code}), restarting...")
                time.sleep(3)
            except Exception as e:
                slot.ffmpeg_status = "error - retry 3s"
                self._log_msg(f"Cam {slot.index + 1}: relay error: {e}")
                time.sleep(3)

    def _relay_worker(self) -> None:
        if self.args.direct_to_obs:
            return
        started: set[int] = set()
        while not self.stopping:
            for slot in list(self.slots):
                if slot.index not in started:
                    started.add(slot.index)
                    threading.Thread(
                        target=self._relay_worker_slot,
                        args=(slot,),
                        daemon=True,
                        name=f"relay-{slot.index}",
                    ).start()
            time.sleep(0.5)

    def _slot_should_have_obs_source(self, slot: SlotState) -> bool:
        if slot.ip is None:
            return False
        if slot.tele_ts <= 0:
            return True
        return slot.tele_fresh

    def obs_state(self) -> dict[str, object]:
        slots: list[dict[str, object]] = []
        for slot in list(self.slots):
            obs_input = self.obs_input_url(slot)
            mode = "srt" if self.args.direct_to_obs or slot.relay_mode == "srt" else "udp"
            slots.append({
                "index": slot.index,
                "sourceName": f"Project-O Cam {slot.index + 1}",
                "assigned": slot.ip is not None,
                "connected": slot.connected,
                "live": slot.live,
                "obsSourcePresent": self._slot_should_have_obs_source(slot),
                "obsInput": obs_input,
                "obsInputUrl": obs_input,
                "mode": mode,
                "relayMode": slot.relay_mode,
                "srtPort": slot.srt_port,
                "obsUdpPort": slot.obs_port,
                "ip": slot.ip,
                "hostname": slot.hostname,
                "lens": slot.lens,
                "transport": slot.transport,
                "telemetryAgeMs": None if slot.tele_ts <= 0 else int((time.time() - slot.tele_ts) * 1000),
            })
        return {
            "service": "project-o-stream-receiver",
            "version": 1,
            "updatedAt": time.time(),
            "directToObs": bool(self.args.direct_to_obs),
            "latencyMs": self.args.latency,
            "slots": slots,
        }

    def _obs_state_worker(self) -> None:
        if self.args.no_obs_state_api:
            return

        receiver = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                path = self.path.split("?", 1)[0].rstrip("/") or "/"
                if path not in {"/", "/state"}:
                    self.send_error(404)
                    return
                try:
                    body = json.dumps(receiver.obs_state(), separators=(",", ":")).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as e:
                    self.send_error(500, str(e))

            def log_message(self, _format: str, *_args: object) -> None:
                return

        try:
            httpd = ThreadingHTTPServer((OBS_STATE_HOST, self.args.obs_state_port), Handler)
            httpd.timeout = 0.5
        except OSError as e:
            self._log_msg(f"OBS state API bind failed on {OBS_STATE_HOST}:{self.args.obs_state_port}: {e}")
            return

        self._log_msg(f"OBS state API: http://{OBS_STATE_HOST}:{self.args.obs_state_port}/state")
        try:
            while not self.stopping:
                httpd.handle_request()
        finally:
            httpd.server_close()

    # ------------------------------------------------------------------ run / shutdown

    def run(self) -> None:

        for target, name in [
            (self._discovery_worker, "discovery"),
            (self._lan_offer_worker, "lan-offers"),
            (self._tailnet_offer_worker, "tailnet-offers"),
            (self._telemetry_worker, "telemetry"),
            (self._obs_state_worker, "obs-state"),
            (self._relay_worker,     "relay"),
        ]:
            threading.Thread(target=target, daemon=True, name=name).start()

        app = ReceiverApp(self)
        self._app = app
        try:
            app.run()
        finally:
            self._shutdown()

    def _shutdown(self) -> None:
        self.stopping = True
        for slot in self.slots:
            if slot.proc and slot.proc.poll() is None:
                try:
                    slot.proc.terminate()
                    slot.proc.wait(timeout=3)
                except Exception:
                    try:
                        slot.proc.kill()
                    except Exception:
                        pass
        try:
            self._log_file.close()
        except Exception:
            pass
        sys.exit(0)

    def send_control(self, slot: SlotState, action: str, params: Optional[dict] = None) -> bool:
        if not slot.ip:
            self._log_msg(f"Cam {slot.index + 1}: no phone address for remote control")
            return False
        payload = json.dumps({
            "service": "project-o-stream-control",
            "action": action,
            "slotIndex": slot.phone_slot_index,
            "sentAt": time.time(),
            **(params or {}),
        }).encode("utf-8")
        target = (slot.ip, slot.control_port or CONTROL_PORT)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                for _ in range(3):
                    sock.sendto(payload, target)
                    time.sleep(0.04)
            self._log_msg(f"Cam {slot.index + 1}: remote {action} sent to {target[0]}:{target[1]}")
            return True
        except Exception as e:
            self._log_msg(f"Cam {slot.index + 1}: remote {action} failed: {e}")
            return False

    def obs_input_url(self, slot: SlotState) -> str:
        if self.args.direct_to_obs or slot.relay_mode == "srt":
            latency_us = self.args.latency * 1000
            return (
                f"srt://0.0.0.0:{slot.srt_port}"
                f"?mode=listener&transtype=live"
                f"&latency={latency_us}&rcvlatency={latency_us}"
                f"&peerlatency={latency_us}&tlpktdrop=1&pkt_size=1316"
            )
        return f"udp://127.0.0.1:{slot.obs_port}?pkt_size=1316"

    def copy_obs_input(self, slot: SlotState) -> bool:
        url = self.obs_input_url(slot)
        try:
            _copy_to_clipboard(url)
            self._log_msg(f"Cam {slot.index + 1}: copied OBS input: {url}")
            return True
        except Exception as e:
            self._log_msg(f"Cam {slot.index + 1}: clipboard copy failed: {e}")
            return False


# ---------------------------------------------------------------------------
# Textual TUI
# ---------------------------------------------------------------------------

class ReceiverApp(App[None]):
    TITLE = "Project-O Stream Receiver"
    CSS = """
    Header {
        background: $primary-darken-3;
    }
    DataTable {
        height: auto;
        min-height: 5;
        margin: 0 1;
        border: tall $panel;
    }
    DataTable > .datatable--header {
        background: $primary-darken-2;
    }
    RichLog {
        height: 1fr;
        margin: 0 1 1 1;
        border: tall $panel;
        padding: 0 1;
    }
    Footer {
        background: $primary-darken-3;
    }
    """
    BINDINGS = [
        Binding("c",      "copy_obs_input",   "Copy OBS",  show=True),
        Binding("s",      "copy_log",         "Copy log",  show=True),
        Binding("m",      "cycle_relay_mode", "Mode",      show=True),
        Binding("l",      "cycle_lens",       "Lens",      show=True),
        Binding("t",      "toggle_torch",     "Torch",     show=True),
        Binding("z",      "zoom_in",          "Zoom+",     show=True),
        Binding("x",      "zoom_out",         "Zoom-",     show=True),
        Binding("k",      "kill_slot",        "Kill slot", show=True),
        Binding("q",      "quit_app",         "Quit",      show=True),
        Binding("ctrl+c", "quit_app",         "Quit",      show=False),
    ]

    def __init__(self, receiver: Receiver) -> None:
        super().__init__()
        self._receiver    = receiver
        self._col_keys: list = []
        self._known_slots: set[int] = set()
        self._last_action_t: dict[str, float] = {}

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield DataTable(id="cameras", cursor_type="row", zebra_stripes=True)
        yield RichLog(id="log", highlight=True, markup=True, max_lines=200)
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        col_defs = [
            "●", "CAM", "DEVICE", "NETWORK", "RTT", "BATTERY", "THERMAL", "OBS INPUT", "STATUS",
        ]
        self._col_keys = [table.add_column(label) for label in col_defs]
        for slot in self._receiver.slots:
            table.add_row(*self._slot_cells(slot), key=str(slot.index))
            self._known_slots.add(slot.index)

        log = self.query_one(RichLog)
        with self._receiver._log_lock:
            for ts, msg in self._receiver._log:
                log.write(f"[dim]{ts}[/dim] {msg}")

        self._update_subtitle()
        self.set_interval(0.25, self._refresh)

    # ------------------------------------------------------------------ cells

    def _slot_cells(self, s: SlotState) -> tuple:
        dot = Text("●", style="bold green") if s.connected else Text("○", style="dim")

        dev = (Text(s.hostname, style="white") if s.hostname
               else Text("waiting…", style="dim italic"))

        if s.ip and s.transport:
            net = Text(f"{s.transport}  {s.ip}", style="white")
        elif s.ip:
            net = Text(s.ip, style="white")
        else:
            net = Text(f"SRT :{s.srt_port}", style="dim")

        if s.tele_fresh and s.rtt_ms is not None:
            r = s.rtt_ms
            rtt = Text(f"{r:.0f}ms", style="green" if r < 20 else ("yellow" if r < 80 else "red"))
        else:
            rtt = Text("—", style="dim")

        if s.tele_fresh and s.battery is not None:
            pct  = s.battery
            bar  = _batt_bar(pct)
            chg  = " ⚡" if s.charging else ""
            batt = Text(
                f"{pct*100:.0f}% {bar}{chg}",
                style="green" if pct >= 0.5 else ("yellow" if pct >= 0.2 else "red"),
            )
        else:
            batt = Text("—", style="dim")

        if s.tele_fresh and s.thermal:
            th_map = {
                "nominal":  ("OK",   "green"),
                "fair":     ("WARM", "yellow"),
                "serious":  ("HOT",  "red"),
                "critical": ("CRIT", "bold red"),
            }
            label, style = th_map.get(s.thermal.lower(), (s.thermal[:4].upper(), "white"))
            thermal = Text(label, style=style)
        else:
            thermal = Text("—", style="dim")

        # Show compact URL (no query params) — full URL copied via 'c' key
        if self._receiver.args.direct_to_obs or s.relay_mode == "srt":
            obs_display = f"srt://0.0.0.0:{s.srt_port}"
        else:
            obs_display = f"udp://127.0.0.1:{s.obs_port}"
        obs = Text(
            obs_display,
            style="green" if (s.connected or self._receiver.args.direct_to_obs or s.relay_mode == "srt") else "dim",
        )

        st = s.ffmpeg_status
        if st == "listening":
            status = Text(st, style="dim")
        elif st == "srt-direct":
            status = Text("srt-direct", style="cyan")
        elif st in ("restarting", "idle"):
            status = Text(st, style="yellow")
        elif st.startswith("err"):
            status = Text(st, style="red")
        else:
            status = Text(st, style="dim")
        if s.relay_mode == "srt":
            status.append("  [SRT]", style="bold cyan")
        if s.connected:
            if s.torch_on:
                status.append("  🔦", style="yellow")
            if s.zoom_level != 1.0:
                status.append(f"  {s.zoom_level:.1f}x", style="cyan")

        return (dot, str(s.index + 1), dev, net, rtt, batt, thermal, obs, status)

    # ------------------------------------------------------------------ refresh

    def _refresh(self) -> None:
        table = self.query_one(DataTable)
        for slot in list(self._receiver.slots):
            if slot.index not in self._known_slots:
                table.add_row(*self._slot_cells(slot), key=str(slot.index))
                self._known_slots.add(slot.index)
            else:
                cells = self._slot_cells(slot)
                for col_idx, val in enumerate(cells):
                    try:
                        table.update_cell(str(slot.index), self._col_keys[col_idx], val, update_width=True)
                    except Exception:
                        pass
        self._update_subtitle()

    def _update_subtitle(self) -> None:
        r         = self._receiver
        connected = sum(1 for s in r.slots if s.connected)
        total_s   = int(time.time() - r.start_ts)
        hrs, rem  = divmod(total_s, 3600)
        mins, sec = divmod(rem, 60)
        uptime    = f"{hrs:02d}:{mins:02d}:{sec:02d}"
        mode = "direct-to-OBS" if r.args.direct_to_obs else "relay→OBS"
        lan_label = r.lan_ip
        if len(r.lan_ips) > 1:
            lan_label = f"{r.lan_ip} (+{len(r.lan_ips) - 1})"
        ts_part = f"  Tailscale {r.tailscale_ip}" if r.tailscale_ip else ""
        conn_indicator = "🟢" if connected else "○"
        self.sub_title = (
            f"up {uptime}  LAN {lan_label}{ts_part}  "
            f"slots {len(r.slots)}  {mode}  "
            f"connected {conn_indicator} {connected}"
        )

    # ------------------------------------------------------------------ log

    def push_log(self, ts: str, msg: str) -> None:
        self.query_one(RichLog).write(f"[dim]{ts}[/dim] {msg}")

    # ------------------------------------------------------------------ actions

    def _selected_slot(self) -> Optional[SlotState]:
        table = self.query_one(DataTable)
        row_idx = table.cursor_row
        slots = self._receiver.slots
        if 0 <= row_idx < len(slots):
            return slots[row_idx]
        return None

    def _debounce(self, key: str, ms: int = 250) -> bool:
        now = time.monotonic()
        if now - self._last_action_t.get(key, 0.0) < ms / 1000:
            return False
        self._last_action_t[key] = now
        return True

    def action_cycle_relay_mode(self) -> None:
        if not self._debounce("mode", 500):
            return
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Cycle mode: no camera row selected")
            return
        slot.relay_mode = "srt" if slot.relay_mode == "obs" else "obs"
        # Kill FFmpeg so it releases the SRT port; relay_worker_slot will idle or restart
        if slot.proc and slot.proc.poll() is None:
            try:
                slot.proc.kill()
            except Exception:
                pass
        # Ask phone to reconnect so it hits the new listener (OBS or FFmpeg) immediately
        if slot.ip and slot.control_port:
            self._receiver.send_control(slot, "reconnect")
        mode_label = "SRT direct" if slot.relay_mode == "srt" else "UDP relay"
        self._receiver._log_msg(f"Cam {slot.index + 1}: switched to {mode_label}")

    def action_cycle_lens(self) -> None:
        if not self._debounce("lens", 500):
            return
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Cycle lens: no camera row selected")
            return
        if not slot.connected:
            self._receiver._log_msg(f"Cam {slot.index + 1}: phone is not connected")
            return
        slot.zoom_level = 1.0
        self._receiver.send_control(slot, "cycleLens")

    def action_toggle_torch(self) -> None:
        if not self._debounce("torch", 500):
            return
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Toggle torch: no camera row selected")
            return
        if not slot.connected:
            self._receiver._log_msg(f"Cam {slot.index + 1}: phone is not connected")
            return
        slot.torch_on = not slot.torch_on
        self._receiver.send_control(slot, "toggleTorch", {"torch": slot.torch_on})

    def action_zoom_in(self) -> None:
        if not self._debounce("zoom", 500):
            return
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Zoom in: no camera row selected")
            return
        if not slot.connected:
            self._receiver._log_msg(f"Cam {slot.index + 1}: phone is not connected")
            return
        slot.zoom_level = min(8.0, round(slot.zoom_level + 0.5, 1))
        self._receiver.send_control(slot, "setZoom", {"zoom": slot.zoom_level})

    def action_zoom_out(self) -> None:
        if not self._debounce("zoom", 500):
            return
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Zoom out: no camera row selected")
            return
        if not slot.connected:
            self._receiver._log_msg(f"Cam {slot.index + 1}: phone is not connected")
            return
        slot.zoom_level = max(1.0, round(slot.zoom_level - 0.5, 1))
        self._receiver.send_control(slot, "setZoom", {"zoom": slot.zoom_level})

    def action_copy_obs_input(self) -> None:
        slot = self._selected_slot()
        if slot is None:
            self._receiver._log_msg("Copy OBS input: no camera row selected")
            return
        self._receiver.copy_obs_input(slot)

    def action_copy_log(self) -> None:
        with self._receiver._log_lock:
            lines = [f"{ts} {msg}" for ts, msg in self._receiver._log]
        text = "\n".join(lines)
        try:
            _copy_to_clipboard(text)
            self._receiver._log_msg("Log copied to clipboard")
        except Exception as e:
            self._receiver._log_msg(f"Copy log failed: {e}")

    def action_kill_slot(self) -> None:
        slot = self._selected_slot()
        if slot is None:
            return
        if slot.relay_mode == "srt" and slot.ip and slot.control_port:
            self._receiver.send_control(slot, "stopStream")
        if slot.proc and slot.proc.poll() is None:
            try:
                slot.proc.kill()
                self._receiver._log_msg(f"Cam {slot.index + 1}: killed by user")
            except Exception as e:
                self._receiver._log_msg(f"Cam {slot.index + 1}: kill failed: {e}")
        elif slot.relay_mode != "srt":
            self._receiver._log_msg(f"Cam {slot.index + 1}: not running")

    def action_quit_app(self) -> None:
        for slot in self._receiver.slots:
            if slot.relay_mode == "srt" and slot.ip and slot.control_port:
                self._receiver.send_control(slot, "stopStream")
        self._receiver.stopping = True
        self.exit()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Project-O Stream Receiver — Textual TUI\n\n"
                    "Receives SRT camera streams from Project-O phones and relays\n"
                    "them to OBS Studio as UDP Media Sources and/or virtual webcams.\n\n"
                    "TUI keys: c=copy OBS URL  s=copy log  l=cycle lens  t=torch\n"
                    "          z=zoom in  x=zoom out  k=kill slot  q=quit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--cameras",       type=int,  default=1,     metavar="N",
                   help="Number of camera slots to pre-create (default: 1, server.bat uses 4)")
    p.add_argument("--port",          type=int,  default=7070,  metavar="PORT",
                   help="Base SRT ingest port; slot i listens on PORT + i×3 (default: 7070)")
    p.add_argument("--obs-port",      type=int,  default=15000, metavar="PORT",
                   help="Base OBS UDP output port; slot i outputs on PORT + i×3 (default: 15000)")
    p.add_argument("--latency",       type=int,  default=80,    metavar="MS",
                   help="SRT receive latency in milliseconds (default: 80)")
    p.add_argument("--ffmpeg",        type=str,  default=None,  metavar="PATH",
                   help="Path to ffmpeg executable (default: ffmpeg from PATH)")
    p.add_argument("--direct-to-obs", action="store_true",
                   help="Skip relay — give OBS the raw SRT URL instead of a UDP relay")
    p.add_argument("--relay-to-obs",  action="store_true",
                   help="Force relay mode even if --direct-to-obs was previously set")
    p.add_argument("--obs-state-port", type=int, default=OBS_STATE_PORT, metavar="PORT",
                   help=f"Local HTTP port for the OBS auto-source script (default: {OBS_STATE_PORT})")
    p.add_argument("--no-obs-state-api", action="store_true",
                   help="Disable the local OBS auto-source state endpoint")
    args = p.parse_args()
    if args.relay_to_obs:
        args.direct_to_obs = False
    return args


if __name__ == "__main__":
    args = _parse_args()
    if not args.ffmpeg:
        import shutil
        args.ffmpeg = shutil.which("ffmpeg") or "ffmpeg"

    receiver = Receiver(args)

    def _sigint(_sig, _frame):  # type: ignore[no-untyped-def]
        receiver.stopping = True

    signal.signal(signal.SIGINT, _sigint)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _sigint)

    receiver.run()
