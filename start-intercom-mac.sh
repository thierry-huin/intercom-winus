#!/bin/bash
# ============================================================
# Winus Intercom — macOS Launcher
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INTERCOM_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${YELLOW}🎙️  Iniciando Winus Intercom (macOS)...${NC}"

# Detect IPs
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
ZT_IP=$(ifconfig 2>/dev/null | grep -A2 'zt' | grep 'inet ' | awk '{print $2}' | head -1)
WG_IP=$(ifconfig 2>/dev/null | grep -A2 'utun' | grep 'inet ' | grep '10\.' | awk '{print $2}' | head -1)

ANNOUNCED="${LAN_IP}"
[ -n "$ZT_IP" ] && ANNOUNCED="$ANNOUNCED,$ZT_IP"
[ -n "$WG_IP" ] && [ "$WG_IP" != "$LAN_IP" ] && ANNOUNCED="$ANNOUNCED,$WG_IP"

OLD_IPS=$(grep '^MEDIASOUP_ANNOUNCED_IPS=' "$INTERCOM_DIR/.env" 2>/dev/null | cut -d= -f2)
sed -i '' '/^MEDIASOUP_ANNOUNCED_IP/d; /^EXTERNAL_IP/d; /^LOCAL_IP/d' "$INTERCOM_DIR/.env" 2>/dev/null
echo "MEDIASOUP_ANNOUNCED_IPS=$ANNOUNCED" >> "$INTERCOM_DIR/.env"
echo "EXTERNAL_IP=$LAN_IP" >> "$INTERCOM_DIR/.env"
echo "LOCAL_IP=$LAN_IP" >> "$INTERCOM_DIR/.env"

if [ "$OLD_IPS" != "$ANNOUNCED" ]; then
    echo -e "  ${YELLOW}⚠${NC} IPs cambiadas: $OLD_IPS → $ANNOUNCED"
else
    echo -e "  ${GREEN}✓${NC} IPs: $ANNOUNCED"
fi

# Start services
cd "$INTERCOM_DIR"
docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} Servicios iniciados"

# Open browser
sleep 1
URL="https://$LAN_IP:8443"
echo -e "  Abriendo: ${URL}"
open "$URL" 2>/dev/null &

echo -e "\n${GREEN}✅ Winus Intercom iniciado${NC}"
echo -e "${YELLOW}   Web: ${URL}${NC}"
