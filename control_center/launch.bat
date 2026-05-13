@echo off
REM ============================================================
REM Winus Intercom - Control Center launcher (Windows)
REM   - Bootstraps a local venv in .\.venv on first run.
REM   - Installs customtkinter on first run.
REM   - Launches the GUI.
REM Requirements: Python 3.9+ on PATH (with the standard tkinter
REM module, which the python.org installer ships by default).
REM ============================================================

setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
set "VENV=%SCRIPT_DIR%.venv"

REM Locate Python
where py >nul 2>&1
if %errorlevel% == 0 (
    set "PYBOOT=py -3"
) else (
    where python >nul 2>&1
    if %errorlevel% == 0 (
        set "PYBOOT=python"
    ) else (
        echo [X] Python 3 not found on PATH.
        echo     Install Python 3.9+ from https://www.python.org/downloads/
        echo     and make sure "Add Python to PATH" is checked.
        pause
        exit /b 1
    )
)

REM Verify tkinter is available
%PYBOOT% -c "import tkinter" >nul 2>&1
if errorlevel 1 (
    echo [X] tkinter is missing from this Python install.
    echo     Re-install Python from python.org with the "tcl/tk and IDLE"
    echo     option enabled, then run this script again.
    pause
    exit /b 1
)

REM Create venv on first run
if not exist "%VENV%\Scripts\python.exe" (
    echo [+] Creating venv in %VENV% ...
    %PYBOOT% -m venv "%VENV%"
    "%VENV%\Scripts\python.exe" -m pip install --quiet --upgrade pip
    "%VENV%\Scripts\python.exe" -m pip install --quiet customtkinter
)

REM Re-check customtkinter (in case the venv was created but install failed)
"%VENV%\Scripts\python.exe" -c "import customtkinter" >nul 2>&1
if errorlevel 1 (
    echo [+] Installing customtkinter...
    "%VENV%\Scripts\python.exe" -m pip install --quiet customtkinter
)

REM Launch the GUI
"%VENV%\Scripts\python.exe" "%SCRIPT_DIR%control_center.py" %*
