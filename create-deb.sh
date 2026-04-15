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
VERSION="1.0.$(date +%Y%m%d)"
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
echo -e "${CYAN}[1/5]${NC} Building Flutter web..."
cd "$INTERCOM_DIR/flutter_app"
flutter build web --pwa-strategy=none --release 2>&1 | tail -2
if [ $? -ne 0 ]; then echo -e "  ${RED}✗ Web build failed${NC}"; exit 1; fi
echo -e "  ${GREEN}✓${NC} Web build OK"

# ======================== 2. BUILD APK ========================
echo -e "${CYAN}[2/5]${NC} Building Android APK..."
flutter build apk --release 2>&1 | tail -2
if [ $? -ne 0 ]; then echo -e "  ${RED}✗ APK build failed${NC}"; exit 1; fi
cp build/app/outputs/flutter-apk/app-release.apk "$INTERCOM_DIR/nginx/downloads/intercom.apk"
echo -e "  ${GREEN}✓${NC} APK OK ($(du -h "$INTERCOM_DIR/nginx/downloads/intercom.apk" | cut -f1))"

# ======================== 3. PREPARE DEB STRUCTURE ========================
echo -e "${CYAN}[3/5]${NC} Preparing .deb structure..."
rm -rf "$DEB_DIR"
APP_DIR="$DEB_DIR/opt/winus-intercom"
mkdir -p "$APP_DIR"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/usr/local/bin"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/512x512/apps"

# Copy application files
rsync -a --exclude='flutter_app/.dart_tool' \
         --exclude='flutter_app/build/app' \
         --exclude='flutter_app/android/.gradle' \
         --exclude='backend/node_modules' \
         --exclude='backend/db/*.db' \
         --exclude='backend/db/*.db-shm' \
         --exclude='backend/db/*.db-wal' \
         --exclude='tie-line-bridge/__pycache__' \
         --exclude='tie-line-bridge/.venv' \
         --exclude='*.tar.gz' \
         --exclude='.env' \
         "$INTERCOM_DIR/" "$APP_DIR/"

# Copy built web app
mkdir -p "$APP_DIR/flutter_app/build"
rsync -a "$INTERCOM_DIR/flutter_app/build/web/" "$APP_DIR/flutter_app/build/web/"

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

echo -e "  ${GREEN}✓${NC} File structure ready"

# ======================== 4. DEBIAN CONTROL ========================
echo -e "${CYAN}[4/5]${NC} Creating DEBIAN control files..."

PKG_SIZE=$(du -sk "$APP_DIR" | cut -f1)

cat > "$DEB_DIR/DEBIAN/control" << CONTROLEOF
Package: winus-intercom
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Installed-Size: ${PKG_SIZE}
Depends: docker-ce | docker.io, openssl, curl
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
         "$APP_DIR/create-deb.sh" 2>/dev/null || true

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

# Detect IPs
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
ZT_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
WG_IP=$(ip -4 addr show 2>/dev/null | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && ANNOUNCED="$ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && ANNOUNCED="$ANNOUNCED,$WG_IP"

sed -i '/^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d' "$ENV_FILE"
echo "MEDIASOUP_ANNOUNCED_IPS=${ANNOUNCED}" >> "$ENV_FILE"
echo "EXTERNAL_IP=${LAN_IP}" >> "$ENV_FILE"
echo "LOCAL_IP=${LAN_IP}" >> "$ENV_FILE"

# Generate SSL certificate
CERT_DIR="$APP_DIR/nginx/certs"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=Winus Intercom" \
        -addext "subjectAltName=IP:${LAN_IP},IP:127.0.0.1" 2>/dev/null || true
fi

# Create downloads dir
mkdir -p "$APP_DIR/nginx/downloads"
mkdir -p "$APP_DIR/backend/db"

# Fix ownership
chown -R "$REAL_USER:$REAL_USER" "$APP_DIR" 2>/dev/null || true

# Build and start Docker services
echo "Building Docker images (this may take a few minutes)..."
cd "$APP_DIR"
if id "$REAL_USER" &>/dev/null && [ "$REAL_USER" != "root" ]; then
    su - "$REAL_USER" -c "cd $APP_DIR && docker compose up -d --build" || true
else
    docker compose up -d --build || true
fi

echo ""
echo "✅ Winus Intercom installed!"
echo "   Open: https://${LAN_IP}:8443"
echo "   Configure network IPs in Admin → Settings"
echo "   ⚠ Log out and back in for Docker permissions"
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

# ======================== 5. BUILD .DEB ========================
echo -e "${CYAN}[5/5]${NC} Building .deb package..."
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
