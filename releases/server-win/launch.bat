@echo off
title Project O Stream - Receiver

python --version >nul 2>&1
if %errorlevel% neq 0 goto no_python

python -c "import textual" >nul 2>&1
if %errorlevel% neq 0 python -m pip install textual --quiet

if not exist "%~dp0UnityCaptureFilter64.dll" goto no_vcam

python -c "import pyvirtualcam, numpy" >nul 2>&1
if %errorlevel% neq 0 python -m pip install pyvirtualcam numpy --quiet

regsvr32 /s "%~dp0UnityCaptureFilter64.dll" >nul 2>&1
if %errorlevel% neq 0 powershell -NoProfile -Command "Start-Process regsvr32 -Args '/s', '%~dp0UnityCaptureFilter64.dll' -Verb RunAs -Wait"

python receiver.py --webcam %*
goto end

:no_vcam
echo [info] UnityCaptureFilter64.dll not found - virtual webcam disabled.
echo [info] Get it from: https://github.com/schellingb/UnityCapture
python receiver.py %*
goto end

:no_python
echo [ERROR] Python not found. Install Python 3.10+ from python.org.
pause

:end
