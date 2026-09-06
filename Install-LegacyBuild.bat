@echo off
setlocal
cd /d "%~dp0"

echo Applying the downloaded pre-update Shogun 2 depots...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-LegacyBuild.ps1" -Action Install
if errorlevel 1 (
    echo.
    echo Legacy build install failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Legacy build installed. Apply the same depots on every human player's PC.
pause
