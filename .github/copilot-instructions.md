# Copilot Instructions for Project O Stream

## Build, Test, and Lint Commands

### Flutter (Mobile - `main` branch)

**Get dependencies:**
```bash
flutter pub get
```

**Lint and analyze:**
```bash
flutter analyze
```

**Build debug APK (Android):**
```bash
flutter build apk --debug
```

**Build release IPA (iOS, unsigned):**
```bash
flutter build ios --release --no-codesign
```

**Clean and rebuild:**
```bash
flutter clean && flutter pub get
```

**Testing:** The Flutter project currently has no automated tests configured. Tests can be added to `test/` directory and run with `flutter test`.

### Desktop (Tauri + Svelte - `desktop/tauri-svelte` branch)

**Development mode (runs dev server):**
```powershell
cd desktop
npm install
npm run tauri dev
```

**Build release:**
```powershell
cd desktop
npm run tauri build
```

### Server/Operations (PowerShell scripts)

**Start receiver:**
```powershell
.\server\start-receiver.ps1
```

**Check workstation health:**
```powershell
.\ops\doctor.ps1
```

**Launch OBS:**
```powershell
.\ops\launch-obs.ps1
```

## High-Level Architecture

**Goal:** Low-latency, high-quality phone camera ingest into OBS over private Tailscale network.

**Core Components:**
- **Mobile App** (`lib/`, `android/`, `ios/`): Flutter UI with native camera and encoder bridges for Android/iOS
- **Desktop Controller** (`desktop/`): Tauri + Svelte + Rust interface to start/stop receiver and monitor status
- **Receiver** (`server/`): Python script that listens for SRT streams and forwards to OBS via UDP
- **Operations** (`ops/`): PowerShell scripts for workstation setup, health checks, and OBS launch

**Media Path:**
```
Mobile camera
  → hardware H.264/H.265 encoder (device-native)
  → SRT stream over Tailscale
  → PC receiver (remux to MPEG-TS)
  → UDP://127.0.0.1:15000
  → OBS Media Source
```

**Discovery Path:**
```
Mobile UDP probe on port 7071
  → PC UDP offer pulse on port 7072 (to online Tailscale peers)
```

**SRT Listener:** `srt://0.0.0.0:7070` (customizable via `-SrtPort` parameter)

## Key Conventions

### Branch Strategy
- **`main`**: Mobile app only (Flutter for Android/iOS). All camera, encoder, and mobile platform changes go here.
- **`desktop/tauri-svelte`**: Desktop-only branch. UI controller, Tauri runtime, Svelte/SvelteKit, Rust, and Windows packaging changes belong here. Mobile changes should NOT be made on this branch.
- **Repository root is the canonical Flutter project root** - all CI tasks assume Flutter project root at repository root.

### Design Rules
- **Native APIs exclusively** - use platform-native camera APIs (not cross-platform wrappers)
- **Hardware encoding** - prefer device-native H.264/H.265 encoders (no software encoding)
- **Tailscale as network layer only** - keep it isolated to networking; business logic doesn't depend on Tailscale specifics
- **Single production media path** - SRT in, MPEG-TS UDP out; avoid multiple incompatible paths
- **Native sensor orientation** - prefer native orientation handling over frame transforms

### Linting and Code Style
- **Flutter linting rules** (enforced by `analysis_options.yaml`):
  - Use single quotes (`'string'` not `"string"`)
  - Avoid `print()` statements (use structured logging instead)
  - Follow `flutter_lints` package rules
  
- **Run linting:** `flutter analyze`

### Project Dependencies
- **Flutter version:** 3.41.8 (see `.github/workflows/` for current CI version)
- **iOS requirement:** physical-device target (not simulator) due to camera/SRT native code
- **Android Gradle:** intentionally does NOT use `dependencyResolutionManagement` - Flutter injects local engine Maven repository at project level
- **Desktop Node:** Node 22 (see `combined-release.yml`)

### CI/Release Process
- **Debug builds** explicitly disable resource shrinking/minification for faster turnaround
- **iOS signing** not configured in CI workflow - currently produces unsigned `.ipa` artifacts
- **Release artifacts** created from `v*` tags (e.g., `v3.0.0`)
- **Manual dispatch** for releases requires explicit tag to prevent accidental releases from `main`

### MCP Servers

**Sideloadly MCP Server** (already configured)
- Location: `MCP/sideloadly_mcp_server.py`
- Configured in: `.vscode/mcp.json`
- Exposes: latest IPA discovery, Sideloadly launch, log tailing

**GitHub API MCP Server** (recommended)
- Useful for: Issue/PR automation, checking CI status, release management
- Setup: Configure in VS Code's MCP settings to enable GitHub integration

**Python Execution MCP Server** (recommended)
- Useful for: Testing and debugging `server/receiver.py`, custom MCP development
- Setup: Configure in VS Code's MCP settings to enable Python script execution

**Common setup:**
```powershell
pip install mcp
```

Reference: MCP server setup docs at https://modelcontextprotocol.io/

## Related Documentation

For deeper context on specific areas, consult:
- `docs/ARCHITECTURE.md` - media path, discovery protocol, design rules
- `docs/CI.md` - GitHub Actions workflow details
- `docs/DEPLOYMENT.md` - release and deployment procedures
- `ops/README.md` - workstation ops, receiver health checks
- `server/README.md` - receiver parameters and port configuration
- `desktop/README.md` - Tauri build and development
