@echo off
setlocal
rem ASCII launcher; Chinese output lives in UTF-8 BOM PowerShell sources.
if not exist "%~dp0scripts\vbs-toolkit.ps1" (
    echo Missing scripts\vbs-toolkit.ps1. Download and extract the complete ZIP.
    pause
    exit /b 1
)
set "VBS_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "VBS_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%VBS_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\vbs-toolkit.ps1" -Mode Diagnose
set "VBS_RESULT=%errorlevel%"
echo.
pause
exit /b %VBS_RESULT%
