@echo off
setlocal
cd /d "%~dp0"

if exist "%SystemRoot%\System32\conhost.exe" (
    start "Transcribe And Translate" "%SystemRoot%\System32\conhost.exe" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0Transcribe-And-Translate.ps1"
    exit /b
)

powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0Transcribe-And-Translate.ps1"

echo.
pause
