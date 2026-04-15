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
echo -e "${CYAN}[2/5]${NC} Generating SSL certificate..."
CERT_DIR="$INSTALL_DIR/nginx/certs"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
    LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -nodes -subj "/CN=Winus Intercom" \
        -addext "subjectAltName=IP:$LAN_IP,IP:127.0.0.1" 2>/dev/null
    echo -e "  ${GREEN}✓${NC} Certificate generated for $LAN_IP"
else
    echo -e "  ${GREEN}✓${NC} Certificate already exists"
fi

# ---- 3. Detect IPs ----
echo -e "${CYAN}[3/5]${NC} Configuring network..."
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
ZT_IP=$(ifconfig 2>/dev/null | grep -A2 'zt' | grep 'inet ' | awk '{print $2}' | head -1)
WG_IP=$(ifconfig 2>/dev/null | grep -A2 'utun' | grep 'inet ' | grep '10\.' | awk '{print $2}' | head -1)

ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && ANNOUNCED="$ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && [ "$WG_IP" != "$LAN_IP" ] && ANNOUNCED="$ANNOUNCED,$WG_IP"

JWT_SECRET=$(openssl rand -hex 32)
cat > "$INSTALL_DIR/.env" << ENVEOF
JWT_SECRET=$JWT_SECRET
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
HTTP_PORT=8180
HTTPS_PORT=8443
TURN_PASSWORD=intercom2024
TURN_USER=intercom
MEDIASOUP_ANNOUNCED_IPS=$ANNOUNCED
EXTERNAL_IP=$LAN_IP
LOCAL_IP=$LAN_IP
ENVEOF
echo -e "  ${GREEN}✓${NC} Announced IPs: $ANNOUNCED"

# ---- 4. Directories ----
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
