#!/bin/bash
set -e

# ============================================================
# Intercom Janus - Script de instalación y arranque
# Ejecutar: chmod +x start.sh && ./start.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "========================================="
echo "   Intercom Janus - Setup & Start"
echo "========================================="
echo ""

# ---- 1. Verificar / Instalar Docker ----
if ! command -v docker &>/dev/null; then
    warn "Docker no encontrado. Instalando..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    log "Docker instalado. Si es la primera vez, cierra sesión y vuelve a entrar para usar Docker sin sudo."
else
    log "Docker encontrado: $(docker --version)"
fi

# ---- 2. Verificar Docker Compose ----
if docker compose version &>/dev/null; then
    COMPOSE="docker compose"
    log "Docker Compose (plugin) encontrado"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
    log "docker-compose (standalone) encontrado"
else
    warn "Docker Compose no encontrado. Instalando plugin..."
    sudo apt-get install -y -qq docker-compose-plugin
    COMPOSE="docker compose"
    log "Docker Compose plugin instalado"
fi

# ---- 3. Verificar que el servicio Docker esté corriendo ----
if ! docker info &>/dev/null; then
    warn "El servicio Docker no está corriendo. Iniciando..."
    sudo systemctl start docker
    sudo systemctl enable docker
    log "Servicio Docker iniciado"
fi

# ---- 4. Crear directorios necesarios ----
mkdir -p backend/db
mkdir -p nginx/certs
log "Directorios verificados"

# ---- 4b. Generar certificado SSL autofirmado si no existe ----
if [ ! -f nginx/certs/cert.pem ]; then
    log "Generando certificado SSL autofirmado..."
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout nginx/certs/key.pem \
        -out nginx/certs/cert.pem \
        -subj "/CN=intercom-local" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    log "Certificado SSL generado (autofirmado, válido 10 años)"
else
    log "Certificado SSL existente conservado"
fi

# ---- 5. Crear .env si no existe ----
if [ ! -f .env ]; then
    cat > .env <<EOF
JANUS_API_SECRET=janussecret
JWT_SECRET=$(openssl rand -hex 16)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
HTTP_PORT=8080
EOF
    log "Archivo .env creado con secretos generados"
else
    log "Archivo .env existente conservado"
fi

# ---- 6. Extract Janus.js library from container ----
# Build Janus first so we can extract janus.js
log "Construyendo contenedor Janus para extraer janus.js..."
$COMPOSE build janus
JANUS_CID=$(docker create intercom-winus-janus 2>/dev/null || docker create $(docker compose config --images | grep janus | head -1) 2>/dev/null)
if [ -n "$JANUS_CID" ]; then
    docker cp "$JANUS_CID:/opt/janus/share/janus/javascript/janus.js" frontend/js/janus.js 2>/dev/null
    docker rm "$JANUS_CID" >/dev/null 2>&1
    log "Janus.js extraído del contenedor ($(wc -c < frontend/js/janus.js) bytes)"
else
    warn "No se pudo extraer janus.js del contenedor"
fi

# ---- 7. Build de los contenedores ----
echo ""
log "Construyendo contenedores (puede tardar varios minutos la primera vez)..."
$COMPOSE build

# ---- 8. Arrancar servicios ----
log "Arrancando servicios..."
$COMPOSE up -d

# ---- 9. Leer puertos del .env ----
source .env
_HTTP=${HTTP_PORT:-8080}
_HTTPS=${HTTPS_PORT:-8443}

# ---- 10. Esperar a que el backend esté listo ----
echo -n "[.] Esperando a que el backend esté listo"
for i in $(seq 1 30); do
    if curl -s http://localhost:$_HTTP/api/health | grep -q '"ok"' 2>/dev/null; then
        echo ""
        log "Backend listo"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# ---- 11. Mostrar estado ----
_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================="
echo "   Servicios activos"
echo "========================================="
$COMPOSE ps
echo ""
echo -e "${GREEN}Intercom (local HTTP):${NC}  http://localhost:$_HTTP"
echo -e "${GREEN}Intercom (remoto HTTPS):${NC} https://$_IP:$_HTTPS"
echo -e "${YELLOW}Nota:${NC} HTTPS usa certificado autofirmado — aceptar excepción en el navegador"
echo ""
echo -e "${GREEN}Login admin:${NC} admin / admin (cambiar en .env)"
echo ""
echo "Comandos útiles:"
echo "  $COMPOSE logs -f        # Ver logs en tiempo real"
echo "  $COMPOSE down           # Parar servicios"
echo "  $COMPOSE up -d          # Reiniciar servicios"
echo "  ./start.sh              # Reinstalar/reiniciar todo"
echo ""
