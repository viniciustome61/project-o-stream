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

:: ---- Python vcam deps (script mode only) ----
if exist "%~dp0server.exe" goto vcam_reg
python -c "import pyvirtualcam, numpy" >nul 2>&1
if %errorlevel% neq 0 python -m pip install pyvirtualcam numpy --quiet

:: ---- Register Unity Capture DLLs + create 4 virtual devices ----
:vcam_reg
powershell -NoProfile -Command "Unblock-File -Path '%DLL64%' -ErrorAction SilentlyContinue"
if exist "%DLL32%" powershell -NoProfile -Command "Unblock-File -Path '%DLL32%' -ErrorAction SilentlyContinue"

set "VCAM_OK=0"
%SystemRoot%\System32\regsvr32.exe /s /i:"UnityCaptureDevices=4" "%DLL64%" >nul 2>&1
if %errorlevel% equ 0 set "VCAM_OK=1"
if exist "%DLL32%" %SystemRoot%\SysWOW64\regsvr32.exe /s /i:"UnityCaptureDevices=4" "%DLL32%" >nul 2>&1

if "%VCAM_OK%"=="1" goto vcam_ok

:: Non-elevated registration failed - create a temp script and elevate it
echo @echo off > "%TEMP%\uc_register.bat"
echo "%SystemRoot%\System32\regsvr32.exe" /s /i:"UnityCaptureDevices=4" "%DLL64%" >> "%TEMP%\uc_register.bat"
if exist "%DLL32%" echo "%SystemRoot%\SysWOW64\regsvr32.exe" /s /i:"UnityCaptureDevices=4" "%DLL32%" >> "%TEMP%\uc_register.bat"
powershell -NoProfile -Command "Start-Process '%TEMP%\uc_register.bat' -Verb RunAs -Wait" >nul 2>&1
del "%TEMP%\uc_register.bat" >nul 2>&1

:: Verify elevation succeeded
set "VCAM_OK=0"
%SystemRoot%\System32\regsvr32.exe /s /i:"UnityCaptureDevices=4" "%DLL64%" >nul 2>&1
if %errorlevel% equ 0 set "VCAM_OK=1"
if "%VCAM_OK%"=="0" echo [warn] Unity Capture registration failed.
if "%VCAM_OK%"=="0" echo [warn] If virtual webcam is missing, install VC++ 2022 x64:
if "%VCAM_OK%"=="0" echo [warn]   https://aka.ms/vs/17/release/vc_redist.x64.exe

:vcam_ok
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
