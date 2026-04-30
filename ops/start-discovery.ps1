$repoRoot = Split-Path $PSScriptRoot -Parent
& (Join-Path $repoRoot "server\discovery-server.ps1") @args
