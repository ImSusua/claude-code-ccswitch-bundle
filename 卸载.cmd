@echo off
setlocal
chcp 65001 >nul
title Claude Code + CC Switch Bundle Uninstaller

echo.
echo   Uninstalling Claude Code + CC Switch (user data is kept by default) ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set EC=%ERRORLEVEL%

echo.
pause
exit /b %EC%
