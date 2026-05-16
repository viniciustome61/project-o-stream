@echo off
title Project O Stream - Server

:: ---- If standalone exe exists, skip Python checks ----
if exist "%~dp0server.exe" goto install_deps_done

python --version >nul 2>&1
if %errorlevel% neq 0 goto no_python

python -c "import textual" >nul 2>&1
if %errorlevel% neq 0 python -m pip install textual --quiet

python -c "import pyvirtualcam, numpy" >nul 2>&1
if %errorlevel% neq 0 python -m pip install pyvirtualcam numpy --quiet

:install_deps_done

:: ---- Optional: unblock Unity Capture DLLs if present ----
:: Unity Capture is NOT required. It is used only when you press M to cycle
:: the relay mode to VCAM. Slot 0 uses OBS Virtual Camera by default.
:: For multi-camera virtual output use the --ndi flag (see NDI Tools at ndi.video).
set "DLL64=%~dp0UnityCaptureFilter64.dll"
if not exist "%DLL64%" set "DLL64=%~dp0UC\Install\UnityCaptureFilter64.dll"
set "DLL32=%~dp0UnityCaptureFilter32.dll"
if not exist "%DLL32%" set "DLL32=%~dp0UC\Install\UnityCaptureFilter32.dll"

if exist "%DLL64%" (
    powershell -NoProfile -Command "Unblock-File -Path '%DLL64%' -ErrorAction SilentlyContinue"
    if exist "%DLL32%" powershell -NoProfile -Command "Unblock-File -Path '%DLL32%' -ErrorAction SilentlyContinue"
)

:: ---- Launch ----
if exist "%~dp0server.exe" goto run_exe
python "%~dp0receiver.py" --cameras 4 --webcam %*
goto end

:run_exe
"%~dp0server.exe" --cameras 4 --webcam %*
goto end

:: ---- No Python ----
:no_python
if exist "%~dp0server.exe" goto install_deps_done
echo [ERROR] Python not found. Install Python 3.10+ from python.org
echo [ERROR] Or run build.bat to create server.exe (no Python needed at runtime).
pause

:end
