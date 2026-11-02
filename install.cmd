@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0plugins\codex-shorekeeper-startup\scripts\manage.ps1" -Action Install %*
set "result=%errorlevel%"
if not "%result%"=="0" echo Operation failed. Review the message above.
pause
exit /b %result%
