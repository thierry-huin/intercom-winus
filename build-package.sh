#!/bin/bash
# ============================================================
# Winus Intercom — Build Distribution Package
# Creates a complete .tar.gz ready to deploy on a fresh Ubuntu
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

INTERCOM_DIR="/home/thierry/intercom-winus"
OUTPUT_DIR="/home/thierry"
DATE=$(date +%Y%m%d-%H%M)
PKG_NAME="winus-intercom-${DATE}"

echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — Build Package          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ======================== 1. BUILD WEB ========================
echo -e "${CYAN}[1/5]${NC} Building Flutter web..."
cd "$INTERCOM_DIR/flutter_app"
flutter build web --pwa-strategy=none --release 2>&1 | tail -2
if [ $? -ne 0 ]; then
    echo -e "  ${RED}✗ Web build failed${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Web build OK"

# ======================== 2. BUILD APK ========================
echo -e "${CYAN}[2/5]${NC} Building Android APK..."
flutter build apk --release 2>&1 | tail -2
if [ $? -ne 0 ]; then
    echo -e "  ${RED}✗ APK build failed${NC}"
    exit 1
fi
cp build/app/outputs/flutter-apk/app-release.apk "$INTERCOM_DIR/nginx/downloads/intercom.apk"
echo -e "  ${GREEN}✓${NC} APK build OK ($(du -h "$INTERCOM_DIR/nginx/downloads/intercom.apk" | cut -f1))"

# ======================== 3. CREATE PACKAGE ========================
echo -e "${CYAN}[3/5]${NC} Creating distribution package..."
cd "$OUTPUT_DIR"
tar czf "${PKG_NAME}.tar.gz" \
  --exclude='intercom-winus/flutter_app/build' \
  --exclude='intercom-winus/flutter_app/.dart_tool' \
  --exclude='intercom-winus/flutter_app/.flutter-plugins-dependencies' \
  --exclude='intercom-winus/flutter_app/android/.gradle' \
  --exclude='intercom-winus/flutter_app/android/app/build' \
  --exclude='intercom-winus/backend/node_modules' \
  --exclude='intercom-winus/backend/db/*.db-shm' \
  --exclude='intercom-winus/backend/db/*.db-wal' \
  --exclude='intercom-winus/tie-line-bridge/__pycache__' \
  --exclude='*.tar.gz' \
  intercom-winus/.env \
  intercom-winus/docker-compose.yml \
  intercom-winus/start-intercom.sh \
  intercom-winus/stop-intercom.sh \
  intercom-winus/restart-intercom.sh \
  intercom-winus/backend/ \
  intercom-winus/nginx/ \
  intercom-winus/coturn/ \
  intercom-winus/flutter_app/lib/ \
  intercom-winus/flutter_app/web/ \
  intercom-winus/flutter_app/pubspec.yaml \
  intercom-winus/flutter_app/pubspec.lock \
  intercom-winus/flutter_app/android/ \
  intercom-winus/flutter_app/build/web/ \
  intercom-winus/tie-line-bridge/ \
  2>&1

PKG_SIZE=$(du -h "${PKG_NAME}.tar.gz" | cut -f1)
echo -e "  ${GREEN}✓${NC} Package: ${PKG_NAME}.tar.gz (${PKG_SIZE})"

# ======================== 4. CREATE INSTALLER ========================
echo -e "${CYAN}[4/5]${NC} Creating installer script..."
cat > "$INTERCOM_DIR/install.sh" << 'INSTALL_EOF'
#!/bin/bash
# ============================================================
# Winus Intercom — Installer
# Run on a fresh Ubuntu 22.04/24.04 machine:
#   sudo bash install.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/home/$(logname)/intercom-winus"
REAL_USER=$(logname)

echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — Installer              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run with sudo: sudo bash install.sh${NC}"
    exit 1
fi

# ---- 1. Docker ----
echo -e "${CYAN}[1/6]${NC} Installing Docker..."
if command -v docker &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Docker already installed"
else
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    usermod -aG docker "$REAL_USER"
    echo -e "  ${GREEN}✓${NC} Docker installed"
fi

# ---- 2. Generate SSL certificate ----
echo -e "${CYAN}[2/6]${NC} Generating SSL certificate..."
CERT_DIR="$INSTALL_DIR/nginx/certs"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=Winus Intercom" \
        -addext "subjectAltName=IP:$SERVER_IP,IP:127.0.0.1" 2>/dev/null
    echo -e "  ${GREEN}✓${NC} Certificate generated for $SERVER_IP"
else
    echo -e "  ${GREEN}✓${NC} Certificate already exists"
fi

# ---- 3. Detect IP and configure ----
echo -e "${CYAN}[3/6]${NC} Configuring network..."
SERVER_IP=""
# Zerotier
SERVER_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
# Wireguard
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
# LAN
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+')
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

sed -i '/^MEDIASOUP_ANNOUNCED_IP/d' "$INSTALL_DIR/.env" 2>/dev/null
echo "MEDIASOUP_ANNOUNCED_IPS=$SERVER_IP" >> "$INSTALL_DIR/.env"
echo -e "  ${GREEN}✓${NC} Server IP: $SERVER_IP"

# ---- 4. Fix permissions ----
echo -e "${CYAN}[4/6]${NC} Setting permissions..."
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/start-intercom.sh" "$INSTALL_DIR/stop-intercom.sh" "$INSTALL_DIR/restart-intercom.sh"
echo -e "  ${GREEN}✓${NC} Permissions set"

# ---- 5. Start services ----
echo -e "${CYAN}[5/6]${NC} Starting services..."
cd "$INSTALL_DIR"
su - "$REAL_USER" -c "cd $INSTALL_DIR && docker compose up -d --build" 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} Services started"

# Wait for backend
echo -n "  Waiting for backend"
for i in $(seq 1 15); do
    if docker exec intercom-backend node -e "require('http').get('http://localhost:3000/',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    [ $i -eq 15 ] && echo -e " ${YELLOW}(timeout)${NC}"
    sleep 1
    echo -n "."
done

# ---- 6. Create desktop shortcut ----
echo -e "${CYAN}[6/6]${NC} Creating shortcuts..."
DESKTOP_DIR="/home/$REAL_USER/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_DIR/winus-intercom.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Intercom
Comment=Start Intercom services
Exec=$INSTALL_DIR/start-intercom.sh
Icon=$INSTALL_DIR/flutter_app/web/icons/Icon-512.png
Terminal=true
Categories=AudioVideo;Audio;Network;
EOF

cat > "$DESKTOP_DIR/winus-intercom-restart.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Intercom - Reiniciar
Comment=Restart services and detect network
Exec=$INSTALL_DIR/restart-intercom.sh
Icon=$INSTALL_DIR/flutter_app/web/icons/Icon-512.png
Terminal=true
Categories=AudioVideo;Audio;Network;
EOF

chown -R "$REAL_USER:$REAL_USER" "$DESKTOP_DIR"
echo -e "  ${GREEN}✓${NC} Desktop shortcuts created"

# ---- DONE ----
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Winus Intercom installed!             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Web:         ${CYAN}https://$SERVER_IP:8443${NC}"
echo -e "  Admin:       ${CYAN}admin / admin${NC} (change password!)"
echo -e "  APK:         ${CYAN}https://$SERVER_IP:8443/intercom.apk${NC}"
echo -e "  iOS cert:    ${CYAN}https://$SERVER_IP:8443/cert.pem${NC}"
echo ""
echo -e "  Restart:     ${CYAN}$INSTALL_DIR/restart-intercom.sh${NC}"
echo -e "  Stop:        ${CYAN}$INSTALL_DIR/stop-intercom.sh${NC}"
echo -e "  Bridge:      ${CYAN}cd $INSTALL_DIR/tie-line-bridge && python3 bridge_gui.py${NC}"
echo ""
echo -e "${YELLOW}  ⚠ Log out and back in for Docker permissions to take effect${NC}"
echo ""
INSTALL_EOF

chmod +x "$INTERCOM_DIR/install.sh"

# Add installer to the package
cd "$OUTPUT_DIR"
tar rf "${PKG_NAME}.tar.gz" intercom-winus/install.sh 2>/dev/null || \
  tar czf "${PKG_NAME}.tar.gz" \
    --exclude='intercom-winus/flutter_app/build' \
    --exclude='intercom-winus/flutter_app/.dart_tool' \
    --exclude='intercom-winus/flutter_app/.flutter-plugins-dependencies' \
    --exclude='intercom-winus/flutter_app/android/.gradle' \
    --exclude='intercom-winus/flutter_app/android/app/build' \
    --exclude='intercom-winus/backend/node_modules' \
    --exclude='intercom-winus/backend/db/*.db-shm' \
    --exclude='intercom-winus/backend/db/*.db-wal' \
    --exclude='intercom-winus/tie-line-bridge/__pycache__' \
    --exclude='*.tar.gz' \
    intercom-winus/.env \
    intercom-winus/docker-compose.yml \
    intercom-winus/start-intercom.sh \
    intercom-winus/stop-intercom.sh \
    intercom-winus/restart-intercom.sh \
    intercom-winus/install.sh \
    intercom-winus/backend/ \
    intercom-winus/nginx/ \
    intercom-winus/coturn/ \
    intercom-winus/flutter_app/lib/ \
    intercom-winus/flutter_app/web/ \
    intercom-winus/flutter_app/pubspec.yaml \
    intercom-winus/flutter_app/pubspec.lock \
    intercom-winus/flutter_app/android/ \
    intercom-winus/flutter_app/build/web/ \
    intercom-winus/tie-line-bridge/ \
    2>&1

echo -e "  ${GREEN}✓${NC} Installer added to package"

# ======================== 5. SUMMARY ========================
PKG_SIZE=$(du -h "$OUTPUT_DIR/${PKG_NAME}.tar.gz" | cut -f1)
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Package ready!                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  File: ${CYAN}${PKG_NAME}.tar.gz${NC} (${PKG_SIZE})"
echo ""
echo -e "  ${YELLOW}To deploy on a new Ubuntu machine:${NC}"
echo -e "  1. Copy the .tar.gz to the machine"
echo -e "  2. tar xzf ${PKG_NAME}.tar.gz"
echo -e "  3. sudo bash intercom-winus/install.sh"
echo ""
