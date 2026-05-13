#!/bin/bash
# ============================================================
# Winus Intercom — Create .deb package
# Usage: bash create-deb.sh
# Requires: dpkg-deb (apt install dpkg-dev)
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTERCOM_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$SCRIPT_DIR"
VERSION="1.0.$(date +%Y%m%d.%H%M)"
PKG="winus-intercom_${VERSION}_amd64"
DEB_DIR="/tmp/${PKG}"

echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — Create .deb            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# Check dpkg-deb
if ! command -v dpkg-deb &>/dev/null; then
    echo -e "  ${YELLOW}Installing dpkg-dev...${NC}"
    sudo apt-get install -y -qq dpkg-dev
fi

# ======================== 1. BUILD WEB ========================
echo -e "${CYAN}[1/6]${NC} Building Flutter web..."
cd "$INTERCOM_DIR/flutter_app"
flutter build web --pwa-strategy=none --release 2>&1 | tail -2
if [ $? -ne 0 ]; then echo -e "  ${RED}✗ Web build failed${NC}"; exit 1; fi
echo -e "  ${GREEN}✓${NC} Web build OK"

# ======================== 2. BUILD APK ========================
echo -e "${CYAN}[2/6]${NC} Building Android APK..."
flutter build apk --release 2>&1 | tail -2
if [ $? -ne 0 ]; then echo -e "  ${RED}✗ APK build failed${NC}"; exit 1; fi
cp build/app/outputs/flutter-apk/app-release.apk "$INTERCOM_DIR/nginx/downloads/intercom.apk"
echo -e "  ${GREEN}✓${NC} APK OK ($(du -h "$INTERCOM_DIR/nginx/downloads/intercom.apk" | cut -f1))"

# ======================== 3. BUILD DOCKER IMAGES ========================
echo -e "${CYAN}[3/6]${NC} Building Docker images..."
cd "$INTERCOM_DIR"
docker compose build
docker compose pull coturn

# Get the image names that compose created
BACKEND_IMG=$(docker compose images backend -q 2>/dev/null | head -1)
NGINX_IMG=$(docker compose images nginx -q 2>/dev/null | head -1)
if [ -z "$BACKEND_IMG" ] || [ -z "$NGINX_IMG" ]; then
    # Fallback: compose project name defaults to directory name
    BACKEND_IMG="winus-intercom-backend"
    NGINX_IMG="winus-intercom-nginx"
fi

echo -e "  Saving images to tar (this may take a minute)..."
DOCKER_TAR="$INTERCOM_DIR/docker-images.tar.gz"
docker save "$BACKEND_IMG" "$NGINX_IMG" coturn/coturn:latest | gzip > "$DOCKER_TAR"
echo -e "  ${GREEN}✓${NC} Docker images saved ($(du -h "$DOCKER_TAR" | cut -f1))"

# ======================== 4. PREPARE DEB STRUCTURE ========================
echo -e "${CYAN}[4/6]${NC} Preparing .deb structure..."
rm -rf "$DEB_DIR"
APP_DIR="$DEB_DIR/opt/winus-intercom"
mkdir -p "$APP_DIR"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/usr/local/bin"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/512x512/apps"

# Copy application files (excluding build artifacts, git, large files)
rsync -a --exclude='.git' \
         --exclude='flutter_app/build' \
         --exclude='flutter_app/.dart_tool' \
         --exclude='flutter_app/.flutter-plugins' \
         --exclude='flutter_app/.flutter-plugins-dependencies' \
         --exclude='flutter_app/android/.gradle' \
         --exclude='flutter_app/android/app/build' \
         --exclude='flutter_app/android/local.properties' \
         --exclude='backend/node_modules' \
         --exclude='backend/db/*.db' \
         --exclude='backend/db/*.db-shm' \
         --exclude='backend/db/*.db-wal' \
         --exclude='tie-line-bridge/__pycache__' \
         --exclude='tie-line-bridge/.venv' \
         --exclude='tie-line-bridge/opus.dll' \
         --exclude='control_center/.venv' \
         --exclude='control_center/__pycache__' \
         --exclude='*.tar.gz' \
         --exclude='*.tgz' \
         --exclude='*.zip' \
         --exclude='*.deb' \
         --exclude='archive/' \
         --exclude='.env' \
         --exclude='nginx/certs/*.pem' \
         "$INTERCOM_DIR/" "$APP_DIR/"

# Ensure the freshly built APK is shipped inside the package
install -D -m 0644 \
    "$INTERCOM_DIR/nginx/downloads/intercom.apk" \
    "$APP_DIR/nginx/downloads/intercom.apk"

# Copy built web app
mkdir -p "$APP_DIR/flutter_app/build"
rsync -a "$INTERCOM_DIR/flutter_app/build/web/" "$APP_DIR/flutter_app/build/web/"

# Copy pre-built Docker images
install -D -m 0644 "$DOCKER_TAR" "$APP_DIR/docker-images.tar.gz"
rm -f "$DOCKER_TAR"

# Create default .env (no secrets — generated at install time)
cat > "$APP_DIR/.env.template" << 'ENVEOF'
JWT_SECRET=CHANGE_ME
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
HTTP_PORT=8180
HTTPS_PORT=8443
TURN_PASSWORD=intercom2024
TURN_USER=intercom
PUBLIC_DOMAIN=
MEDIASOUP_ANNOUNCED_IPS=
EXTERNAL_IP=
LOCAL_IP=
ENVEOF

# Copy icon
cp "$INTERCOM_DIR/flutter_app/web/icons/Icon-512.png" \
   "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/winus-intercom.png" 2>/dev/null || true

# Launcher in /usr/local/bin
cat > "$DEB_DIR/usr/local/bin/winus-intercom" << 'LAUNCHEOF'
#!/bin/bash
exec /opt/winus-intercom/start-intercom.sh "$@"
LAUNCHEOF
chmod +x "$DEB_DIR/usr/local/bin/winus-intercom"

cat > "$DEB_DIR/usr/local/bin/winus-intercom-restart" << 'LAUNCHEOF'
#!/bin/bash
exec /opt/winus-intercom/restart-intercom.sh "$@"
LAUNCHEOF
chmod +x "$DEB_DIR/usr/local/bin/winus-intercom-restart"

# Desktop entries
cat > "$DEB_DIR/usr/share/applications/winus-intercom.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Intercom
Comment=Start Winus Intercom server
Exec=bash -c '/opt/winus-intercom/start-intercom.sh; read -p "Press Enter to close..."'
Icon=winus-intercom
Terminal=true
Categories=AudioVideo;Audio;Network;
DESKTOPEOF

cat > "$DEB_DIR/usr/share/applications/winus-intercom-restart.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Intercom - Restart
Comment=Restart services and update IPs
Exec=bash -c '/opt/winus-intercom/restart-intercom.sh; read -p "Press Enter to close..."'
Icon=winus-intercom
Terminal=true
Categories=AudioVideo;Audio;Network;
DESKTOPEOF

# Control Center: launcher + desktop entry. The actual Python venv is created
# on first run by `launch.sh` so the package stays portable.
cat > "$DEB_DIR/usr/local/bin/winus-control-center" << 'LAUNCHEOF'
#!/bin/bash
exec /opt/winus-intercom/control_center/launch.sh "$@"
LAUNCHEOF
chmod +x "$DEB_DIR/usr/local/bin/winus-control-center"

cat > "$DEB_DIR/usr/share/applications/winus-control-center.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Control Center
Comment=Build, deploy and manage Winus Intercom
Exec=/opt/winus-intercom/control_center/launch.sh
Icon=winus-intercom
Terminal=false
Categories=Development;AudioVideo;Audio;Network;
StartupWMClass=Winus Intercom — Control Center
DESKTOPEOF

echo -e "  ${GREEN}✓${NC} File structure ready"

# ======================== 5. DEBIAN CONTROL ========================
echo -e "${CYAN}[5/6]${NC} Creating DEBIAN control files..."

PKG_SIZE=$(du -sk "$APP_DIR" | cut -f1)

cat > "$DEB_DIR/DEBIAN/control" << CONTROLEOF
Package: winus-intercom
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Installed-Size: ${PKG_SIZE}
Depends: docker-ce | docker.io, openssl, curl
Recommends: docker-compose-plugin
Maintainer: Thierry Huin <thierry@huin.tv>
Description: Winus Intercom - Professional IP Intercom System
 Full-featured IP intercom system with WebRTC audio,
 push-to-talk, groups, permissions, and a Flutter web/mobile app.
 Powered by mediasoup, nginx, and coturn via Docker.
CONTROLEOF

# postinst: run after install
cat > "$DEB_DIR/DEBIAN/postinst" << 'POSTINSTEOF'
#!/bin/bash
set -e

APP_DIR="/opt/winus-intercom"
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
USER_HOME=$(eval echo "~$REAL_USER")

# Ensure scripts are executable
chmod +x "$APP_DIR/start-intercom.sh" \
         "$APP_DIR/stop-intercom.sh" \
         "$APP_DIR/restart-intercom.sh" \
         "$APP_DIR/create-deb.sh" \
         "$APP_DIR/control_center/launch.sh" \
         "$APP_DIR/control_center/control_center.py" 2>/dev/null || true

# Add user to docker group
if id "$REAL_USER" &>/dev/null; then
    usermod -aG docker "$REAL_USER" 2>/dev/null || true
fi

# Generate .env from template if not exists
ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "$APP_DIR/.env.template" "$ENV_FILE"
    # Generate random JWT secret
    JWT=$(openssl rand -hex 32)
    sed -i "s/CHANGE_ME/$JWT/" "$ENV_FILE"
fi

# Auto-detect IPs (used as default answers to the prompts below, and as
# fallback when running non-interactively).
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
ZT_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
WG_IP=$(ip -4 addr show 2>/dev/null | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
AUTO_ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$WG_IP"

# Try to guess the server's public IP (used as default for EXTERNAL_IP when
# we're on a cloud VM). Skip the call if we have no outbound internet.
PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"

# Decide defaults: on cloud VMs (public IP differs from LAN IP) lean on the
# public IP for EXTERNAL_IP; on a LAN-only install keep LAN_IP everywhere.
DEFAULT_EXTERNAL="${PUBLIC_IP:-$LAN_IP}"
DEFAULT_LOCAL="${LAN_IP}"
DEFAULT_ANNOUNCED="${DEFAULT_EXTERNAL}"
[ -n "$LAN_IP" ] && [ "$LAN_IP" != "$DEFAULT_EXTERNAL" ] && DEFAULT_ANNOUNCED="$DEFAULT_EXTERNAL,$LAN_IP"
DEFAULT_DOMAIN=""

# Prompt only when we have a TTY AND the user hasn't forced
# non-interactive via DEBIAN_FRONTEND=noninteractive.
INTERACTIVE=no
if [ -t 0 ] && [ -t 1 ] && [ "${DEBIAN_FRONTEND}" != "noninteractive" ]; then
    INTERACTIVE=yes
fi

ask() {
    # ask <VAR_NAME> <PROMPT> <DEFAULT>
    local __var="$1"; local __prompt="$2"; local __default="$3"
    local __answer=""
    if [ "$INTERACTIVE" = "yes" ]; then
        if [ -n "$__default" ]; then
            read -r -p "  $__prompt [$__default]: " __answer </dev/tty || __answer=""
        else
            read -r -p "  $__prompt: " __answer </dev/tty || __answer=""
        fi
    fi
    # Fall back to default if empty / non-interactive
    [ -z "$__answer" ] && __answer="$__default"
    # Export dynamically
    eval "$__var=\"\$__answer\""
}

if [ "$INTERACTIVE" = "yes" ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo " Winus Intercom — server network configuration"
    echo "──────────────────────────────────────────────"
    echo "Press Enter to accept the default shown in brackets."
    echo ""
fi

ask EXTERNAL_IP "Public IP or domain clients will use (EXTERNAL_IP)" "$DEFAULT_EXTERNAL"
ask LOCAL_IP    "Local/private IP of this server (LOCAL_IP)"         "$DEFAULT_LOCAL"
ask MEDIASOUP_ANNOUNCED_IPS "Mediasoup announced IPs (comma-separated)" "$DEFAULT_ANNOUNCED"
ask PUBLIC_DOMAIN "Optional public domain (e.g. winus.overon.es). Leave blank if none" "$DEFAULT_DOMAIN"

sed -i '/^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d; /^PUBLIC_DOMAIN/d' "$ENV_FILE"
echo "MEDIASOUP_ANNOUNCED_IPS=${MEDIASOUP_ANNOUNCED_IPS}" >> "$ENV_FILE"
echo "EXTERNAL_IP=${EXTERNAL_IP}" >> "$ENV_FILE"
echo "LOCAL_IP=${LOCAL_IP}" >> "$ENV_FILE"
echo "PUBLIC_DOMAIN=${PUBLIC_DOMAIN}" >> "$ENV_FILE"

# Generate SSL certificate
CERT_DIR="$APP_DIR/nginx/certs"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
    # Accept both IP and domain as SAN entries.
    SAN="IP:${LOCAL_IP},IP:127.0.0.1"
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "$LOCAL_IP" ]; then
        if echo "$EXTERNAL_IP" | grep -qE '^[0-9.]+$'; then
            SAN="$SAN,IP:${EXTERNAL_IP}"
        else
            SAN="$SAN,DNS:${EXTERNAL_IP}"
        fi
    fi
    if [ -n "$PUBLIC_DOMAIN" ] && [ "$PUBLIC_DOMAIN" != "$EXTERNAL_IP" ]; then
        SAN="$SAN,DNS:${PUBLIC_DOMAIN}"
    fi
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=${EXTERNAL_IP:-Winus Intercom}" \
        -addext "subjectAltName=${SAN}" 2>/dev/null || true
fi

# Create downloads dir
mkdir -p "$APP_DIR/nginx/downloads"
mkdir -p "$APP_DIR/backend/db"

# Fix ownership
chown -R "$REAL_USER:$REAL_USER" "$APP_DIR" 2>/dev/null || true

# Load pre-built Docker images and start services
IMAGES_TAR="$APP_DIR/docker-images.tar.gz"
if [ -f "$IMAGES_TAR" ]; then
    echo "Loading pre-built Docker images..."
    docker load < "$IMAGES_TAR"
    echo "Starting services..."
    cd "$APP_DIR"
    if id "$REAL_USER" &>/dev/null && [ "$REAL_USER" != "root" ]; then
        su - "$REAL_USER" -c "cd $APP_DIR && docker compose up -d" || true
    else
        docker compose up -d || true
    fi
    # Remove the tar to save ~500 MB of disk after loading
    rm -f "$IMAGES_TAR"
else
    # Fallback: no pre-built images, build from source
    echo "No pre-built images found, building from source..."
    cd "$APP_DIR"
    if id "$REAL_USER" &>/dev/null && [ "$REAL_USER" != "root" ]; then
        su - "$REAL_USER" -c "cd $APP_DIR && docker compose up -d --build" || true
    else
        docker compose up -d --build || true
    fi
fi

echo ""
echo "✅ Winus Intercom installed!"
if [ -n "$PUBLIC_DOMAIN" ]; then
    echo "   Open: https://${PUBLIC_DOMAIN}:8443"
else
    echo "   Open: https://${EXTERNAL_IP}:8443"
fi
echo "   (You can fine-tune anything at Admin → Settings)"
echo "   ⚠ Log out and back in for Docker permissions to take effect"
echo ""

exit 0
POSTINSTEOF
chmod +x "$DEB_DIR/DEBIAN/postinst"

# prerm: stop services before uninstall
cat > "$DEB_DIR/DEBIAN/prerm" << 'PRERMEOF'
#!/bin/bash
echo "Stopping Winus Intercom services..."
cd /opt/winus-intercom && docker compose down 2>/dev/null || true
exit 0
PRERMEOF
chmod +x "$DEB_DIR/DEBIAN/prerm"

echo -e "  ${GREEN}✓${NC} DEBIAN control files ready"

# ======================== 6. BUILD .DEB ========================
echo -e "${CYAN}[6/6]${NC} Building .deb package..."
cd "$OUTPUT_DIR"
dpkg-deb --build --root-owner-group "$DEB_DIR" "${OUTPUT_DIR}/${PKG}.deb"
DEB_SIZE=$(du -h "${OUTPUT_DIR}/${PKG}.deb" | cut -f1)
rm -rf "$DEB_DIR"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ .deb package ready!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  File: ${CYAN}${PKG}.deb${NC} (${DEB_SIZE})"
echo ""
echo -e "  ${YELLOW}To install on a Ubuntu machine:${NC}"
echo -e "  1. Copy ${PKG}.deb to the machine"
echo -e "  2. sudo dpkg -i ${PKG}.deb"
echo -e "  3. Log out and back in"
echo -e "  4. Open Winus Intercom from the applications menu"
echo ""
echo -e "  ${YELLOW}To uninstall:${NC}"
echo -e "  sudo apt remove winus-intercom"
echo ""
