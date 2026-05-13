@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM Server Bridge - Windows Installer
REM Connects two Winus Intercom servers via RTP audio relay.
REM ============================================================

title Server Bridge - Installer

set "BRIDGE_DIR=%~dp0"
set "BRIDGE_DIR=%BRIDGE_DIR:~0,-1%"
set "VENV=%BRIDGE_DIR%\.venv-server-bridge"
set "LOG=%BRIDGE_DIR%\server_bridge_install.log"

echo ============================================ > "%LOG%"
echo Server Bridge Install Log >> "%LOG%"
echo %date% %time% >> "%LOG%"
echo ============================================ >> "%LOG%"
echo.
echo ============================================
echo    Server Bridge - Windows Installer
echo ============================================
echo.

REM ---- 1. Check Python ----
echo [1/4] Checking Python...
echo [1/4] Checking Python... >> "%LOG%"
where python >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    where python3 >nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo [ERROR] Python not found.
        echo   Download from: https://www.python.org/downloads/
        echo   IMPORTANT: Check "Add Python to PATH" during install.
        echo.
        pause
        exit /b 1
    )
    set "PYTHON=python3"
) else (
    set "PYTHON=python"
)
for /f "tokens=*" %%i in ('%PYTHON% --version 2^>^&1') do set PYVER=%%i
echo   Found: %PYVER%
echo   %PYVER% >> "%LOG%"

REM Check version >= 3.10
for /f "tokens=2 delims= " %%v in ("%PYVER%") do set PYVER_NUM=%%v
for /f "tokens=1,2 delims=." %%a in ("%PYVER_NUM%") do (
    set PYMAJOR=%%a
    set PYMINOR=%%b
)
if %PYMAJOR% LSS 3 (
    echo [ERROR] Python 3.10+ required
    pause
    exit /b 1
)
if %PYMAJOR% EQU 3 if %PYMINOR% LSS 10 (
    echo [ERROR] Python 3.10+ required
    pause
    exit /b 1
)

REM ---- 2. Virtual environment ----
echo.
echo [2/4] Creating virtual environment...
echo [2/4] Creating venv... >> "%LOG%"
if exist "%VENV%" (
    "%VENV%\Scripts\python.exe" --version >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo   Recreating broken venv...
        rmdir /s /q "%VENV%"
    ) else (
        echo   venv OK
    )
)
if not exist "%VENV%" (
    %PYTHON% -m venv "%VENV%" >> "%LOG%" 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Failed to create venv
        pause
        exit /b 1
    )
    echo   Created .venv-server-bridge
)

REM ---- 3. Install packages ----
echo.
echo [3/4] Installing Python packages...
echo [3/4] Installing packages... >> "%LOG%"
call "%VENV%\Scripts\activate.bat"
python -m pip install --upgrade pip >> "%LOG%" 2>&1
python -m pip install websockets aiohttp customtkinter Pillow >> "%LOG%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] pip install failed - see server_bridge_install.log
    pause
    exit /b 1
)
echo   All packages installed

REM ---- 4. Create config + launcher + shortcut ----
echo.
echo [4/4] Creating launcher...
echo [4/4] Creating launcher... >> "%LOG%"

REM Config template (don't overwrite)
if not exist "%BRIDGE_DIR%\server_bridge.json" (
    echo { > "%BRIDGE_DIR%\server_bridge.json"
    echo   "server_a": "https://server-a:8443", >> "%BRIDGE_DIR%\server_bridge.json"
    echo   "server_b": "https://server-b:8443", >> "%BRIDGE_DIR%\server_bridge.json"
    echo   "links": [ >> "%BRIDGE_DIR%\server_bridge.json"
    echo     { >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "label": "Link 1", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "a_username": "bridge_b_1", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "a_password": "changeme", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "a_target_type": "user", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "a_target_id": 0, >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "b_username": "bridge_a_1", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "b_password": "changeme", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "b_target_type": "user", >> "%BRIDGE_DIR%\server_bridge.json"
    echo       "b_target_id": 0 >> "%BRIDGE_DIR%\server_bridge.json"
    echo     } >> "%BRIDGE_DIR%\server_bridge.json"
    echo   ] >> "%BRIDGE_DIR%\server_bridge.json"
    echo } >> "%BRIDGE_DIR%\server_bridge.json"
    echo   Created server_bridge.json (edit before running!)
)

REM Launcher .bat
REM GUI launcher (main)
echo @echo off> "%BRIDGE_DIR%\Server_Bridge.bat"
echo cd /d "%%~dp0">> "%BRIDGE_DIR%\Server_Bridge.bat"
echo call .venv-server-bridge\Scripts\activate.bat>> "%BRIDGE_DIR%\Server_Bridge.bat"
echo python server_bridge_gui.py>> "%BRIDGE_DIR%\Server_Bridge.bat"
echo   Created Server_Bridge.bat (GUI)

REM CLI launcher
echo @echo off> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo cd /d "%%~dp0">> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo call .venv-server-bridge\Scripts\activate.bat>> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo echo Server Bridge — Ctrl+C to stop>> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo echo.>> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo python server_bridge.py>> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo pause>> "%BRIDGE_DIR%\Server_Bridge_CLI.bat"
echo   Created Server_Bridge_CLI.bat (headless)

REM Desktop shortcut
set "DESKTOP=%USERPROFILE%\Desktop"
powershell -Command "$s=(New-Object -COM WScript.Shell).CreateShortcut('%DESKTOP%\Server Bridge.lnk');$s.TargetPath='%BRIDGE_DIR%\Server_Bridge.bat';$s.WorkingDirectory='%BRIDGE_DIR%';$s.Description='Winus Server Bridge - Inter-server audio relay';$s.Save()" >> "%LOG%" 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   Desktop shortcut created
) else (
    echo   [!] Could not create shortcut (not critical)
)

echo.
echo ============================================
echo    Installation complete!
echo ============================================
echo.
echo    1. Edit server_bridge.json with your
echo       server URLs and bridge credentials
echo.
echo    2. Double-click Server_Bridge.bat
echo       or the Desktop shortcut to run
echo.
echo    Log: server_bridge_install.log
echo.
pause
