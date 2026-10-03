@echo off
setlocal
chcp 65001 >nul
title Claude Code + CC Switch Bundle Installer

echo.
echo   Claude Code CLI + CC Switch merged installer (offline-first)
echo   Unblocking package files ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File" >nul 2>&1

echo   Starting installer ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EC=%ERRORLEVEL%

echo.
if "%EC%"=="0" (
  echo   [OK] Installation finished successfully.
) else (
  echo   [FAIL] Installation failed. Check the log: %%TEMP%%\cc-bundle-install.log
)
echo.
pause
exit /b %EC%
