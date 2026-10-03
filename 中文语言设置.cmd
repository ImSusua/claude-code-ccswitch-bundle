@echo off
setlocal
chcp 65001 >nul
title Claude Code Language Setting

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-language.ps1" %*
set EC=%ERRORLEVEL%

echo.
pause
exit /b %EC%
