@echo off
title Build receiver.exe

echo [build] Installing PyInstaller...
python -m pip install pyinstaller --quiet --no-cache-dir --no-warn-script-location

echo [build] Building server.exe (this takes ~30 seconds)...
python -m PyInstaller ^
    --onefile ^
    --clean ^
    --name server ^
    --collect-all textual ^
    --collect-all pyvirtualcam ^
    --hidden-import=pyvirtualcam ^
    --hidden-import=numpy ^
    --noconfirm ^
    "%~dp0receiver.py"

if %errorlevel% neq 0 (
    echo [ERROR] Build failed.
    pause
    goto end
)

copy /Y "%~dp0dist\server.exe" "%~dp0server.exe" >nul
echo [build] Cleaning up...
rmdir /S /Q "%~dp0dist" >nul 2>&1
rmdir /S /Q "%~dp0build" >nul 2>&1
del /Q "%~dp0server.spec" >nul 2>&1

echo.
echo [done] server.exe is ready. Run server.bat to launch.

:end
pause
