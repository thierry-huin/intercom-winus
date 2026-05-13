#!/bin/bash
# ============================================================
# Winus Intercom — Deploy on Proxmox
# Loads pre-built Docker images and starts all services.
# No compilation or build required on the target machine.
#
# Usage: sudo bash deploy-proxmox.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/winus-intercom"
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — Proxmox Deploy             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ======================== 0. PREREQUISITES ========================
echo -e "${CYAN}[1/6]${NC} Checking prerequisites..."

# Install Docker if not present
if ! command -v docker &>/dev/null; then
    echo -e "  ${YELLOW}Docker not found. Installing...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo -e "  ${GREEN}✓${NC} Docker installed"
else
    echo -e "  ${GREEN}✓${NC} Docker already installed"
fi

# Install docker compose plugin if missing
if ! docker compose version &>/dev/null; then
    echo -e "  ${YELLOW}Installing Docker Compose plugin...${NC}"
    apt-get update && apt-get install -y docker-compose-plugin
    echo -e "  ${GREEN}✓${NC} Docker Compose installed"
fi

# Add user to docker group
if id "$REAL_USER" &>/dev/null; then
    usermod -aG docker "$REAL_USER" 2>/dev/null || true
fi

# Install openssl if missing
if ! command -v openssl &>/dev/null; then
    apt-get update && apt-get install -y openssl
fi

# ======================== 1. LOAD IMAGES ========================
echo -e "${CYAN}[2/6]${NC} Loading pre-built Docker images..."

if [ -f "$SCRIPT_DIR/docker-images.tar" ]; then
    docker load -i "$SCRIPT_DIR/docker-images.tar"
    echo -e "  ${GREEN}✓${NC} Docker images loaded"
else
    echo -e "  ${RED}✗ docker-images.tar not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# ======================== 2. INSTALL FILES ========================
echo -e "${CYAN}[3/6]${NC} Installing application files..."

mkdir -p "$APP_DIR"
mkdir -p "$APP_DIR/backend/db"
mkdir -p "$APP_DIR/nginx/certs"
mkdir -p "$APP_DIR/nginx/downloads"
mkdir -p "$APP_DIR/coturn"
mkdir -p "$APP_DIR/flutter_app/build"

# docker-compose (uses image: not build:)
cp "$SCRIPT_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"

# Coturn config
cp "$SCRIPT_DIR/turnserver.conf" "$APP_DIR/coturn/turnserver.conf"

# Flutter web build
rsync -a "$SCRIPT_DIR/flutter-web/" "$APP_DIR/flutter_app/build/web/" 2>/dev/null || \
    cp -r "$SCRIPT_DIR/flutter-web/"* "$APP_DIR/flutter_app/build/web/" 2>/dev/null || true

# Nginx extra files (privacy page)
cp "$SCRIPT_DIR/nginx-conf/privacy.html" "$APP_DIR/nginx/" 2>/dev/null || true

# Utility scripts
for script in start-intercom.sh stop-intercom.sh restart-intercom.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        cp "$SCRIPT_DIR/$script" "$APP_DIR/$script"
        chmod +x "$APP_DIR/$script"
    fi
done

# Control Center
if [ -d "$SCRIPT_DIR/control_center" ]; then
    mkdir -p "$APP_DIR/control_center"
    cp -r "$SCRIPT_DIR/control_center/"* "$APP_DIR/control_center/"
    chmod +x "$APP_DIR/control_center/launch.sh" 2>/dev/null || true
    chmod +x "$APP_DIR/control_center/control_center.py" 2>/dev/null || true

    # Install Python + customtkinter for Control Center
    echo -e "  ${YELLOW}Installing Control Center dependencies...${NC}"
    apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv 2>/dev/null || true
    if [ ! -d "$APP_DIR/control_center/.venv" ]; then
        python3 -m venv "$APP_DIR/control_center/.venv"
        "$APP_DIR/control_center/.venv/bin/pip" install -q customtkinter
    fi
    echo -e "  ${GREEN}✓${NC} Control Center installed"
fi

echo -e "  ${GREEN}✓${NC} Files installed to $APP_DIR"

# ======================== 3. CONFIGURE .env ========================
echo -e "${CYAN}[4/6]${NC} Configuring network..."

ENV_FILE="$APP_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    cp "$SCRIPT_DIR/.env.template" "$ENV_FILE"
    # Generate random JWT secret
    JWT=$(openssl rand -hex 32)
    sed -i "s/CHANGE_ME/$JWT/" "$ENV_FILE"
fi

# Auto-detect IPs
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
ZT_IP=$(ip -4 addr show 2>/dev/null | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
WG_IP=$(ip -4 addr show 2>/dev/null | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"

DEFAULT_EXTERNAL="${PUBLIC_IP:-$LAN_IP}"
DEFAULT_LOCAL="${LAN_IP}"
DEFAULT_ANNOUNCED="${DEFAULT_EXTERNAL}"
[ -n "$LAN_IP" ] && [ "$LAN_IP" != "$DEFAULT_EXTERNAL" ] && DEFAULT_ANNOUNCED="$DEFAULT_EXTERNAL,$LAN_IP"

INTERACTIVE=no
if [ -t 0 ] && [ -t 1 ] && [ "${DEBIAN_FRONTEND}" != "noninteractive" ]; then
    INTERACTIVE=yes
fi

ask() {
    local __var="$1"; local __prompt="$2"; local __default="$3"
    local __answer=""
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
    echo "──────────────────────────────────────────────"
    echo " Network configuration"
    echo "──────────────────────────────────────────────"
    echo "Press Enter to accept the default shown in brackets."
    echo ""
fi

ask EXTERNAL_IP "Public IP or domain (EXTERNAL_IP)" "$DEFAULT_EXTERNAL"
ask LOCAL_IP    "Local/private IP (LOCAL_IP)"        "$DEFAULT_LOCAL"
ask MEDIASOUP_ANNOUNCED_IPS "Mediasoup announced IPs (comma-separated)" "$DEFAULT_ANNOUNCED"
ask PUBLIC_DOMAIN "Public domain (leave blank if none)" ""

sed -i '/^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d; /^PUBLIC_DOMAIN/d' "$ENV_FILE"
echo "MEDIASOUP_ANNOUNCED_IPS=${MEDIASOUP_ANNOUNCED_IPS}" >> "$ENV_FILE"
echo "EXTERNAL_IP=${EXTERNAL_IP}" >> "$ENV_FILE"
echo "LOCAL_IP=${LOCAL_IP}" >> "$ENV_FILE"
echo "PUBLIC_DOMAIN=${PUBLIC_DOMAIN}" >> "$ENV_FILE"

echo -e "  ${GREEN}✓${NC} Network configured"

# ======================== 4. GENERATE SSL CERT ========================
echo -e "${CYAN}[5/6]${NC} Generating SSL certificate..."

CERT_DIR="$APP_DIR/nginx/certs"
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
        -addext "subjectAltName=${SAN}" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Certificate generated"
else
    echo -e "  ${GREEN}✓${NC} Certificate already exists"
fi

# ======================== 5. START SERVICES ========================
echo -e "${CYAN}[6/6]${NC} Starting services..."

chown -R "$REAL_USER:$REAL_USER" "$APP_DIR" 2>/dev/null || true

cd "$APP_DIR"
# NO --build flag — uses pre-loaded images
docker compose up -d

sleep 3
docker compose ps

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Winus Intercom deployed!                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
if [ -n "$PUBLIC_DOMAIN" ]; then
    echo -e "  Open: ${CYAN}https://${PUBLIC_DOMAIN}:8443${NC}"
else
    echo -e "  Open: ${CYAN}https://${EXTERNAL_IP}:8443${NC}"
fi
echo ""
echo -e "  ${YELLOW}Management:${NC}"
echo -e "  docker compose -f $APP_DIR/docker-compose.yml logs -f"
echo -e "  docker compose -f $APP_DIR/docker-compose.yml restart"
echo ""

exit 0
