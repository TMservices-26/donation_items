@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-pdf-drop.ps1"
if errorlevel 1 (
  echo.
  echo Setup failed. See the error above, then try again.
)
echo.
pause
