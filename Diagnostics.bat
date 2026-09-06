@echo off
setlocal
cd /d "%~dp0"

echo Installing temporary diagnostics profile...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Shogun2CoopFix.ps1" -Action InstallDiagnostics
if errorlevel 1 (
    echo.
    echo Diagnostics install failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Reproduce the problem, then run ShowLogs.bat on both PCs.
pause
