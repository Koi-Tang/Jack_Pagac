@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\manage.ps1" -Action Uninstall -Destination "%~dp0."
pause
