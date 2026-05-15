param(
    [int]$SrtPort    = 7070,
    [int]$ObsUdpPort = 15000,
    [int]$LatencyMs  = 80,
    [int]$Cameras    = 1,
    [switch]$DirectToObs,
    [switch]$Ndi,
    [switch]$NoDiscovery
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = Get-Location }

# ---- Python ----------------------------------------------------------------
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Error "Python not found. Install Python 3.10+ and add it to PATH."
    exit 1
}

# ---- textual ---------------------------------------------------------------
$checkTextual = & python -c "import textual" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[launcher] textual not installed - installing..."
    & python -m pip install textual --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install textual. Run: pip install textual"
        exit 1
    }
    Write-Host "[launcher] textual installed."
}

# ---- build args for receiver.py -------------------------------------------
$receiverPy = Join-Path $scriptRoot "receiver.py"
if (-not (Test-Path $receiverPy)) {
    Write-Error "receiver.py not found at: $receiverPy"
    exit 1
}

$pyArgs = @(
    $receiverPy,
    "--cameras",  $Cameras,
    "--port",     $SrtPort,
    "--obs-port", $ObsUdpPort,
    "--latency",  $LatencyMs
)
if ($DirectToObs) { $pyArgs += "--direct-to-obs" }
if ($Ndi)         { $pyArgs += "--ndi" }

# ---- launch ----------------------------------------------------------------
Write-Host "[launcher] Starting receiver (Textual TUI)..."
& python @pyArgs
