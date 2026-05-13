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

# ---- 2. SSL certificate (deferred until after we know EXTERNAL_IP) ----
CERT_DIR="$INSTALL_DIR/nginx/certs"
mkdir -p "$CERT_DIR"

# ---- 3. Detect IPs and configure ----
echo -e "${CYAN}[3/6]${NC} Configuring network..."
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
ZT_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
WG_IP=$(ip -4 addr show 2>/dev/null | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"

AUTO_ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$WG_IP"

DEFAULT_EXTERNAL="${PUBLIC_IP:-$LAN_IP}"
DEFAULT_LOCAL="${LAN_IP}"
DEFAULT_ANNOUNCED="${DEFAULT_EXTERNAL}"
[ -n "$LAN_IP" ] && [ "$LAN_IP" != "$DEFAULT_EXTERNAL" ] && DEFAULT_ANNOUNCED="$DEFAULT_EXTERNAL,$LAN_IP"
DEFAULT_DOMAIN=""

INTERACTIVE=no
if [ -t 0 ] && [ -t 1 ] && [ "${DEBIAN_FRONTEND}" != "noninteractive" ]; then
    INTERACTIVE=yes
fi

ask() {
    local __var="$1"; local __prompt="$2"; local __default="$3"; local __answer=""
    if [ "$INTERACTIVE" = "yes" ]; then
        if [ -n "$__default" ]; then
            read -r -p "  $__prompt [$__default]: " __answer </dev/tty || __answer=""
        else
            read -r -p "  $__prompt: " __answer </dev/tty || __answer=""
        fi
    fi
    [ -z "$__answer" ] && __answer="$__default"
    eval "$__var=\"\$__answer\""
}

if [ "$INTERACTIVE" = "yes" ]; then
    echo ""
    echo "─────────────────────────────────────────────"
    echo " Winus Intercom — server network configuration"
    echo "─────────────────────────────────────────────"
    echo "Press Enter to accept the default shown in brackets."
    echo ""
fi

ask EXTERNAL_IP "Public IP or domain clients will use (EXTERNAL_IP)" "$DEFAULT_EXTERNAL"
ask LOCAL_IP    "Local/private IP of this server (LOCAL_IP)"         "$DEFAULT_LOCAL"
ask MEDIASOUP_ANNOUNCED_IPS "Mediasoup announced IPs (comma-separated)" "$DEFAULT_ANNOUNCED"
ask PUBLIC_DOMAIN "Optional public domain (Enter to skip)" "$DEFAULT_DOMAIN"

# Generate secrets + persist .env
JWT_SECRET=$(openssl rand -hex 32)
touch "$INSTALL_DIR/.env"
sed -i '/^JWT_SECRET=/d; /^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d; /^PUBLIC_DOMAIN/d' "$INSTALL_DIR/.env" 2>/dev/null
echo "JWT_SECRET=$JWT_SECRET" >> "$INSTALL_DIR/.env"
echo "MEDIASOUP_ANNOUNCED_IPS=$MEDIASOUP_ANNOUNCED_IPS" >> "$INSTALL_DIR/.env"
echo "EXTERNAL_IP=${EXTERNAL_IP}" >> "$INSTALL_DIR/.env"
echo "LOCAL_IP=${LOCAL_IP}" >> "$INSTALL_DIR/.env"
echo "PUBLIC_DOMAIN=${PUBLIC_DOMAIN}" >> "$INSTALL_DIR/.env"
echo -e "  ${GREEN}✓${NC} Announced IPs: $MEDIASOUP_ANNOUNCED_IPS"

# Now issue the SSL cert with EXTERNAL_IP / DOMAIN in the SAN
if [ ! -f "$CERT_DIR/cert.pem" ]; then
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
        -addext "subjectAltName=${SAN}" 2>/dev/null
    echo -e "  ${GREEN}✓${NC} Certificate generated (SAN: ${SAN})"
fi

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
if [ -n "$PUBLIC_DOMAIN" ]; then
    WEB_URL="https://${PUBLIC_DOMAIN}:8443"
else
    WEB_URL="https://${EXTERNAL_IP:-$LAN_IP}:8443"
fi
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
