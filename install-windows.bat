@echo off
REM ============================================================
REM Winus Intercom — Windows Installer
REM Requires: Docker Desktop for Windows (running)
REM Usage: Double-click install-windows.bat or run from CMD
REM ============================================================

setlocal enabledelayedexpansion

echo.
echo ╔══════════════════════════════════════════╗
echo ║  Winus Intercom — Windows Installer      ║
echo ╚══════════════════════════════════════════╝
echo.

REM ---- Check Docker ----
echo [1/5] Checking Docker...
docker --version >nul 2>&1
if errorlevel 1 (
    echo   [X] Docker not found. Please install Docker Desktop:
    echo       https://www.docker.com/products/docker-desktop/
    echo.
    pause
    exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
    echo   [X] Docker is not running. Please start Docker Desktop and try again.
    echo.
    pause
    exit /b 1
)
echo   [OK] Docker is running

REM ---- Detect LAN IP ----
echo [2/5] Detecting network...
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "127.0.0"') do (
    set "RAW_IP=%%a"
    for /f "tokens=*" %%b in ("!RAW_IP!") do set "LAN_IP=%%b"
    goto :got_ip
)
:got_ip
if not defined LAN_IP set LAN_IP=127.0.0.1

REM ---- Try to discover the public IP (cloud VMs) ----
for /f "delims=" %%a in ('powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 https://api.ipify.org).Content } catch {}"') do set "PUBLIC_IP=%%a"

if defined PUBLIC_IP (
    set "DEFAULT_EXTERNAL=%PUBLIC_IP%"
) else (
    set "DEFAULT_EXTERNAL=%LAN_IP%"
)
set "DEFAULT_LOCAL=%LAN_IP%"
if "%LAN_IP%"=="%DEFAULT_EXTERNAL%" (
    set "DEFAULT_ANNOUNCED=%DEFAULT_EXTERNAL%"
) else (
    set "DEFAULT_ANNOUNCED=%DEFAULT_EXTERNAL%,%LAN_IP%"
)

echo   [OK] LAN IP: %LAN_IP%
if defined PUBLIC_IP echo   [OK] Public IP detected: %PUBLIC_IP%

REM ---- Interactive network configuration ----
echo.
echo -------------------------------------------------
echo  Winus Intercom -- server network configuration
echo -------------------------------------------------
echo Press Enter to accept the default shown in brackets.
echo.

set /p "EXTERNAL_IP=  Public IP or domain clients will use [%DEFAULT_EXTERNAL%]: "
if "%EXTERNAL_IP%"=="" set "EXTERNAL_IP=%DEFAULT_EXTERNAL%"

set /p "LOCAL_IP=  Local/private IP of this PC [%DEFAULT_LOCAL%]: "
if "%LOCAL_IP%"=="" set "LOCAL_IP=%DEFAULT_LOCAL%"

set /p "MEDIASOUP_ANNOUNCED_IPS=  Mediasoup announced IPs (comma-separated) [%DEFAULT_ANNOUNCED%]: "
if "%MEDIASOUP_ANNOUNCED_IPS%"=="" set "MEDIASOUP_ANNOUNCED_IPS=%DEFAULT_ANNOUNCED%"

set /p "PUBLIC_DOMAIN=  Optional public domain (Enter to skip): "

REM ---- Ask for admin password ----
set /p "ADMIN_PASS=  Admin password (default: admin): "
if "%ADMIN_PASS%"=="" set "ADMIN_PASS=admin"

REM ---- Generate .env ----
echo [3/5] Configuring...

REM Generate random JWT secret
for /f %%a in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')"') do set "JWT_SECRET=%%a"

(
echo JWT_SECRET=%JWT_SECRET%
echo ADMIN_USERNAME=admin
echo ADMIN_PASSWORD=%ADMIN_PASS%
echo HTTP_PORT=8080
echo HTTPS_PORT=8443
echo TURN_USER=intercom
echo TURN_PASSWORD=intercom2024
echo MEDIASOUP_ANNOUNCED_IPS=%MEDIASOUP_ANNOUNCED_IPS%
echo EXTERNAL_IP=%EXTERNAL_IP%
echo LOCAL_IP=%LOCAL_IP%
echo PUBLIC_DOMAIN=%PUBLIC_DOMAIN%
) > .env
echo   [OK] Configuration saved to .env

REM ---- Generate SSL certificate ----
echo [4/5] Generating SSL certificate...
if not exist "nginx\certs" mkdir nginx\certs
if not exist "nginx\certs\cert.pem" (
    set "SAN=IP:%LOCAL_IP%,IP:127.0.0.1"
    REM Append EXTERNAL_IP (as IP: or DNS: depending on the form)
    echo %EXTERNAL_IP%| findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
    if !errorlevel! equ 0 (
        if not "%EXTERNAL_IP%"=="%LOCAL_IP%" set "SAN=!SAN!,IP:%EXTERNAL_IP%"
    ) else (
        if not "%EXTERNAL_IP%"=="" if not "%EXTERNAL_IP%"=="%LOCAL_IP%" set "SAN=!SAN!,DNS:%EXTERNAL_IP%"
    )
    if not "%PUBLIC_DOMAIN%"=="" if not "%PUBLIC_DOMAIN%"=="%EXTERNAL_IP%" set "SAN=!SAN!,DNS:%PUBLIC_DOMAIN%"
    docker run --rm -v "%cd%\nginx\certs:/certs" alpine/openssl req -x509 -newkey rsa:2048 ^
        -keyout /certs/key.pem -out /certs/cert.pem ^
        -days 3650 -nodes -subj "/CN=%EXTERNAL_IP%" ^
        -addext "subjectAltName=!SAN!" 2>nul
    echo   [OK] Certificate generated (SAN: !SAN!)
) else (
    echo   [OK] Certificate already exists
)

REM ---- Create downloads dir ----
if not exist "nginx\downloads" mkdir nginx\downloads

REM ---- Build and start ----
echo [5/5] Building and starting services (this may take a few minutes)...
docker compose up -d --build
if errorlevel 1 (
    echo   [X] Build failed. Check Docker Desktop is running.
    pause
    exit /b 1
)

REM ---- Wait for backend ----
echo.
echo   Waiting for backend to start...
timeout /t 10 /nobreak >nul

REM ---- Control Center launcher ----
if exist "%~dp0control_center\launch.bat" (
    echo [+] Creating Control Center shortcut: WinusControlCenter.bat
    > "%~dp0WinusControlCenter.bat" echo @echo off
    >> "%~dp0WinusControlCenter.bat" echo cd /d "%%~dp0"
    >> "%~dp0WinusControlCenter.bat" echo call control_center\launch.bat
)

REM ---- Done ----
echo.
echo ╔══════════════════════════════════════════╗
echo ║  Winus Intercom installed!               ║
echo ╚══════════════════════════════════════════╝
echo.
if not "%PUBLIC_DOMAIN%"=="" (
    echo   Web:       https://%PUBLIC_DOMAIN%:8443
) else (
    echo   Web:       https://%EXTERNAL_IP%:8443
)
echo   Admin:     admin / %ADMIN_PASS%
echo   APK:       https://%EXTERNAL_IP%:8443/intercom.apk
echo   iOS cert:  https://%EXTERNAL_IP%:8443/cert.pem
echo.
if not "%EXTERNAL_IP%"=="%LAN_IP%" (
    echo   LAN URL:   https://%LAN_IP%:8443
    echo.
)
echo   Manage:    docker compose stop / start / logs
echo   Settings:  Admin panel → Settings (configure IPs)
echo.
echo   Firewall: Open these ports for external access:
echo     8443/TCP   - HTTPS (web + WebSocket)
echo     10000-10200/UDP - WebRTC media
echo     3478/UDP+TCP    - TURN server
echo     49152-49200/UDP - TURN relay
echo.
pause
