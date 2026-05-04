# Ops

Operational scripts for local workstation setup.

## Branch Scope

- `main` remains the mobile app branch.
- `desktop/tauri-svelte` is desktop-only for the Tauri + Svelte controller and desktop packaging.

Keep mobile automation on `main`; keep desktop runtime/operator changes that support the Tauri shell on this branch.

## Doctor

Project O Stream 3.0 includes a workstation doctor that checks tools, Tailscale, receiver ports, and structured receiver health.

```powershell
.\ops\doctor.ps1
```

## OBS

```powershell
.\ops\launch-obs.ps1
```

## Sideloadly MCP Server

A local MCP server is available at `MCP/sideloadly_mcp_server.py` for IPA handoff to Sideloadly.

### What it exposes

- `get_latest_ipa_path`: returns the newest `.ipa` in `releases/`
- `launch_sideloadly_install`: opens `C:\Sideloadly\Sideloadly.exe` with an IPA path
- `tail_sideloadly_logs`: reads the newest Sideloadly log tail from `%APPDATA%\Sideloadly`

### Setup

```powershell
pip install mcp
```

The workspace MCP config is in `.vscode/mcp.json` and points to this server over stdio.
