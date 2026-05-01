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
