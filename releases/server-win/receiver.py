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
from datetime import datetime, timedelta
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
SLOT_TTL        = 120
TELE_FRESH      = 20
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
        return "libndi_newtek" in (result.stdout + result.stderr)
    except Exception:
        return False


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
        self.index    = index
        self.srt_port = srt_port
        self.obs_port = obs_port
        self.ip: Optional[str] = None
        self.hostname:  Optional[str]   = None
        self.battery:   Optional[float] = None
        self.charging:  bool            = False
        self.thermal:   Optional[str]   = None
        self.rtt_ms:    Optional[float] = None
        self.transport: Optional[str]   = None
        self.tele_ts:   float           = 0.0
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


# ---------------------------------------------------------------------------
# Receiver — data model + workers
# ---------------------------------------------------------------------------

class Receiver:
    def __init__(self, args: argparse.Namespace):
        self.args     = args
        self.start_ts = time.time()
        self.stopping = False

        self.lan_ip       = _lan_ip()
        self.tailscale_ip = _tailscale_ip()

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

        self.ffmpeg_path   = args.ffmpeg or "ffmpeg"
        self.ndi_available = False
        if args.ndi and not args.direct_to_obs:
            self.ndi_available = _check_ndi(self.ffmpeg_path)

        self._log_lock = threading.Lock()
        self._log: list[tuple[str, str]] = []
        self._app: Optional["ReceiverApp"] = None

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
        if self._app is not None:
            try:
                self._app.call_from_thread(self._app.push_log, ts, msg)
            except Exception:
                pass

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
                slot_idx  = self.assigner.get(client_ip)
                slot      = self.slots[slot_idx]
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
                if slot.ip != client_ip:
                    slot.ip        = client_ip
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

            slot            = self.slots[slot_idx]
            slot.ip         = client_ip
            slot.transport  = payload.get("transport") or _infer_transport(client_ip)
            slot.hostname   = payload.get("hostname") or slot.hostname
            slot.battery    = payload.get("battery",     slot.battery)
            slot.charging   = bool(payload.get("charging", slot.charging))
            slot.thermal    = payload.get("thermalState", slot.thermal)
            slot.rtt_ms     = payload.get("rttMs",        slot.rtt_ms)
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
            cmd += ["-map", "0", "-vf", "format=uyvy422", "-c:a", "pcm_s16le", "-f", "libndi_newtek", ndi_name]
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def _relay_worker_slot(self, slot: SlotState) -> None:
        ndi_note = f" + NDI: Project-O-Camera-{slot.index + 1}" if (self.args.ndi and self.ndi_available) else ""
        self._log_msg(f"Cam {slot.index + 1}: waiting on SRT :{slot.srt_port} -> UDP :{slot.obs_port}{ndi_note}")
        backoff = 1.0
        while not self.stopping:
            try:
                t0 = time.time()
                slot.proc = self._start_ffmpeg(slot)
                slot.proc.wait()
                if self.stopping:
                    break
                elapsed = time.time() - t0
                code    = slot.proc.returncode
                # grab last stderr line for context
                stderr_tail = ""
                if slot.proc.stderr:
                    raw = slot.proc.stderr.read().decode("utf-8", errors="replace").strip()
                    last = [l.strip() for l in raw.splitlines() if l.strip()]
                    if last:
                        stderr_tail = f": {last[-1][:120]}"
                if elapsed < 3.0:
                    # fast exit = startup failure; back off to avoid log flood
                    backoff = min(backoff * 2, 30.0)
                    self._log_msg(
                        f"Cam {slot.index + 1}: FFmpeg failed ({code}){stderr_tail} - retry in {backoff:.0f}s"
                    )
                else:
                    backoff = 1.0
                    self._log_msg(f"Cam {slot.index + 1}: FFmpeg exited ({code}), restarting...")
                time.sleep(backoff)
            except Exception as e:
                self._log_msg(f"Cam {slot.index + 1}: relay error: {e}")
                backoff = min(backoff * 2, 30.0)
                time.sleep(backoff)

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

    # ------------------------------------------------------------------ run / shutdown

    def run(self) -> None:
        if self.args.ndi:
            self._log_msg(
                "NDI: enabled (libndi_newtek found)" if self.ndi_available
                else "NDI: disabled — need NDI-enabled FFmpeg (github.com/valnoxy/ndi-ffmpeg-build)"
            )

        for target, name in [
            (self._discovery_worker, "discovery"),
            (self._telemetry_worker, "telemetry"),
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
        sys.exit(0)


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
        Binding("k",      "kill_slot", "Kill slot", show=True),
        Binding("q",      "quit_app",  "Quit",      show=True),
        Binding("ctrl+c", "quit_app",  "Quit",      show=False),
    ]

    def __init__(self, receiver: Receiver) -> None:
        super().__init__()
        self._receiver    = receiver
        self._col_keys: list = []
        self._known_slots: set[int] = set()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield DataTable(id="cameras", cursor_type="row", zebra_stripes=True)
        yield RichLog(id="log", highlight=True, markup=True, max_lines=200)
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        self._col_keys = list(table.add_columns(
            "●", "CAM", "DEVICE", "NETWORK", "RTT", "BATTERY", "THERMAL", "OBS INPUT"
        ))
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

        obs = Text()
        obs.append(f"udp://127.0.0.1:{s.obs_port}",
                   style="green" if s.connected else "dim")
        if self._receiver.args.ndi and self._receiver.ndi_available:
            obs.append(f"  NDI: Project-O-Camera-{s.index + 1}", style="cyan dim")

        return (dot, str(s.index + 1), dev, net, rtt, batt, thermal, obs)

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
                        table.update_cell(str(slot.index), self._col_keys[col_idx], val)
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
        mode      = (
            "direct-to-OBS" if r.args.direct_to_obs else
            "relay→OBS+NDI"  if (r.args.ndi and r.ndi_available) else
            "relay→OBS"
        )
        ts_part = f"  Tailscale {r.tailscale_ip}" if r.tailscale_ip else ""
        conn_indicator = "🟢" if connected else "○"
        self.sub_title = (
            f"up {uptime}  LAN {r.lan_ip}{ts_part}  "
            f"slots {len(r.slots)}  {mode}  "
            f"connected {conn_indicator} {connected}"
        )

    # ------------------------------------------------------------------ log

    def push_log(self, ts: str, msg: str) -> None:
        self.query_one(RichLog).write(f"[dim]{ts}[/dim] {msg}")

    # ------------------------------------------------------------------ actions

    def action_kill_slot(self) -> None:
        table   = self.query_one(DataTable)
        row_idx = table.cursor_row
        slots   = self._receiver.slots
        if 0 <= row_idx < len(slots):
            slot = slots[row_idx]
            if slot.proc and slot.proc.poll() is None:
                try:
                    slot.proc.kill()
                    self._receiver._log_msg(f"Cam {slot.index + 1}: killed by user")
                except Exception as e:
                    self._receiver._log_msg(f"Cam {slot.index + 1}: kill failed: {e}")
            else:
                self._receiver._log_msg(f"Cam {slot.index + 1}: not running")

    def action_quit_app(self) -> None:
        self._receiver.stopping = True
        self.exit()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Project-O Stream Receiver — Textual TUI")
    p.add_argument("--cameras",       type=int,  default=1,     metavar="N")
    p.add_argument("--port",          type=int,  default=7070,  metavar="PORT")
    p.add_argument("--obs-port",      type=int,  default=15000, metavar="PORT")
    p.add_argument("--latency",       type=int,  default=80,    metavar="MS")
    p.add_argument("--ffmpeg",        type=str,  default=None,  metavar="PATH")
    p.add_argument("--direct-to-obs", action="store_true")
    p.add_argument("--ndi",           action="store_true")
    return p.parse_args()


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
