@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM TieLine Bridge - Windows Installer
REM Installs Python venv, dependencies, Opus DLL, and shortcut
REM ============================================================

title TieLine Bridge - Installer

set "BRIDGE_DIR=%~dp0"
set "BRIDGE_DIR=%BRIDGE_DIR:~0,-1%"
set "LOG=%BRIDGE_DIR%\install.log"

REM Start logging
echo ============================================ > "%LOG%"
echo TieLine Bridge Install Log >> "%LOG%"
echo %date% %time% >> "%LOG%"
echo ============================================ >> "%LOG%"
echo BRIDGE_DIR=%BRIDGE_DIR% >> "%LOG%"
echo. >> "%LOG%"

echo.
echo ============================================
echo    TieLine Bridge v3.2.2 - Windows Installer
echo ============================================
echo    (Log: install.log)
echo.

REM ---- 1. Check Python ----
echo [1/5] Checking Python...
echo [1/5] Checking Python... >> "%LOG%"
where python >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    where python3 >nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Python not found. >> "%LOG%"
        echo.
        echo [ERROR] Python not found.
        echo.
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
echo   Python: %PYVER% >> "%LOG%"
where %PYTHON% >> "%LOG%" 2>&1

REM Check version >= 3.10
for /f "tokens=2 delims= " %%v in ("%PYVER%") do set PYVER_NUM=%%v
for /f "tokens=1,2 delims=." %%a in ("%PYVER_NUM%") do (
    set PYMAJOR=%%a
    set PYMINOR=%%b
)
if %PYMAJOR% LSS 3 (
    echo [ERROR] Python 3.10+ required, found %PYVER% >> "%LOG%"
    echo [ERROR] Python 3.10+ required, found %PYVER%
    pause
    exit /b 1
)
if %PYMAJOR% EQU 3 if %PYMINOR% LSS 10 (
    echo [ERROR] Python 3.10+ required, found %PYVER% >> "%LOG%"
    echo [ERROR] Python 3.10+ required, found %PYVER%
    pause
    exit /b 1
)

REM ---- 2. Create virtual environment ----
echo.
echo [2/5] Creating virtual environment...
echo. >> "%LOG%"
echo [2/5] Creating venv... >> "%LOG%"
if exist "%BRIDGE_DIR%\.venv" (
    echo   .venv already exists, validating... >> "%LOG%"
    "%BRIDGE_DIR%\.venv\Scripts\python.exe" --version >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo   .venv is broken, recreating...
        echo   .venv broken, removing... >> "%LOG%"
        rmdir /s /q "%BRIDGE_DIR%\.venv"
    ) else (
        echo   .venv OK, skipping
        echo   .venv valid, skipping >> "%LOG%"
    )
)
if not exist "%BRIDGE_DIR%\.venv" (
    echo   Running: %PYTHON% -m venv "%BRIDGE_DIR%\.venv" >> "%LOG%"
    %PYTHON% -m venv "%BRIDGE_DIR%\.venv" >> "%LOG%" 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Failed to create virtual environment >> "%LOG%"
        echo [ERROR] Failed to create virtual environment
        pause
        exit /b 1
    )
    echo   Created .venv
    echo   venv created OK >> "%LOG%"
)

REM ---- 3. Install Python packages ----
echo.
echo [3/5] Installing Python packages...
echo. >> "%LOG%"
echo [3/5] Installing packages... >> "%LOG%"
call "%BRIDGE_DIR%\.venv\Scripts\activate.bat"
echo   pip location: >> "%LOG%"
where pip >> "%LOG%" 2>&1
python -m pip install --upgrade pip >> "%LOG%" 2>&1
echo   Installing requirements.txt... >> "%LOG%"
python -m pip install -r "%BRIDGE_DIR%\requirements.txt" >> "%LOG%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] pip install failed - see install.log >> "%LOG%"
    echo [ERROR] pip install failed - see install.log for details
    pause
    exit /b 1
)
echo   All packages installed
echo   All packages installed OK >> "%LOG%"

REM ---- 4. Download opus.dll ----
echo.
echo [4/5] Checking Opus library...
echo. >> "%LOG%"
echo [4/5] Checking opus.dll... >> "%LOG%"
if exist "%BRIDGE_DIR%\opus.dll" (
    echo   opus.dll already present
    echo   opus.dll already present >> "%LOG%"
    goto :opus_done
)

echo   Downloading opus.dll...
set "OPUS_URL=https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2-win64.zip"
set "OPUS_ZIP=%TEMP%\opus-win64.zip"
set "OPUS_EXTRACT=%TEMP%\opus-extract"
echo   URL: %OPUS_URL% >> "%LOG%"
echo   ZIP: %OPUS_ZIP% >> "%LOG%"

echo   Trying PowerShell download...
echo   Trying PowerShell... >> "%LOG%"
powershell -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%OPUS_URL%' -OutFile '%OPUS_ZIP%'" >> "%LOG%" 2>&1
if not exist "%OPUS_ZIP%" (
    echo   [!] PowerShell failed. Trying curl...
    echo   PowerShell failed, trying curl... >> "%LOG%"
    curl -sL "%OPUS_URL%" -o "%OPUS_ZIP%" >> "%LOG%" 2>&1
)

if not exist "%OPUS_ZIP%" (
    echo   [!] Download failed.
    echo   Download failed - ZIP not found >> "%LOG%"
    goto :opus_manual
)
echo   ZIP downloaded OK >> "%LOG%"

echo   Extracting...
if exist "%OPUS_EXTRACT%" rd /s /q "%OPUS_EXTRACT%"
powershell -Command "Expand-Archive -Path '%OPUS_ZIP%' -DestinationPath '%OPUS_EXTRACT%' -Force" >> "%LOG%" 2>&1
echo   Extracted to: %OPUS_EXTRACT% >> "%LOG%"
dir /s /b "%OPUS_EXTRACT%\*.dll" >> "%LOG%" 2>&1

REM Search for opus.dll in extracted files
for /r "%OPUS_EXTRACT%" %%f in (opus.dll libopus-0.dll) do (
    if exist "%%f" (
        echo   Found: %%f >> "%LOG%"
        copy "%%f" "%BRIDGE_DIR%\opus.dll" >nul
        echo   opus.dll installed
        echo   opus.dll copied OK >> "%LOG%"
    )
)

if exist "%BRIDGE_DIR%\opus.dll" goto :opus_done
echo   [!] opus.dll not found in archive
echo   opus.dll NOT found in archive >> "%LOG%"

:opus_manual
echo.
echo   [!] Could not download opus.dll automatically.
echo       Please download manually:
echo       1. Go to https://opus-codec.org/downloads/
echo       2. Download the Windows binary
echo       3. Copy opus.dll to: %BRIDGE_DIR%\
echo.

:opus_done
REM Clean up temp files
if exist "%OPUS_ZIP%" del "%OPUS_ZIP%" >nul 2>&1
if exist "%OPUS_EXTRACT%" rd /s /q "%OPUS_EXTRACT%" >nul 2>&1

REM ---- 5. Firewall rule for incoming RTP audio ----
echo.
echo [5/6] Configuring Windows Firewall...
echo. >> "%LOG%"
echo [5/6] Configuring firewall... >> "%LOG%"

REM Remove old rule if exists (avoid duplicates)
netsh advfirewall firewall delete rule name="TieLine Bridge RTP" >nul 2>&1
netsh advfirewall firewall add rule name="TieLine Bridge RTP" dir=in action=allow protocol=UDP program="%BRIDGE_DIR%\.venv\Scripts\python.exe" description="Allow incoming RTP audio for TieLine Bridge" >> "%LOG%" 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   Firewall rule added OK
    echo   Firewall rule OK >> "%LOG%"
) else (
    echo   [!] Could not add firewall rule. Run as Administrator to fix.
    echo   [!] Or manually allow UDP for: %BRIDGE_DIR%\.venv\Scripts\python.exe
    echo   Firewall rule FAILED >> "%LOG%"
)

REM ---- 6. Create launcher and desktop shortcut ----
echo.
echo [6/6] Creating launcher...
echo. >> "%LOG%"
echo [6/6] Creating launcher... >> "%LOG%"
echo   BRIDGE_DIR=%BRIDGE_DIR% >> "%LOG%"

REM Create run.bat (line by line to avoid percent-escaping issues)
echo @echo off> "%BRIDGE_DIR%\TieLine_Bridge.bat"
echo cd /d "%%~dp0">> "%BRIDGE_DIR%\TieLine_Bridge.bat"
echo call .venv\Scripts\activate.bat>> "%BRIDGE_DIR%\TieLine_Bridge.bat"
echo python bridge_gui.py>> "%BRIDGE_DIR%\TieLine_Bridge.bat"
echo pause>> "%BRIDGE_DIR%\TieLine_Bridge.bat"

if exist "%BRIDGE_DIR%\TieLine_Bridge.bat" (
    echo   Created TieLine_Bridge.bat
    echo   TieLine_Bridge.bat created OK >> "%LOG%"
) else (
    echo   [ERROR] Failed to create TieLine_Bridge.bat
    echo   [ERROR] TieLine_Bridge.bat NOT created >> "%LOG%"
    echo   Trying alternative path... >> "%LOG%"
    REM Fallback: try writing to current directory
    echo @echo off> TieLine_Bridge.bat
    echo cd /d "%%~dp0">> TieLine_Bridge.bat
    echo call .venv\Scripts\activate.bat>> TieLine_Bridge.bat
    echo python bridge_gui.py>> TieLine_Bridge.bat
    echo pause>> TieLine_Bridge.bat
    if exist "TieLine_Bridge.bat" (
        echo   Created TieLine_Bridge.bat (fallback path)
        echo   Fallback OK >> "%LOG%"
    ) else (
        echo   [ERROR] Still failed - check folder permissions
        echo   [ERROR] Fallback also failed >> "%LOG%"
    )
)

REM Create desktop shortcut via PowerShell
set "DESKTOP=%USERPROFILE%\Desktop"
echo   Desktop: %DESKTOP% >> "%LOG%"
powershell -Command "$s=(New-Object -COM WScript.Shell).CreateShortcut('%DESKTOP%\TieLine Bridge.lnk');$s.TargetPath='%BRIDGE_DIR%\TieLine_Bridge.bat';$s.WorkingDirectory='%BRIDGE_DIR%';$s.Description='TieLine Bridge - Audio Matrix Bridge';$s.Save()" >> "%LOG%" 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   Desktop shortcut created
    echo   Shortcut created OK >> "%LOG%"
) else (
    echo   [!] Could not create desktop shortcut (not critical)
    echo   Shortcut creation failed >> "%LOG%"
)

REM ---- Done ----
echo. >> "%LOG%"
echo ============================================ >> "%LOG%"
echo INSTALL COMPLETE %date% %time% >> "%LOG%"
echo ============================================ >> "%LOG%"

echo.
echo ============================================
echo    Installation complete!
echo ============================================
echo.
echo    Run: double-click TieLine_Bridge.bat
echo    Or:  Desktop shortcut
echo.
echo    Log saved to: install.log
echo.
pause
