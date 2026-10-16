@echo off
cd /d "%~dp0"
REM Enable PortAudio ASIO DLL (Dante Virtual Soundcard up to 64ch)
set SD_ENABLE_ASIO=1
if exist ".venv\Scripts\activate.bat" call ".venv\Scripts\activate.bat"
python bridge_gui.py
if errorlevel 1 pause
