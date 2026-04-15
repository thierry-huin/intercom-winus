#!/bin/bash
# Winus Intercom - Launcher
# Starts Docker services and opens the web interface

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INTERCOM_DIR="/home/thierry/intercom-winus"
BRIDGE_DIR="$INTERCOM_DIR/tie-line-bridge"

echo -e "${YELLOW}🎙️  Iniciando Winus Intercom...${NC}"

# 0. Resolver IPs para WebRTC (múltiples candidatos ICE)
# IP pública: desde DNS de huin.tv (siempre actualizado)
PUBLIC_IP=$(host huin.tv 2>/dev/null | grep 'has address' | head -1 | awk '{print $NF}')
# IP LAN (interfaz física)
LAN_IP=$(ip -4 addr show | grep -v ' lo\| wg\| tailscale\| br-\| docker\| veth' | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
# IP WireGuard (para clientes en la VPN)
WG_IP=$(ip -4 addr show | grep ' wg' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)

# Construir lista de IPs anunciadas (sin duplicados, sin vacíos)
ANNOUNCED_IPS="$PUBLIC_IP"
[ -n "$WG_IP" ] && [ "$WG_IP" != "$PUBLIC_IP" ] && ANNOUNCED_IPS="$ANNOUNCED_IPS,$WG_IP"
[ -n "$LAN_IP" ] && [ "$LAN_IP" != "$PUBLIC_IP" ] && ANNOUNCED_IPS="$ANNOUNCED_IPS,$LAN_IP"

LOCAL_IP="${LAN_IP:-$WG_IP}"

OLD_IPS=$(grep '^MEDIASOUP_ANNOUNCED_IPS=' "$INTERCOM_DIR/.env" 2>/dev/null | cut -d= -f2)
sed -i '/^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d' "$INTERCOM_DIR/.env" 2>/dev/null
echo "MEDIASOUP_ANNOUNCED_IPS=$ANNOUNCED_IPS" >> "$INTERCOM_DIR/.env"
echo "EXTERNAL_IP=$PUBLIC_IP" >> "$INTERCOM_DIR/.env"
echo "LOCAL_IP=$LOCAL_IP" >> "$INTERCOM_DIR/.env"

if [ "$OLD_IPS" != "$ANNOUNCED_IPS" ]; then
    echo -e "  ${YELLOW}⚠${NC} IPs cambiadas: $OLD_IPS → $ANNOUNCED_IPS"
else
    echo -e "  ${GREEN}✓${NC} IPs: $ANNOUNCED_IPS"
fi

# 1. Start Docker services
cd "$INTERCOM_DIR"
echo -e "  Levantando contenedores Docker..."
docker compose up -d 2>&1 | tail -5
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} Backend, Nginx y Coturn iniciados"
else
    echo -e "  ${RED}✗${NC} Error arrancando contenedores"
    exit 1
fi

# 2. Wait for backend to be ready
echo -n "  Esperando backend..."
for i in $(seq 1 10); do
    if docker exec intercom-backend node -e "require('http').get('http://localhost:3000/',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))" 2>/dev/null; then
        echo -e " ${GREEN}✓${NC}"
        break
    fi
    if [ $i -eq 10 ]; then
        echo -e " ${YELLOW}(timeout, continuando)${NC}"
    fi
    sleep 1
    echo -n "."
done

# 3. Open browser
sleep 1
URL="https://$(hostname -I | awk '{print $1}'):8443"
echo -e "  Abriendo navegador: ${URL}"
xdg-open "$URL" 2>/dev/null || google-chrome "$URL" 2>/dev/null || firefox "$URL" 2>/dev/null &

echo -e "\n${GREEN}✅ Winus Intercom iniciado${NC}"
echo -e "${YELLOW}   Web: ${URL}${NC}"
echo -e "${YELLOW}   Bridge: cd $BRIDGE_DIR && python3 bridge.py${NC}"
