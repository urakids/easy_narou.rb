@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0narou.ps1" %*
set "narouExitCode=%ERRORLEVEL%"
if not "%narouExitCode%"=="0" pause
exit /b %narouExitCode%
