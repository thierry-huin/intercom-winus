#!/bin/bash
# Winus Intercom - Stop all services

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Deteniendo Winus Intercom...${NC}"

cd /home/thierry/intercom-winus

# Stop Docker services
docker compose down 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} Contenedores detenidos"

# Stop bridge if running
pkill -f "tie-line-bridge/bridge.py" 2>/dev/null && echo -e "  ${GREEN}✓${NC} Bridge detenido"

echo -e "\n${GREEN}✅ Servicios detenidos${NC}"
