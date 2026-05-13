#!/bin/bash
# ============================================================
# Winus Intercom — Build & Export Docker images
# Builds all Docker images locally and packages them into a
# single .tar.gz ready to deploy on Proxmox (or any Docker host)
# without needing to compile anything on the target machine.
#
# Usage: bash build-and-export.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(date +%Y%m%d.%H%M)"
EXPORT_DIR="/tmp/winus-intercom-deploy-${VERSION}"
ARCHIVE_NAME="winus-intercom-server-${VERSION}.tar.gz"

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Winus Intercom — Build & Export for Proxmox ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ======================== 1. BUILD FLUTTER WEB ========================
echo -e "${CYAN}[1/5]${NC} Building Flutter web app..."
cd "$SCRIPT_DIR/flutter_app"
flutter build web --pwa-strategy=none --release 2>&1 | tail -2
if [ $? -ne 0 ]; then echo -e "  ${RED}✗ Flutter web build failed${NC}"; exit 1; fi
echo -e "  ${GREEN}✓${NC} Flutter web build OK"
cd "$SCRIPT_DIR"

# ======================== 2. BUILD DOCKER IMAGES ========================
echo -e "${CYAN}[2/5]${NC} Building Docker images (this may take a few minutes)..."

# Tag images with a fixed name so we can reference them in the deploy compose
docker compose build backend
echo -e "  ${GREEN}✓${NC} Backend image built"

docker compose build nginx
echo -e "  ${GREEN}✓${NC} Nginx image built"

# Tag images with explicit names for export
BACKEND_IMAGE="winus-intercom-backend:${VERSION}"
NGINX_IMAGE="winus-intercom-nginx:${VERSION}"
BACKEND_IMAGE_LATEST="winus-intercom-backend:latest"
NGINX_IMAGE_LATEST="winus-intercom-nginx:latest"

# Get the compose-generated image names and re-tag them
docker tag winus-intercom-backend:latest "$BACKEND_IMAGE"
docker tag winus-intercom-nginx:latest "$NGINX_IMAGE"

echo -e "  ${GREEN}✓${NC} Images tagged: ${BACKEND_IMAGE}, ${NGINX_IMAGE}"

# ======================== 3. EXPORT IMAGES ========================
echo -e "${CYAN}[3/5]${NC} Exporting Docker images to tar..."

mkdir -p "$EXPORT_DIR"

docker save \
    "$BACKEND_IMAGE_LATEST" "$BACKEND_IMAGE" \
    "$NGINX_IMAGE_LATEST" "$NGINX_IMAGE" \
    coturn/coturn:latest \
    -o "$EXPORT_DIR/docker-images.tar"

IMAGE_SIZE=$(du -h "$EXPORT_DIR/docker-images.tar" | cut -f1)
echo -e "  ${GREEN}✓${NC} Images exported (${IMAGE_SIZE})"

# ======================== 4. PACKAGE DEPLOY FILES ========================
echo -e "${CYAN}[4/5]${NC} Packaging deployment files..."

# docker-compose for deploy (uses image: instead of build:)
cat > "$EXPORT_DIR/docker-compose.yml" << 'COMPOSEEOF'
services:
  backend:
    image: winus-intercom-backend:latest
    container_name: intercom-backend
    restart: unless-stopped
    network_mode: host
    working_dir: /app
    environment:
      - JWT_SECRET=${JWT_SECRET:-change_this_jwt_secret}
      - ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}
      - MEDIASOUP_ANNOUNCED_IPS=${MEDIASOUP_ANNOUNCED_IPS:-}
      - TURN_PORT=3478
      - TURN_USER=${TURN_USER:-intercom}
      - TURN_PASSWORD=${TURN_PASSWORD:-intercom2024}
      - INTERCOM_HOST_DIR=/opt/winus-intercom
      - INTERCOM_COMPOSE_FILE=/app/docker-compose.yml
    volumes:
      - ./backend/db:/app/db
      - ./.env:/app/.env
      - ./docker-compose.yml:/app/docker-compose.yml:ro
      - ./nginx/certs:/app/nginx/certs
      - /var/run/docker.sock:/var/run/docker.sock

  nginx:
    image: winus-intercom-nginx:latest
    container_name: intercom-nginx
    restart: unless-stopped
    networks:
      - intercom-net
    ports:
      - "${HTTP_PORT:-8080}:80"
      - "${HTTPS_PORT:-8443}:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - backend
    volumes:
      - ./flutter_app/build/web:/usr/share/nginx/html:ro
      - ./nginx/certs:/etc/nginx/certs:ro
      - ./nginx/downloads:/usr/share/nginx/downloads:ro

  coturn:
    image: coturn/coturn:latest
    container_name: intercom-coturn
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ -z "${EXTERNAL_IP}" ]; then
          echo "FATAL: EXTERNAL_IP is not set in .env." >&2
          exit 1
        fi
        if [ -z "${LOCAL_IP}" ]; then
          echo "FATAL: LOCAL_IP is not set in .env." >&2
          exit 1
        fi
        RESOLVED_IP=$$(getent hosts ${EXTERNAL_IP} | awk '{print $$1}' | head -1)
        if [ -z "$$RESOLVED_IP" ]; then
          echo "FATAL: Could not resolve EXTERNAL_IP=${EXTERNAL_IP}" >&2
          exit 1
        fi
        echo "TURN external-ip: $$RESOLVED_IP / ${LOCAL_IP}"
        exec turnserver -c /etc/coturn/turnserver.conf \
          --user=${TURN_USER:-intercom}:${TURN_PASSWORD:-intercom2024} \
          --external-ip=$$RESOLVED_IP/${LOCAL_IP}

networks:
  intercom-net:
    driver: bridge
COMPOSEEOF

# Copy config files needed at runtime
cp "$SCRIPT_DIR/coturn/turnserver.conf" "$EXPORT_DIR/turnserver.conf"
cp "$SCRIPT_DIR/.env.template" "$EXPORT_DIR/.env.template"

# Copy Flutter web build
mkdir -p "$EXPORT_DIR/flutter-web"
rsync -a "$SCRIPT_DIR/flutter_app/build/web/" "$EXPORT_DIR/flutter-web/"

# Copy nginx config files
mkdir -p "$EXPORT_DIR/nginx-conf"
cp "$SCRIPT_DIR/nginx/nginx.conf" "$EXPORT_DIR/nginx-conf/"
cp "$SCRIPT_DIR/nginx/privacy.html" "$EXPORT_DIR/nginx-conf/"

# Copy utility scripts
cp "$SCRIPT_DIR/start-intercom.sh" "$EXPORT_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/stop-intercom.sh" "$EXPORT_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/restart-intercom.sh" "$EXPORT_DIR/" 2>/dev/null || true

# Copy Control Center (Python GUI for management)
mkdir -p "$EXPORT_DIR/control_center"
rsync -a "$SCRIPT_DIR/control_center/control_center.py" "$EXPORT_DIR/control_center/" 2>/dev/null || \
    cp "$SCRIPT_DIR/control_center/control_center.py" "$EXPORT_DIR/control_center/" 2>/dev/null || true
rsync -a "$SCRIPT_DIR/control_center/launch.sh" "$EXPORT_DIR/control_center/" 2>/dev/null || \
    cp "$SCRIPT_DIR/control_center/launch.sh" "$EXPORT_DIR/control_center/" 2>/dev/null || true
rsync -a "$SCRIPT_DIR/control_center/README.md" "$EXPORT_DIR/control_center/" 2>/dev/null || true

# Deploy script
cp "$SCRIPT_DIR/deploy-proxmox.sh" "$EXPORT_DIR/"

echo -e "  ${GREEN}✓${NC} Deployment files packaged"

# ======================== 5. CREATE ARCHIVE ========================
echo -e "${CYAN}[5/5]${NC} Creating archive..."

cd /tmp
tar czf "$SCRIPT_DIR/$ARCHIVE_NAME" -C /tmp "winus-intercom-deploy-${VERSION}"
rm -rf "$EXPORT_DIR"

FINAL_SIZE=$(du -h "$SCRIPT_DIR/$ARCHIVE_NAME" | cut -f1)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Export ready!                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  File: ${CYAN}${ARCHIVE_NAME}${NC} (${FINAL_SIZE})"
echo ""
echo -e "  ${YELLOW}To deploy on Proxmox:${NC}"
echo -e "  1. Copy ${ARCHIVE_NAME} to the Proxmox container/VM"
echo -e "  2. tar xzf ${ARCHIVE_NAME}"
echo -e "  3. cd winus-intercom-deploy-*"
echo -e "  4. sudo bash deploy-proxmox.sh"
echo ""
