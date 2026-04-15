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

# ---- 3. Detect IPs and configure ----
echo -e "${CYAN}[3/6]${NC} Configuring network..."
# Public IP via LAN physical interface
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
# ZeroTier
ZT_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
# WireGuard
WG_IP=$(ip -4 addr show 2>/dev/null | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
# Build announced IPs list
SERVER_IP="${LAN_IP}"
[ -n "$ZT_IP" ] && SERVER_IP="$SERVER_IP,$ZT_IP"
[ -n "$WG_IP" ] && SERVER_IP="$SERVER_IP,$WG_IP"

# Generate secrets
JWT_SECRET=$(openssl rand -hex 32)
sed -i '/^JWT_SECRET=/d; /^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d' "$INSTALL_DIR/.env" 2>/dev/null
echo "JWT_SECRET=$JWT_SECRET" >> "$INSTALL_DIR/.env"
echo "MEDIASOUP_ANNOUNCED_IPS=$SERVER_IP" >> "$INSTALL_DIR/.env"
echo "EXTERNAL_IP=${LAN_IP}" >> "$INSTALL_DIR/.env"
echo "LOCAL_IP=${LAN_IP}" >> "$INSTALL_DIR/.env"
echo -e "  ${GREEN}✓${NC} Announced IPs: $SERVER_IP"

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
WEB_URL="https://$LAN_IP:8443"
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Winus Intercom installed!             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Web:         ${CYAN}$WEB_URL${NC}"
echo -e "  Admin:       ${CYAN}admin / admin${NC} (¡Cambia la contraseña en Admin → Users!)"
echo -e "  Network IPs: ${CYAN}Admin → Settings${NC} para configurar IPs"
echo -e "  APK:         ${CYAN}$WEB_URL/intercom.apk${NC}"
echo -e "  iOS cert:    ${CYAN}$WEB_URL/cert.pem${NC}"
echo ""
echo -e "  Restart:     ${CYAN}$INSTALL_DIR/restart-intercom.sh${NC}"
echo -e "  Stop:        ${CYAN}$INSTALL_DIR/stop-intercom.sh${NC}"
echo -e "  Bridge:      ${CYAN}cd $INSTALL_DIR/tie-line-bridge && python3 bridge_gui.py${NC}"
echo ""
echo -e "${YELLOW}  ⚠ Cierra sesión y vuelve a entrar para que los permisos de Docker estén activos${NC}"
echo ""
