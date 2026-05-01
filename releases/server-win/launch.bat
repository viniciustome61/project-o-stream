@echo off
title Project O Stream - Receiver
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-receiver.ps1" %*
if %errorlevel% neq 0 pause
pause