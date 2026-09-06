@echo off
setlocal
cd /d "%~dp0"

echo Removing only the Shogun2CoopFix profile block...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Shogun2CoopFix.ps1" -Action RestoreProfile
if errorlevel 1 (
    echo.
    echo Removal failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Done. Any timestamped backup was retained.
pause
