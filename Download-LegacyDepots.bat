@echo off
setlocal
cd /d "%~dp0"

echo Guiding the Steam Console download of the pre-update Shogun 2 depots...
echo Steam stays signed in locally; this script never asks for a password.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Download-LegacyDepots.ps1" -Action Guide
if errorlevel 1 (
    echo.
    echo Depot download or installation failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Legacy build and co-op profile installed. Every human player must use the same build.
pause
