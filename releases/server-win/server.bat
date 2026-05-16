@echo off
title Project O Stream - Server

:: ---- If standalone exe exists, skip Python checks ----
if exist "%~dp0server.exe" goto check_vcam

python --version >nul 2>&1
if %errorlevel% neq 0 goto no_python

python -c "import textual" >nul 2>&1
if %errorlevel% neq 0 python -m pip install textual --quiet

:: ---- Locate Unity Capture DLLs ----
:check_vcam
set "DLL64=%~dp0UnityCaptureFilter64.dll"
if not exist "%DLL64%" set "DLL64=%~dp0UC\Install\UnityCaptureFilter64.dll"
set "DLL32=%~dp0UnityCaptureFilter32.dll"
if not exist "%DLL32%" set "DLL32=%~dp0UC\Install\UnityCaptureFilter32.dll"

if not exist "%DLL64%" goto no_vcam

:: ---- Require admin for Unity Capture dynamic registration ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [Unity Capture] Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

:: ---- Python vcam deps (script mode only) ----
if exist "%~dp0server.exe" goto vcam_unblock
python -c "import pyvirtualcam, numpy" >nul 2>&1
if %errorlevel% neq 0 python -m pip install pyvirtualcam numpy --quiet

:: ---- Unblock DLLs (SmartScreen / download mark) ----
:vcam_unblock
powershell -NoProfile -Command "Unblock-File -Path '%DLL64%' -ErrorAction SilentlyContinue"
if exist "%DLL32%" powershell -NoProfile -Command "Unblock-File -Path '%DLL32%' -ErrorAction SilentlyContinue"

:: Registration is handled dynamically by receiver.py on start/stop.

if exist "%~dp0server.exe" goto run_exe_vcam
python "%~dp0receiver.py" --cameras 4 --webcam %*
goto end

:run_exe_vcam
"%~dp0server.exe" --cameras 4 --webcam %*
goto end

:: ---- No DLLs found ----
:no_vcam
echo [info] Unity Capture DLLs not found - virtual webcam disabled.
echo [info] Place UC\Install\UnityCaptureFilter64.dll next to server.bat to enable.
if exist "%~dp0server.exe" goto run_exe_novcam
python "%~dp0receiver.py" %*
goto end

:run_exe_novcam
"%~dp0server.exe" %*
goto end

:: ---- No Python ----
:no_python
if exist "%~dp0server.exe" goto check_vcam
echo [ERROR] Python not found. Install Python 3.10+ from python.org
echo [ERROR] Or run build.bat to create server.exe (no Python needed at runtime).
pause

:end
