$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$obsExe = Join-Path $repoRoot "vendor\obs-portable\bin\64bit\obs64.exe"
if (-not (Test-Path $obsExe)) {
    Write-Host "OBS executable not found at $obsExe"
    exit 1
}

Start-Process -FilePath $obsExe -WorkingDirectory (Split-Path $obsExe)
