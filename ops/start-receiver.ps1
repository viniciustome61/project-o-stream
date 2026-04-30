$repoRoot = Split-Path $PSScriptRoot -Parent
& (Join-Path $repoRoot "server\start-receiver.ps1") @args
