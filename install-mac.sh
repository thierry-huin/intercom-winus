#!/bin/bash
# ============================================================
# Winus Intercom — macOS Installer
# Usage: bash install-mac.sh
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — macOS Installer        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ---- 1. Docker Desktop ----
echo -e "${CYAN}[1/5]${NC} Checking Docker..."
if ! command -v docker &>/dev/null; then
    echo -e "  ${RED}✗ Docker not found${NC}"
    echo -e "  Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
    echo -e "  Then run this script again."
    exit 1
fi
if ! docker info &>/dev/null; then
    echo -e "  ${RED}✗ Docker is not running${NC}"
    echo -e "  Start Docker Desktop and run this script again."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Docker OK"

# ---- 2. SSL certificate ----
# NOTE: the SSL cert is now generated AFTER the network prompt below, so it
# can include EXTERNAL_IP / PUBLIC_DOMAIN in its SAN list. This block only
# leaves the directory ready.
CERT_DIR="$INSTALL_DIR/nginx/certs"
mkdir -p "$CERT_DIR"

# ---- 3. Detect IPs + prompt ----
echo -e "${CYAN}[3/5]${NC} Configuring network..."
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
ZT_IP=$(ifconfig 2>/dev/null | grep -A2 'zt' | grep 'inet ' | awk '{print $2}' | head -1)
WG_IP=$(ifconfig 2>/dev/null | grep -A2 'utun' | grep 'inet ' | grep '10\.' | awk '{print $2}' | head -1)
PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"

AUTO_ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && [ "$WG_IP" != "$LAN_IP" ] && AUTO_ANNOUNCED="$AUTO_ANNOUNCED,$WG_IP"

DEFAULT_EXTERNAL="${PUBLIC_IP:-$LAN_IP}"
DEFAULT_LOCAL="${LAN_IP}"
DEFAULT_ANNOUNCED="${DEFAULT_EXTERNAL}"
[ -n "$LAN_IP" ] && [ "$LAN_IP" != "$DEFAULT_EXTERNAL" ] && DEFAULT_ANNOUNCED="$DEFAULT_EXTERNAL,$LAN_IP"
DEFAULT_DOMAIN=""

INTERACTIVE=no
if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=yes; fi

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

JWT_SECRET=$(openssl rand -hex 32)
cat > "$INSTALL_DIR/.env" << ENVEOF
JWT_SECRET=$JWT_SECRET
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
HTTP_PORT=8180
HTTPS_PORT=8443
TURN_PASSWORD=intercom2024
TURN_USER=intercom
MEDIASOUP_ANNOUNCED_IPS=$MEDIASOUP_ANNOUNCED_IPS
EXTERNAL_IP=$EXTERNAL_IP
LOCAL_IP=$LOCAL_IP
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
ENVEOF
echo -e "  ${GREEN}✓${NC} Announced IPs: $MEDIASOUP_ANNOUNCED_IPS"

# ---- 4. SSL certificate (now that we know EXTERNAL_IP/DOMAIN) + dirs ----
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
mkdir -p "$INSTALL_DIR/backend/db" "$INSTALL_DIR/nginx/downloads"

# ---- 5. Build and start ----
echo -e "${CYAN}[4/5]${NC} Building Docker images..."
cd "$INSTALL_DIR"
docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d --build 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} Services started"

# Wait for backend
echo -n "  Waiting for backend"
for i in $(seq 1 15); do
    if docker exec intercom-backend node -e "require('http').get('http://localhost:3000/',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    [ $i -eq 15 ] && echo -e " ${YELLOW}(timeout)${NC}"
    sleep 1; echo -n "."
done

# ---- 5. Desktop shortcuts ----
echo -e "${CYAN}[5/5]${NC} Creating shortcuts..."
cat > "$INSTALL_DIR/WinusIntercom.command" << CMDEOF
#!/bin/bash
cd "$(dirname "\$0")"
bash start-intercom-mac.sh
CMDEOF
chmod +x "$INSTALL_DIR/WinusIntercom.command"

# Control Center (admin GUI). Requires Python 3 with tkinter. Mac stock
# Python doesn't include tkinter — if missing, point the user to
# `brew install python-tk@3.x` instead of failing the whole install.
if [ -d "$INSTALL_DIR/control_center" ]; then
    chmod +x "$INSTALL_DIR/control_center/launch.sh" 2>/dev/null || true
    cat > "$INSTALL_DIR/WinusControlCenter.command" << CMDEOF
#!/bin/bash
cd "\$(dirname "\$0")"
if ! python3 -c 'import tkinter' 2>/dev/null; then
    osascript -e 'display dialog "Tkinter is missing.\nInstall Python with tkinter, e.g.:\n  brew install python-tk@3.12" buttons {"OK"}'
    exit 1
fi
bash control_center/launch.sh
CMDEOF
    chmod +x "$INSTALL_DIR/WinusControlCenter.command"
    echo -e "  ${GREEN}✓${NC} Control Center launcher: WinusControlCenter.command"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Winus Intercom installed (macOS)!     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Web:    ${CYAN}https://$LAN_IP:8443${NC}"
echo -e "  Admin:  ${CYAN}admin / admin${NC} (¡Cámbiala!)"
echo -e "  Configurar IPs en: Admin → Settings"
echo ""
echo -e "  Para iniciar: ${CYAN}bash $INSTALL_DIR/start-intercom-mac.sh${NC}"
echo -e "  O haz doble clic en: ${CYAN}WinusIntercom.command${NC}"
echo ""
