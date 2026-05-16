@echo off
title Project O Stream - Receiver
cd /d "%~dp0"

:: ---- Python ----------------------------------------------------------------
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Python not found. Install Python 3.10+ from python.org and add it to PATH.
    pause & exit /b 1
)

:: ---- textual ---------------------------------------------------------------
python -c "import textual" >nul 2>&1
if %errorlevel% neq 0 (
    echo Installing textual, please wait...
    python -m pip install textual --quiet
    if %errorlevel% neq 0 (
        echo [ERROR] pip install textual failed. Run manually: pip install textual
        pause & exit /b 1
    )
)

:: ---- webcam driver + deps --------------------------------------------------
set WEBCAM_FLAG=
if exist "%~dp0\UnityCaptureFilter64bit.dll" (
    :: Install Python deps for webcam output
    python -c "import pyvirtualcam, numpy" >nul 2>&1
    if %errorlevel% neq 0 (
        echo Installing webcam output dependencies (pyvirtualcam, numpy)...
        python -m pip install pyvirtualcam numpy --quiet
    )

    :: Register the DLL (idempotent). Try without elevation first; escalate if denied.
    regsvr32 /s "%~dp0\UnityCaptureFilter64bit.dll" >nul 2>&1
    if %errorlevel% neq 0 (
        echo [setup] Registering Unity Capture webcam driver (admin required once)...
        powershell -Command "Start-Process regsvr32 -ArgumentList '/s', '\"%~dp0\UnityCaptureFilter64bit.dll\"' -Verb RunAs -Wait" >nul 2>&1
    )

    set WEBCAM_FLAG=--webcam
) else (
    echo [info] UnityCaptureFilter64bit.dll not found - virtual webcam output disabled.
    echo        Place UnityCaptureFilter64bit.dll next to this file to enable webcam output.
    echo        Get it from: https://github.com/schellingb/UnityCapture
    echo.
)

:: ---- launch ----------------------------------------------------------------
python receiver.py %WEBCAM_FLAG% %*
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] receiver.py exited with code %errorlevel%
    pause
)
