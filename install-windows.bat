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
echo   [OK] LAN IP: %LAN_IP%

REM ---- Ask for public domain/IP ----
echo.
set /p "PUBLIC_DOMAIN=  Public domain or IP (e.g. myserver.com, or press Enter for LAN only): "
if "%PUBLIC_DOMAIN%"=="" set PUBLIC_DOMAIN=%LAN_IP%
echo   [OK] Public address: %PUBLIC_DOMAIN%

REM ---- Ask for admin password ----
set /p "ADMIN_PASS=  Admin password (default: admin): "
if "%ADMIN_PASS%"=="" set ADMIN_PASS=admin

REM ---- Generate .env ----
echo [3/5] Configuring...

REM Generate random JWT secret
for /f %%a in ('powershell -command "[guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')"') do set JWT_SECRET=%%a

(
echo JWT_SECRET=%JWT_SECRET%
echo ADMIN_USERNAME=admin
echo ADMIN_PASSWORD=%ADMIN_PASS%
echo HTTP_PORT=8080
echo HTTPS_PORT=8443
echo TURN_USER=intercom
echo TURN_PASSWORD=intercom2024
echo MEDIASOUP_ANNOUNCED_IPS=%LAN_IP%,%PUBLIC_DOMAIN%
echo EXTERNAL_IP=%PUBLIC_DOMAIN%
echo LOCAL_IP=%LAN_IP%
) > .env
echo   [OK] Configuration saved to .env

REM ---- Generate SSL certificate ----
echo [4/5] Generating SSL certificate...
if not exist "nginx\certs" mkdir nginx\certs
if not exist "nginx\certs\cert.pem" (
    docker run --rm -v "%cd%\nginx\certs:/certs" alpine/openssl req -x509 -newkey rsa:2048 ^
        -keyout /certs/key.pem -out /certs/cert.pem ^
        -days 3650 -nodes -subj "/CN=Winus Intercom" ^
        -addext "subjectAltName=IP:%LAN_IP%,IP:127.0.0.1" 2>nul
    echo   [OK] Certificate generated
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

REM ---- Done ----
echo.
echo ╔══════════════════════════════════════════╗
echo ║  Winus Intercom installed!               ║
echo ╚══════════════════════════════════════════╝
echo.
echo   Web:       https://%LAN_IP%:8443
echo   Admin:     admin / %ADMIN_PASS%
echo   APK:       https://%LAN_IP%:8443/intercom.apk
echo   iOS cert:  https://%LAN_IP%:8443/cert.pem
echo.
if not "%PUBLIC_DOMAIN%"=="%LAN_IP%" (
echo   External:  https://%PUBLIC_DOMAIN%:8443
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
