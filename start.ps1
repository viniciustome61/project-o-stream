param(
    [int]$SrtPort      = 7070,
    [int]$ObsUdpPort   = 15000,
    [int]$ObsStatePort = 7077,
    [int]$LatencyMs    = 80,
    [int]$Cameras      = 1,
    [string]$Ffmpeg    = "",
    [switch]$DirectToObs,
    [switch]$RelayToObs,
    [switch]$NoObsStateApi,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Get-Location }

# ---- Go toolchain -----------------------------------------------------------
$exePath = Join-Path $repoRoot "bin\receiver.exe"

if (-not $SkipBuild) {
    $go = Get-Command go -ErrorAction SilentlyContinue
    if (-not $go) {
        Write-Error "Go not found. Install Go 1.26+ and add it to PATH."
        exit 1
    }

    Write-Host "[launcher] Building Go receiver..."
    New-Item -ItemType Directory -Force (Join-Path $repoRoot "bin") | Out-Null
    Push-Location $repoRoot
    try {
        & go build -o $exePath .
        if ($LASTEXITCODE -ne 0) {
            Write-Error "go build failed."
            exit 1
        }
    }
    finally { Pop-Location }
    Write-Host "[launcher] Build OK: $exePath"
}

if (-not (Test-Path $exePath)) {
    Write-Error "Receiver binary not found at: $exePath (run without -SkipBuild to build it)"
    exit 1
}

# ---- firewall (best effort) -------------------------------------------------
# Windows Firewall silently drops inbound UDP (discovery 7071, telemetry 7075,
# SRT ingest) for a new binary. Rule creation needs admin; skip quietly if not.
$fwRule = "Project O Stream Go Receiver"
try {
    $existing = netsh advfirewall firewall show rule name="$fwRule" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existing) {
        netsh advfirewall firewall add rule name="$fwRule" dir=in action=allow program="$exePath" enable=yes | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "[launcher] Firewall rule added for receiver.exe" }
        else { Write-Host "[launcher] Could not add firewall rule (run once as admin if the phone can't discover the PC)" }
    }
}
catch { Write-Host "[launcher] Firewall check skipped: $_" }

# ---- build args for the Go receiver ----------------------------------------
$goArgs = @(
    "--cameras",        $Cameras,
    "--port",           $SrtPort,
    "--obs-port",       $ObsUdpPort,
    "--obs-state-port", $ObsStatePort,
    "--latency",        $LatencyMs
)
if ($Ffmpeg)        { $goArgs += @("--ffmpeg", $Ffmpeg) }
if ($DirectToObs)   { $goArgs += "--direct-to-obs" }
if ($RelayToObs)    { $goArgs += "--relay-to-obs" }
if ($NoObsStateApi) { $goArgs += "--no-obs-state-api" }

# ---- launch -----------------------------------------------------------------
Write-Host "[launcher] Starting Go receiver (TUI)..."
& $exePath @goArgs
exit $LASTEXITCODE
