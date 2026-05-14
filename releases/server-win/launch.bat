@echo off
title Project O Stream - Receiver

:: Re-launch as administrator if not already elevated
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-receiver.ps1" -DirectToObs %*
if %errorlevel% neq 0 pause
