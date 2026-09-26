@echo off
setlocal
cd /d "%~dp0"

set "PY=.venv\Scripts\python.exe"

if not exist "%PY%" (
  echo [1/3] Creating virtual environment...
  python -m venv .venv
  if errorlevel 1 goto :fail
)

"%PY%" -c "import pycaw, comtypes" >nul 2>&1
if errorlevel 1 (
  echo [2/3] Installing dependencies...
  "%PY%" -m pip install -r requirements.txt
  if errorlevel 1 goto :fail
)

echo [3/3] Starting Amou Music LAN remote...
echo.
"%PY%" server.py %*
goto :eof

:fail
echo.
echo Startup failed. See the messages above.
pause
exit /b 1
