@echo off
setlocal
cd /d "%~dp0"

echo Installing Shogun 2 co-op fix...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Shogun2CoopFix.ps1" -Action InstallProfile
if errorlevel 1 (
    echo.
    echo Installation failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Installed. Apply this package on every human player's PC.
pause
