@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File sbid-daily.ps1 -Uninstall
echo.
pause
