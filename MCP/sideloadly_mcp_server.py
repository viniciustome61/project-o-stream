#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP


mcp = FastMCP("sideloadly")
REPO_ROOT = Path(__file__).resolve().parents[1]


def _default_releases_dir() -> Path:
    env_path = os.getenv("IPA_RELEASES_DIR")
    if env_path:
        return Path(env_path)
    return REPO_ROOT / "releases"


def _default_sideloadly_exe() -> Path:
    env_path = os.getenv("SIDELOADLY_EXE")
    if env_path:
        return Path(env_path)
    return Path(r"C:\Sideloadly\Sideloadly.exe")


def _latest_ipa(releases_dir: Path) -> Path:
    if not releases_dir.exists():
        raise FileNotFoundError(f"Releases directory not found: {releases_dir}")

    ipa_files = sorted(
        [p for p in releases_dir.rglob("*.ipa") if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not ipa_files:
        raise FileNotFoundError(f"No .ipa files found under: {releases_dir}")
    return ipa_files[0]


def _default_log_root() -> Path:
    appdata = os.getenv("APPDATA")
    if appdata:
        return Path(appdata) / "Sideloadly"
    return Path.home() / "AppData" / "Roaming" / "Sideloadly"


@mcp.tool()
def get_latest_ipa_path(releases_dir: str = "") -> dict:
    """Return the newest IPA path from releases/."""
    root = Path(releases_dir) if releases_dir else _default_releases_dir()
    ipa = _latest_ipa(root)
    return {"ipa_path": str(ipa), "releases_dir": str(root)}


@mcp.tool()
def launch_sideloadly_install(
    ipa_path: str = "",
    sideloadly_exe: str = "",
    additional_args: str = "",
) -> dict:
    """Launch Sideloadly with an IPA path so user can sign/install with connected iPhone."""
    exe = Path(sideloadly_exe) if sideloadly_exe else _default_sideloadly_exe()
    if not exe.exists():
        raise FileNotFoundError(f"Sideloadly executable not found: {exe}")

    if ipa_path:
        ipa = Path(ipa_path)
    else:
        ipa = _latest_ipa(_default_releases_dir())
    if not ipa.exists():
        raise FileNotFoundError(f"IPA not found: {ipa}")

    cmd = [str(exe), str(ipa)]
    if additional_args.strip():
        cmd.extend(additional_args.split())

    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP

    process = subprocess.Popen(cmd, creationflags=creationflags)
    return {
        "launched": True,
        "pid": process.pid,
        "command": cmd,
        "note": "Sideloadly UI is now running. Complete signing/install in its window.",
    }


@mcp.tool()
def tail_sideloadly_logs(lines: int = 200, log_root: str = "") -> dict:
    """Read tail output from the newest Sideloadly .log file."""
    root = Path(log_root) if log_root else _default_log_root()
    if not root.exists():
        raise FileNotFoundError(f"Sideloadly log directory not found: {root}")

    logs = sorted(
        [p for p in root.rglob("*.log") if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not logs:
        raise FileNotFoundError(f"No log files found in: {root}")

    newest = logs[0]
    with newest.open("r", encoding="utf-8", errors="replace") as f:
        content = f.readlines()
    tail = "".join(content[-max(1, lines) :])
    return {"log_file": str(newest), "tail": tail}


if __name__ == "__main__":
    mcp.run()
