# Project O Stream Desktop

This directory is desktop-only.

- Desktop branch: `desktop/tauri-svelte`
- Mobile branch: `main`
- Desktop stack: Tauri 2, SvelteKit, TypeScript, Rust
- Version: 3.0.0

Do not use this branch as the mobile baseline. Flutter Android/iOS changes belong on `main`; Tauri, Svelte, Rust desktop-shell, and desktop packaging changes belong here.

## 3.0 Features

- Start and stop the receiver from the desktop UI.
- Poll receiver status through native Tauri commands.
- Show Tailscale IP, SRT port, OBS UDP port, and discovery ports.
- Run the workstation doctor and display its output in the operational log.
- Launch OBS through the existing operator script.

## Development

```powershell
cd desktop
npm install
npm run tauri dev
```

## Build

```powershell
cd desktop
npm run tauri build
```
