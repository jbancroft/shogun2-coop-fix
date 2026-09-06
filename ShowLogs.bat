@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Shogun2CoopFix.ps1" -Action ShowLogSummary
pause
