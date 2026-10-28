@echo off
cd /d "%~dp0"
echo === Comprobando login y pendientes ===
powershell -NoProfile -ExecutionPolicy Bypass -File sbid-daily.ps1 -Check
echo.
echo === Simulacion (no guarda nada) ===
powershell -NoProfile -ExecutionPolicy Bypass -File sbid-daily.ps1 -DryRun
echo.
pause
