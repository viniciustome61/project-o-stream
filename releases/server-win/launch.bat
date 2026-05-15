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
    python -m pip install textual
    if %errorlevel% neq 0 (
        echo [ERROR] pip install textual failed. Run manually: pip install textual
        pause & exit /b 1
    )
)

:: ---- launch ----------------------------------------------------------------
python receiver.py %*
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] receiver.py exited with code %errorlevel%
    pause
)
