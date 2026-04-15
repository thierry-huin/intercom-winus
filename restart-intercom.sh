#!/bin/bash
# Winus Intercom - Restart services (useful after network change)
# Stops all services, re-detects IPs, rebuilds and restarts.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

INTERCOM_DIR="/home/thierry/intercom-winus"

echo -e "${YELLOW}🔄 Reiniciando Winus Intercom...${NC}"
echo ""

# ======================== 1. STOP ========================
echo -e "${CYAN}[1/4]${NC} Deteniendo servicios..."
cd "$INTERCOM_DIR"

# Stop bridge if running
if pkill -f "tie-line-bridge/bridge.py" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Bridge detenido"
fi

# Stop Docker containers
docker compose down 2>&1 | tail -3
echo -e "  ${GREEN}✓${NC} Contenedores detenidos"

# ======================== 2. DETECT IP ========================
echo -e "${CYAN}[2/4]${NC} Detectando IP..."

SERVER_IP=""
DOMAIN=$(grep '^PUBLIC_DOMAIN=' "$INTERCOM_DIR/.env" 2>/dev/null | cut -d= -f2)

# Priority: PUBLIC_DOMAIN > Zerotier > Wireguard > Tailscale > LAN
if [ -n "$DOMAIN" ]; then
    SERVER_IP=$(host "$DOMAIN" 2>/dev/null | grep 'has address' | head -1 | awk '{print $NF}')
    if [ -n "$SERVER_IP" ]; then
        echo -e "  ${GREEN}✓${NC} $DOMAIN → $SERVER_IP"
    else
        echo -e "  ${YELLOW}⚠${NC} No se pudo resolver $DOMAIN, usando IP local"
    fi
fi

# Fallback: local interfaces
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show | grep -A2 ' zt' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show | grep -A2 ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show | grep -A2 ' tailscale' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
[ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[\d.]+')
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

OLD_IP=$(grep '^MEDIASOUP_ANNOUNCED_IPS=' "$INTERCOM_DIR/.env" 2>/dev/null | cut -d= -f2)
sed -i '/^MEDIASOUP_ANNOUNCED_IP/d' "$INTERCOM_DIR/.env" 2>/dev/null
echo "MEDIASOUP_ANNOUNCED_IPS=$SERVER_IP" >> "$INTERCOM_DIR/.env"

if [ "$OLD_IP" != "$SERVER_IP" ]; then
    echo -e "  ${YELLOW}⚠ IP cambiada:${NC} $OLD_IP → $SERVER_IP"
else
    echo -e "  ${GREEN}✓${NC} IP: $SERVER_IP"
fi

# ======================== 3. START ========================
echo -e "${CYAN}[3/4]${NC} Arrancando contenedores..."
docker compose up -d --build 2>&1 | tail -5
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} Backend, Nginx y Coturn iniciados"
else
    echo -e "  ${RED}✗${NC} Error arrancando contenedores"
    exit 1
fi

# ======================== 4. WAIT ========================
echo -ne "${CYAN}[4/4]${NC} Esperando backend..."
for i in $(seq 1 15); do
    if docker exec intercom-backend node -e "require('http').get('http://localhost:3000/',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    if [ $i -eq 15 ]; then
        echo -e " ${YELLOW}(timeout)${NC}"
    fi
    sleep 1
    echo -n "."
done

# ======================== DONE ========================
echo ""
echo -e "${GREEN}✅ Winus Intercom reiniciado${NC}"
if [ -n "$DOMAIN" ]; then
    echo -e "${CYAN}   Web:  ${NC}https://$DOMAIN:8443"
fi
echo -e "${CYAN}   IP:   ${NC}$SERVER_IP"
echo ""
echo -e "Pulsa ENTER para cerrar..."
read -r
