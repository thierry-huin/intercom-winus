#!/bin/bash
set -e

# ============================================================
# Intercom - Empaquetador
# Crea un archivo .tar.gz listo para instalar en otro servidor
# Incluye: servidor (Docker), frontend, tieline bridge
# Uso: ./package.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error(){ echo -e "${RED}[✗]${NC} $1"; exit 1; }

VERSION=$(date +%Y%m%d-%H%M)
PKG_NAME="intercom-${VERSION}"
PKG_DIR="/tmp/${PKG_NAME}"
OUTPUT="${SCRIPT_DIR}/${PKG_NAME}.tar.gz"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Intercom — Empaquetador v$VERSION      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- 1. Verificar que el frontend está compilado ----
if [ ! -f "flutter_app/build/web/index.html" ]; then
    error "Frontend no compilado. Ejecuta primero:
    cd flutter_app && flutter build web --release"
fi
log "Frontend compilado encontrado"

# ---- 2. Build tieline .deb ----
if [ -f "tie-line-bridge/build_deb.sh" ]; then
    log "Construyendo TieLine Bridge .deb..."
    bash tie-line-bridge/build_deb.sh
fi

# ---- 3. Preparar directorio temporal ----
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# ---- 4. Copiar backend ----
mkdir -p "$PKG_DIR/backend"
cp -r backend/src "$PKG_DIR/backend/src"
cp backend/package.json "$PKG_DIR/backend/"
cp backend/package-lock.json "$PKG_DIR/backend/" 2>/dev/null || true
cp backend/Dockerfile "$PKG_DIR/backend/"
mkdir -p "$PKG_DIR/backend/db"
log "Backend copiado"

# ---- 5. Copiar nginx ----
mkdir -p "$PKG_DIR/nginx/certs"
cp nginx/Dockerfile "$PKG_DIR/nginx/"
# Generate nginx.conf that uses Docker service name (not host.docker.internal)
sed 's/host\.docker\.internal:3000/backend:3000/g' nginx/nginx.conf > "$PKG_DIR/nginx/nginx.conf"
log "Nginx copiado (proxy → backend:3000)"

# ---- 6. Copiar coturn ----
mkdir -p "$PKG_DIR/coturn"
cp coturn/turnserver.conf "$PKG_DIR/coturn/"
log "Coturn copiado"

# ---- 7. Copiar management app ----
if [ -d "management" ] && [ -f "management/server.py" ]; then
    mkdir -p "$PKG_DIR/management"
    cp management/server.py "$PKG_DIR/management/"
    cp management/index.html "$PKG_DIR/management/"
    log "Management app copiada"
fi

# ---- 8. Copiar frontend compilado ----
cp -r flutter_app/build/web "$PKG_DIR/web"
log "Frontend compilado copiado ($(du -sh flutter_app/build/web | cut -f1))"

# ---- 9. Copiar TieLine Bridge ----
mkdir -p "$PKG_DIR/tieline-bridge"
for f in bridge.py bridge_gui.py audio_engine.py channel.py opus_codec.py rtp_handler.py \
         requirements.txt config.json config_wizard.sh setup_mac.command setup_linux.sh \
         setup_windows.bat build_deb.sh README.md; do
    [ -f "tie-line-bridge/$f" ] && cp "tie-line-bridge/$f" "$PKG_DIR/tieline-bridge/"
done
# Include pre-built .deb if available
for deb in tie-line-bridge/tieline-bridge_*.deb; do
    [ -f "$deb" ] && cp "$deb" "$PKG_DIR/tieline-bridge/"
done
# Include logo
[ -f "tie-line-bridge/logo.png" ] && cp "tie-line-bridge/logo.png" "$PKG_DIR/tieline-bridge/"
log "TieLine Bridge copiado"

# ---- 10. Copiar logo a raíz del paquete ----
[ -f "tie-line-bridge/logo.png" ] && cp "tie-line-bridge/logo.png" "$PKG_DIR/logo.png"

# ---- 11. docker-compose.yml ----
cat > "$PKG_DIR/docker-compose.yml" <<'COMPOSE'
services:
  backend:
    build: ./backend
    container_name: intercom-backend
    restart: unless-stopped
    networks:
      - intercom-net
    ports:
      - "10000-10200:10000-10200/udp"
    environment:
      - JWT_SECRET=${JWT_SECRET:-change_this_jwt_secret}
      - ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}
      - MEDIASOUP_ANNOUNCED_IPS=${MEDIASOUP_ANNOUNCED_IPS:-}
      - TURN_PORT=3478
      - TURN_USER=${TURN_USER:-intercom}
      - TURN_PASSWORD=${TURN_PASSWORD:-intercom2024}
    volumes:
      - ./backend/db:/app/db

  nginx:
    build: ./nginx
    container_name: intercom-nginx
    restart: unless-stopped
    networks:
      - intercom-net
    ports:
      - "${HTTP_PORT:-8080}:80"
      - "${HTTPS_PORT:-8443}:443"
    depends_on:
      - backend
    volumes:
      - ./web:/usr/share/nginx/html:ro
      - ./nginx/certs:/etc/nginx/certs:ro

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
        RESOLVED_IP=$$(getent hosts ${EXTERNAL_IP:-localhost} | awk '{print $$1}' | head -1)
        echo "TURN external-ip: $$RESOLVED_IP / ${LOCAL_IP:-127.0.0.1}"
        exec turnserver -c /etc/coturn/turnserver.conf \
          --user=${TURN_USER:-intercom}:${TURN_PASSWORD:-intercom2024} \
          --external-ip=$$RESOLVED_IP/${LOCAL_IP:-127.0.0.1}

networks:
  intercom-net:
    driver: bridge
COMPOSE
log "docker-compose.yml generado"

# ---- 12. Copiar install.sh + intercom.sh ----
cp "$SCRIPT_DIR/install.sh" "$PKG_DIR/install.sh"
chmod +x "$PKG_DIR/install.sh"
cp "$SCRIPT_DIR/intercom.sh" "$PKG_DIR/intercom.sh"
chmod +x "$PKG_DIR/intercom.sh"
[ -f "$SCRIPT_DIR/install-windows.bat" ] && cp "$SCRIPT_DIR/install-windows.bat" "$PKG_DIR/install-windows.bat"
log "Scripts de instalación y gestión incluidos"

# ---- 13. README principal ----
cat > "$PKG_DIR/README.md" <<'README'
# Intercom IP — Sistema de Comunicación

Sistema de intercom IP basado en mediasoup (SFU) con clientes web (Flutter),
Android, iOS y bridge para matrices de audio hardware.

## Contenido del paquete
- **Servidor** — Backend Node.js + mediasoup (Docker)
- **Frontend** — PWA Flutter compilada
- **TURN** — Coturn para NAT traversal
- **TieLine Bridge** — Bridge de audio multicanal (Mac + Linux)

## Instalación rápida del servidor
```bash
chmod +x install.sh
./install.sh
```

El instalador:
1. Instala Docker y Docker Compose si no están presentes
2. Pregunta la IP del servidor, puertos y credenciales admin
3. Genera certificado SSL autofirmado
4. Construye y arranca los contenedores

## Gestión del servidor
```bash
./intercom.sh start     # Arrancar
./intercom.sh stop      # Parar
./intercom.sh restart   # Reiniciar
./intercom.sh rebuild   # Reconstruir contenedores
./intercom.sh logs      # Ver logs
./intercom.sh status    # Ver estado
```

## Puertos
- **8443**: HTTPS (interfaz web + WebSocket)
- **8080**: HTTP
- **10000-10200/UDP**: WebRTC media (mediasoup)
- **3478/UDP+TCP**: TURN server

## Acceso
1. Abrir `https://IP_SERVIDOR:8443` en Chrome
2. Aceptar certificado autofirmado
3. Login como admin para crear usuarios y permisos
4. Cada usuario accede desde su dispositivo

## TieLine Bridge (matrices de audio hardware)
Para conectar matrices Dante, MADI, Blackhole, etc.:

### macOS
```bash
cd tieline-bridge/
# Doble-click en setup_mac.command
```

### Linux
```bash
# Opción A: .deb
sudo dpkg -i tieline-bridge/tieline-bridge_1.0_all.deb
sudo apt-get install -f
tieline wizard

# Opción B: Script
sudo bash tieline-bridge/setup_linux.sh
tieline wizard
```

Ver `tieline-bridge/README.md` para documentación completa del bridge.

## Configuración
Editar `.env` y reiniciar:
```bash
./intercom.sh restart
```
README
log "README.md incluido"

# ---- 14. Empaquetar ----
echo ""
log "Empaquetando..."
cd /tmp
tar czf "$OUTPUT" "$PKG_NAME"
rm -rf "$PKG_DIR"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo ""
echo "╔══════════════════════════════════════════╗"
echo -e "║   ${GREEN}✓ Paquete creado${NC}                       ║"
echo "╠══════════════════════════════════════════╣"
echo -e "║  Archivo: ${CYAN}${PKG_NAME}.tar.gz${NC}"
echo -e "║  Tamaño:  ${SIZE}"
echo "║"
echo "║  Contenido:"
echo "║   ├─ Servidor Intercom (Docker)"
echo "║   ├─ Frontend PWA (Flutter)"
echo "║   ├─ TURN Server (Coturn)"
echo "║   ├─ Management Server"
echo "║   └─ TieLine Bridge (Mac + Linux)"
echo "║"
echo "║  Instalar en otro servidor:"
echo "║   scp ${PKG_NAME}.tar.gz user@server:~/"
echo "║   tar xzf ${PKG_NAME}.tar.gz"
echo "║   cd ${PKG_NAME} && ./install.sh"
echo "║"
echo "╚══════════════════════════════════════════╝"
echo ""
