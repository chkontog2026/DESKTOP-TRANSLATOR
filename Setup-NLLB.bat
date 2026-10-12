@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv-nllb\Scripts\python.exe" python -m venv .venv-nllb
if errorlevel 1 goto failed
.venv-nllb\Scripts\python.exe -m pip install -r tools\requirements-nllb.txt
if errorlevel 1 goto failed
.venv-nllb\Scripts\python.exe tools\translate_nllb.py --setup
if errorlevel 1 goto failed
echo Local NLLB is ready.
pause
exit /b 0
:failed
echo NLLB setup failed. See the error above.
pause
exit /b 1
