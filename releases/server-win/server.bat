@echo off
title Project O Stream - Server

if exist "%~dp0server.exe" goto run_exe

python --version >nul 2>&1
if %errorlevel% neq 0 goto no_python

python -c "import textual" >nul 2>&1
if %errorlevel% neq 0 python -m pip install textual --quiet

python "%~dp0receiver.py" --cameras 4 %*
goto end

:run_exe
"%~dp0server.exe" --cameras 4 %*
goto end

:no_python
echo [ERROR] Python not found. Install Python 3.10+ from python.org
echo [ERROR] Or run build.bat to create server.exe (no Python needed at runtime).
pause

:end
