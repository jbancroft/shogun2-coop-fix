@echo off
setlocal
cd /d "%~dp0"

echo Restoring the latest native-file backup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-LegacyBuild.ps1" -Action Restore
if errorlevel 1 (
    echo.
    echo Legacy build restore failed. Copy the error above when asking for help.
    pause
    exit /b 1
)

echo.
echo Native files restored. If data/locales were not backed up, run Steam file verification.
pause
