#!/usr/bin/env python3
"""
Project-O Stream Receiver
Rich TUI entry-point that replaces start-receiver.ps1.

Requires: pip install rich
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
from datetime import datetime, timedelta
from typing import Callable, Optional

from rich.align import Align
from rich.columns import Columns
from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DISC_PORT       = 7071
DISC_PUSH_PORT  = 7072
TELE_PORT       = 7075
SLOT_TTL        = 120          # seconds
TELE_FRESH      = 20           # seconds — telemetry considered live
PROBE_BYTES     = b"PROJECTO_STREAM_DISCOVER"
LAN_PROBE_BYTES = b"PROJECTO_STREAM_LAN_PROBE"
LAN_ACK_BYTES   = b"PROJECTO_STREAM_LAN_ACK"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


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


def _infer_transport(ip: str) -> str:
    try:
        addr = ipaddress.ip_address(ip)
        if addr.is_private:
            # Tailscale uses 100.64/10 (CGNAT) range
            if str(addr).startswith("100."):
                return "tailscale"
            return "lan"
        return "wan"
    except ValueError:
        return "lan"


def _batt_bar(pct: float, width: int = 8) -> str:
    filled = round(pct * width)
    return "▮" * filled + "▯" * (width - filled)


def _check_ndi(ffmpeg_path: str) -> bool:
    try:
        result = subprocess.run(
            [ffmpeg_path, "-muxers"],
            capture_output=True, text=True, timeout=5
        )
        output = result.stdout + result.stderr
        return "libndi_newtek" in output
    except Exception:
        return False


def _open_firewall(port: int, proto: str = "UDP") -> None:
    rule_name = f"Project-O-Stream-{proto}-{port}"
    cmd_check = ["netsh", "advfirewall", "firewall", "show", "rule", f"name={rule_name}"]
    try:
        r = subprocess.run(cmd_check, capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return  # rule already exists
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
        self.index    = index
        self.srt_port = srt_port
        self.obs_port = obs_port
        # assigned IP
        self.ip: Optional[str] = None
        # telemetry
        self.hostname:     Optional[str]   = None
        self.battery:      Optional[float] = None
        self.charging:     bool            = False
        self.thermal:      Optional[str]   = None
        self.rtt_ms:       Optional[float] = None
        self.transport:    Optional[str]   = None
        self.tele_ts:      float           = 0.0
        # relay
        self.proc: Optional[subprocess.Popen] = None  # type: ignore[type-arg]

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
        self._count  = slot_count_fn
        self._grow   = grow_fn
        self._table: dict[str, tuple[int, float]] = {}  # ip -> (slot, last_seen)
        self._lock   = threading.Lock()

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


# ---------------------------------------------------------------------------
# Receiver application
# ---------------------------------------------------------------------------

class Receiver:
    def __init__(self, args: argparse.Namespace):
        self.args      = args
        self.start_ts  = time.time()
        self.stopping  = False

        # IPs
        self.lan_ip       = _lan_ip()
        self.tailscale_ip = _tailscale_ip()

        # Slots
        self.slots: list[SlotState] = []
        for i in range(args.cameras):
            self.slots.append(SlotState(
                index    = i,
                srt_port = args.port + i * 3,
                obs_port = args.obs_port + i * 3,
            ))

        self.assigner = SlotAssigner(
            slot_count_fn=lambda: len(self.slots),
            grow_fn=self._grow_slot,
        )

        self._selected = 0

        # FFmpeg
        self.ffmpeg_path = args.ffmpeg or "ffmpeg"
        self.ndi_available = False
        if args.ndi and not args.direct_to_obs:
            self.ndi_available = _check_ndi(self.ffmpeg_path)

        # Log ring-buffer
        self._log_lock = threading.Lock()
        self._log: list[tuple[str, str]] = []  # (timestamp, message)

        # Open firewall
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
            if len(self._log) > 10:
                self._log.pop(0)

    # ------------------------------------------------------------------ TUI

    def _build_header(self) -> Panel:
        now     = datetime.now().strftime("%H:%M:%S")
        uptime  = timedelta(seconds=int(time.time() - self.start_ts))
        hrs, rem = divmod(int(uptime.total_seconds()), 3600)
        mins, secs = divmod(rem, 60)
        up_str  = f"{hrs:02d}:{mins:02d}:{secs:02d}"

        connected = sum(1 for s in self.slots if s.connected)

        if self.args.direct_to_obs:
            mode_str = "direct-to-OBS"
        elif self.args.ndi and self.ndi_available:
            mode_str = "relay→OBS+NDI"
        else:
            mode_str = "relay→OBS"

        t = Text()
        t.append("● PROJECT-O STREAM RECEIVER", style="bold white")
        t.append(f"  {now}", style="white")
        t.append(f"  up {up_str}", style="dim white")
        t.append("  LAN ", style="dim white")
        t.append(self.lan_ip, style="cyan")
        if self.tailscale_ip:
            t.append("  Tailscale ", style="dim white")
            t.append(self.tailscale_ip, style="magenta")
        t.append(f"  slots {len(self.slots)}", style="dim white")
        t.append(f"  mode ", style="dim white")
        t.append(mode_str, style="yellow")
        t.append(f"  connected ", style="dim white")
        t.append(str(connected), style="green bold" if connected else "dim white")

        return Panel(Align.center(t), style="bold")

    def _build_cameras(self) -> Panel:
        tbl = Table(show_header=True, header_style="bold dim", box=None, padding=(0, 1))
        tbl.add_column("", width=2)          # cursor
        tbl.add_column("", width=2)          # dot
        tbl.add_column("CAM",    width=4)
        tbl.add_column("DEVICE", width=20)
        tbl.add_column("NETWORK", width=24)
        tbl.add_column("RTT",    width=8)
        tbl.add_column("BATTERY", width=14)
        tbl.add_column("THERMAL", width=8)
        tbl.add_column("OBS INPUT", width=28)

        sel = self._selected
        for s in self.slots:
            selected = (s.index == sel)
            row_style = "on grey23" if selected else ""
            cursor = Text("▶" if selected else " ", style="bold cyan" if selected else "dim")

            # dot
            dot = Text("●", style="green bold") if s.connected else Text("○", style="dim")

            # device
            if s.hostname:
                dev = Text(s.hostname, style="white")
            else:
                dev = Text("waiting…", style="dim italic")

            # network
            if s.ip and s.transport:
                net = Text(f"{s.transport}  {s.ip}", style="white")
            elif s.ip:
                net = Text(s.ip, style="white")
            else:
                net = Text(f"SRT :{s.srt_port}", style="dim")

            # RTT
            if s.tele_fresh and s.rtt_ms is not None:
                r = s.rtt_ms
                rtt_style = "green" if r < 20 else ("yellow" if r < 80 else "red")
                rtt = Text(f"{r:.0f}ms", style=rtt_style)
            else:
                rtt = Text("—", style="dim")

            # Battery
            if s.tele_fresh and s.battery is not None:
                pct = s.battery
                bar = _batt_bar(pct)
                chg = " ⚡" if s.charging else ""
                batt_style = "green" if pct >= 0.5 else ("yellow" if pct >= 0.2 else "red")
                batt = Text(f"{pct*100:.0f}% {bar}{chg}", style=batt_style)
            else:
                batt = Text("—", style="dim")

            # Thermal
            if s.tele_fresh and s.thermal:
                th_map = {
                    "nominal": ("OK",   "green"),
                    "fair":    ("WARM", "yellow"),
                    "serious": ("HOT",  "red"),
                    "critical":("CRIT", "bold red"),
                }
                label, style = th_map.get(s.thermal.lower(), (s.thermal[:4].upper(), "white"))
                thermal = Text(label, style=style)
            else:
                thermal = Text("—", style="dim")

            # OBS input
            obs_text = Text()
            if s.connected:
                obs_text.append(f"udp://127.0.0.1:{s.obs_port}", style="green")
            else:
                obs_text.append(f"udp://127.0.0.1:{s.obs_port}", style="dim")
            if self.args.ndi and self.ndi_available:
                obs_text.append(f"\nNDI: Project-O-Camera-{s.index + 1}", style="cyan dim")

            tbl.add_row(cursor, dot, str(s.index + 1), dev, net, rtt, batt, thermal, obs_text, style=row_style)

        return Panel(tbl, title="[bold]Cameras[/bold]")

    def _build_log(self) -> Panel:
        with self._log_lock:
            entries = list(self._log[-10:])
        t = Text()
        for ts, msg in entries:
            t.append(f"{ts} ", style="dim")
            t.append(f"{msg}\n", style="white")
        hint = Text("\n↑↓ select  ", style="dim")
        hint.append("k", style="bold cyan")
        hint.append(" kill slot  ", style="dim")
        hint.append("q", style="bold cyan")
        hint.append(" quit", style="dim")
        t.append_text(hint)
        return Panel(t, title="[bold]Log[/bold]")

    def _render(self) -> Columns:
        from rich.console import Group  # local import fine
        body = Group(
            self._build_header(),
            self._build_cameras(),
            self._build_log(),
        )
        return body  # type: ignore[return-value]

    # ------------------------------------------------------------------ workers

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
                slot_idx = self.assigner.get(client_ip)
                slot = self.slots[slot_idx]
                transport = _infer_transport(client_ip)
                offer = {
                    "service":     "project-o-stream",
                    "host":        self.tailscale_ip or self.lan_ip,
                    "hostname":    hostname,
                    "srtPort":     slot.srt_port,
                    "obsUdpPort":  slot.obs_port,
                    "transport":   transport,
                    "lanIp":       self.lan_ip,
                    "tailscaleIp": self.tailscale_ip,
                    "slotIndex":   slot_idx,
                    "totalSlots":  len(self.slots),
                }
                try:
                    sock.sendto(json.dumps(offer).encode(), addr)
                except Exception:
                    pass
                # update slot IP if not set
                if slot.ip != client_ip:
                    slot.ip = client_ip
                    slot.transport = transport
                    self._log_msg(f"Slot {slot_idx + 1} assigned to {client_ip} (SRT :{slot.srt_port})")

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

            slot_idx = self.assigner.lookup(client_ip)
            if slot_idx is None:
                slot_idx = self.assigner.get(client_ip)

            slot = self.slots[slot_idx]
            slot.ip         = client_ip
            slot.transport  = payload.get("transport") or _infer_transport(client_ip)
            slot.hostname   = payload.get("hostname") or slot.hostname
            slot.battery    = payload.get("battery",  slot.battery)
            slot.charging   = bool(payload.get("charging", slot.charging))
            slot.thermal    = payload.get("thermalState", slot.thermal)
            slot.rtt_ms     = payload.get("rttMs", slot.rtt_ms)
            slot.tele_ts    = time.time()

            batt_pct = f"{slot.battery*100:.0f}%" if slot.battery is not None else "?"
            self._log_msg(
                f"Tele [{slot.hostname or client_ip}] "
                f"batt={batt_pct} thermal={slot.thermal or '?'} rtt={slot.rtt_ms}ms"
            )

        sock.close()

    def _start_ffmpeg(self, slot: SlotState) -> "subprocess.Popen[bytes]":
        latency_us = self.args.latency * 1000
        input_url  = (
            f"srt://0.0.0.0:{slot.srt_port}"
            f"?mode=listener&transtype=live"
            f"&latency={latency_us}&rcvlatency={latency_us}&peerlatency={latency_us}"
            f"&tlpktdrop=1&pkt_size=1316"
        )
        target = f"udp://127.0.0.1:{slot.obs_port}?pkt_size=1316"
        cmd = [
            self.ffmpeg_path,
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer", "-flags", "low_delay",
            "-probesize", "32k", "-analyzeduration", "0",
            "-i", input_url,
            "-map", "0", "-c", "copy", "-f", "mpegts", target,
        ]
        if self.args.ndi and self.ndi_available:
            ndi_name = f"Project-O-Camera-{slot.index + 1}"
            cmd += [
                "-map", "0",
                "-vf", "format=uyvy422",
                "-c:a", "pcm_s16le",
                "-f", "libndi_newtek", ndi_name,
            ]
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _relay_worker_slot(self, slot: SlotState) -> None:
        ndi_note = f" + NDI: Project-O-Camera-{slot.index + 1}" if (self.args.ndi and self.ndi_available) else ""
        self._log_msg(f"Cam {slot.index + 1}: waiting on SRT :{slot.srt_port} → UDP :{slot.obs_port}{ndi_note}")
        while not self.stopping:
            try:
                slot.proc = self._start_ffmpeg(slot)
                slot.proc.wait()
                if self.stopping:
                    break
                code = slot.proc.returncode
                self._log_msg(f"Cam {slot.index + 1}: FFmpeg exited ({code}), restarting…")
                time.sleep(1)
            except Exception as e:
                self._log_msg(f"Cam {slot.index + 1}: relay error: {e}")
                time.sleep(2)

    def _relay_worker(self) -> None:
        if self.args.direct_to_obs:
            return
        started: set[int] = set()
        while not self.stopping:
            for slot in list(self.slots):
                if slot.index not in started:
                    started.add(slot.index)
                    t = threading.Thread(
                        target=self._relay_worker_slot,
                        args=(slot,),
                        daemon=True,
                        name=f"relay-{slot.index}",
                    )
                    t.start()
            time.sleep(0.5)

    # ------------------------------------------------------------------ keyboard

    def _input_worker(self) -> None:
        try:
            import msvcrt
        except ImportError:
            return  # non-Windows
        while not self.stopping:
            if not msvcrt.kbhit():
                time.sleep(0.05)
                continue
            ch = msvcrt.getwch()
            if ch in ('\x00', '\xe0'):  # arrow key prefix
                ch2 = msvcrt.getwch()
                if ch2 == 'H':    # up
                    self._selected = max(0, self._selected - 1)
                elif ch2 == 'P':  # down
                    self._selected = min(len(self.slots) - 1, self._selected + 1)
            elif ch in ('k', 'K'):
                if 0 <= self._selected < len(self.slots):
                    slot = self.slots[self._selected]
                    if slot.proc and slot.proc.poll() is None:
                        try:
                            slot.proc.kill()
                            self._log_msg(f"Cam {slot.index + 1}: killed by user")
                        except Exception as e:
                            self._log_msg(f"Cam {slot.index + 1}: kill failed: {e}")
                    else:
                        self._log_msg(f"Cam {slot.index + 1}: not running")
            elif ch in ('q', 'Q', '\x03'):  # q or Ctrl+C
                self.stopping = True

    # ------------------------------------------------------------------ run

    def run(self) -> None:
        if self.args.ndi:
            if self.ndi_available:
                self._log_msg("NDI: enabled (libndi_newtek found)")
            else:
                self._log_msg("NDI: disabled — need NDI-enabled FFmpeg (github.com/valnoxy/ndi-ffmpeg-build)")

        threads = [
            threading.Thread(target=self._discovery_worker, daemon=True, name="discovery"),
            threading.Thread(target=self._telemetry_worker, daemon=True, name="telemetry"),
            threading.Thread(target=self._relay_worker,    daemon=True, name="relay"),
            threading.Thread(target=self._input_worker,    daemon=True, name="input"),
        ]
        for t in threads:
            t.start()

        console = Console()
        try:
            with Live(
                self._render(),
                console=console,
                refresh_per_second=4,
                screen=True,
            ) as live:
                while not self.stopping:
                    live.update(self._render())
                    time.sleep(0.25)
        except KeyboardInterrupt:
            pass
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
        sys.exit(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Project-O Stream Receiver — Rich TUI"
    )
    p.add_argument("--cameras",       type=int,  default=1,      metavar="N",    help="Number of camera slots")
    p.add_argument("--port",          type=int,  default=7070,   metavar="PORT", help="Base SRT port (default 7070)")
    p.add_argument("--obs-port",      type=int,  default=15000,  metavar="PORT", help="Base OBS UDP port (default 15000)")
    p.add_argument("--latency",       type=int,  default=80,     metavar="MS",   help="SRT latency in ms (default 80)")
    p.add_argument("--ffmpeg",        type=str,  default=None,   metavar="PATH", help="Path to ffmpeg binary")
    p.add_argument("--direct-to-obs", action="store_true",                       help="No relay; phones connect directly to OBS")
    p.add_argument("--ndi",           action="store_true",                       help="Also output NDI stream per camera")
    return p.parse_args()


if __name__ == "__main__":
    # Resolve ffmpeg from PATH if not given
    args = _parse_args()
    if not args.ffmpeg:
        import shutil
        args.ffmpeg = shutil.which("ffmpeg") or "ffmpeg"

    receiver = Receiver(args)

    # Handle Ctrl+C via signal for non-terminal environments
    def _sigint(_sig, _frame):  # type: ignore[no-untyped-def]
        receiver.stopping = True

    signal.signal(signal.SIGINT, _sigint)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _sigint)

    receiver.run()
