#!/bin/bash
set -euo pipefail

# ─── Configuration ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE_NAME="winus-intercom"
VERSION=$(date +%Y%m%d-%H%M)
OUT_DIR="${1:-$SCRIPT_DIR}"
PACKAGE_DIR="$OUT_DIR/${PACKAGE_NAME}-${VERSION}"

echo "╔═══════════════════════════════════════════╗"
echo "║   Winus Intercom – Package Builder        ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "Output: $PACKAGE_DIR"
echo ""

# ─── Create package directory structure ───
mkdir -p "$PACKAGE_DIR"/{docker-images,config,db,web,apk,src,certs,coturn,bridge}

# ─── 1. Export Docker images ───
echo "▸ [1/7] Exporting Docker images..."
for img in intercom-winus-backend:latest intercom-winus-nginx:latest coturn/coturn:latest; do
    safe_name=$(echo "$img" | tr '/:' '_')
    if docker image inspect "$img" &>/dev/null; then
        echo "  Saving $img..."
        docker save "$img" | gzip > "$PACKAGE_DIR/docker-images/${safe_name}.tar.gz"
    else
        echo "  ⚠ Image $img not found, skipping"
    fi
done

# ─── 2. Copy web build ───
echo "▸ [2/7] Copying web build..."
if [ -d "$SCRIPT_DIR/flutter_app/build/web" ]; then
    cp -r "$SCRIPT_DIR/flutter_app/build/web/." "$PACKAGE_DIR/web/"
    # Copy legacy HTML frontend (intercom.html, admin.html) WITHOUT overwriting Flutter index.html
    if [ -d "$SCRIPT_DIR/frontend" ]; then
        cp "$SCRIPT_DIR/frontend/intercom.html" "$PACKAGE_DIR/web/" 2>/dev/null || true
        cp "$SCRIPT_DIR/frontend/admin.html" "$PACKAGE_DIR/web/" 2>/dev/null || true
        cp -r "$SCRIPT_DIR/frontend/css" "$PACKAGE_DIR/web/" 2>/dev/null || true
        mkdir -p "$PACKAGE_DIR/web/js"
        cp "$SCRIPT_DIR/frontend/js/"*.js "$PACKAGE_DIR/web/js/" 2>/dev/null || true
        echo "  Legacy frontend merged (intercom.html, admin.html)"
    fi
else
    echo "  ⚠ Web build not found – run 'flutter build web --release' first"
fi

# ─── 3. Copy APK ───
echo "▸ [3/7] Copying APK..."
if [ -f "$SCRIPT_DIR/nginx/downloads/intercom.apk" ]; then
    cp "$SCRIPT_DIR/nginx/downloads/intercom.apk" "$PACKAGE_DIR/apk/intercom.apk"
else
    echo "  ⚠ APK not found at nginx/downloads/intercom.apk"
fi

# ─── 4. Copy source/config for rebuild capability ───
echo "▸ [4/7] Copying source & config..."
# docker-compose and main scripts
cp "$SCRIPT_DIR/docker-compose.yml" "$PACKAGE_DIR/"
cp "$SCRIPT_DIR/intercom.sh" "$PACKAGE_DIR/"
cp "$SCRIPT_DIR/.env" "$PACKAGE_DIR/config/env.example"
# Backend source (for rebuild)
rsync -a --exclude='node_modules' --exclude='db' "$SCRIPT_DIR/backend/" "$PACKAGE_DIR/src/backend/"
# Nginx config
rsync -a --exclude='certs' --exclude='downloads' "$SCRIPT_DIR/nginx/" "$PACKAGE_DIR/src/nginx/"
# Coturn config
cp "$SCRIPT_DIR/coturn/turnserver.conf" "$PACKAGE_DIR/coturn/"
# Tie-line bridge
rsync -a --exclude='__pycache__' "$SCRIPT_DIR/tie-line-bridge/" "$PACKAGE_DIR/bridge/"

# ─── 5. Copy database ───
echo "▸ [5/7] Copying database..."
# Stop WAL checkpoint for clean copy
docker exec intercom-backend sh -c 'sqlite3 /app/db/intercom.db "PRAGMA wal_checkpoint(TRUNCATE);"' 2>/dev/null || true
if [ -f "$SCRIPT_DIR/backend/db/intercom.db" ]; then
    cp "$SCRIPT_DIR/backend/db/intercom.db" "$PACKAGE_DIR/db/intercom.db"
fi

# ─── 6. Copy SSL certs (for reference, new server should regenerate) ───
echo "▸ [6/7] Copying SSL certificates..."
if [ -d "$SCRIPT_DIR/nginx/certs" ]; then
    cp "$SCRIPT_DIR/nginx/certs/"*.pem "$PACKAGE_DIR/certs/" 2>/dev/null || true
fi

# ─── 7. Create installer script ───
echo "▸ [7/7] Creating installer..."
cat > "$PACKAGE_DIR/install.sh" << 'INSTALLER'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DIR="${1:-/opt/winus-intercom}"

echo "╔═══════════════════════════════════════════╗"
echo "║   Winus Intercom – Installer              ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "Install directory: $INSTALL_DIR"
echo ""

# ─── Check Docker ───
if ! command -v docker &>/dev/null; then
    echo "✗ Docker is not installed. Install it first:"
    echo "  curl -fsSL https://get.docker.com | sh"
    echo "  sudo usermod -aG docker \$USER"
    exit 1
fi
echo "✓ Docker found: $(docker --version)"

if ! docker compose version &>/dev/null; then
    echo "✗ Docker Compose plugin not found."
    exit 1
fi
echo "✓ Docker Compose found"

# ─── Create install directory ───
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(whoami):$(whoami)" "$INSTALL_DIR"

# ─── Load Docker images ───
echo ""
echo "▸ Loading Docker images..."
for img in "$SCRIPT_DIR"/docker-images/*.tar.gz; do
    [ -f "$img" ] || continue
    echo "  Loading $(basename "$img")..."
    docker load < "$img"
done

# ─── Copy project structure ───
echo "▸ Setting up project..."
cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/intercom.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/intercom.sh"

# Backend source (for future rebuilds)
mkdir -p "$INSTALL_DIR/backend"
cp -r "$SCRIPT_DIR/src/backend/." "$INSTALL_DIR/backend/"

# Nginx config
mkdir -p "$INSTALL_DIR/nginx"
cp -r "$SCRIPT_DIR/src/nginx/." "$INSTALL_DIR/nginx/"

# Coturn
mkdir -p "$INSTALL_DIR/coturn"
cp "$SCRIPT_DIR/coturn/turnserver.conf" "$INSTALL_DIR/coturn/"

# Web build
mkdir -p "$INSTALL_DIR/flutter_app/build/web"
cp -r "$SCRIPT_DIR/web/." "$INSTALL_DIR/flutter_app/build/web/"

# APK download
mkdir -p "$INSTALL_DIR/nginx/downloads"
if [ -f "$SCRIPT_DIR/apk/intercom.apk" ]; then
    cp "$SCRIPT_DIR/apk/intercom.apk" "$INSTALL_DIR/nginx/downloads/intercom.apk"
fi

# Bridge
mkdir -p "$INSTALL_DIR/tie-line-bridge"
cp -r "$SCRIPT_DIR/bridge/." "$INSTALL_DIR/tie-line-bridge/"

# ─── Database ───
echo "▸ Setting up database..."
mkdir -p "$INSTALL_DIR/backend/db"
if [ -f "$SCRIPT_DIR/db/intercom.db" ]; then
    read -p "  Import existing database? (y/n) [n]: " USE_DB
    if [[ "${USE_DB:-n}" =~ ^[yY] ]]; then
        cp "$SCRIPT_DIR/db/intercom.db" "$INSTALL_DIR/backend/db/"
        echo "  ✓ Database imported"
    else
        echo "  ✓ Clean start (database will be created on first run)"
    fi
else
    echo "  ✓ Clean start (no database in package)"
fi

# ─── SSL Certificates ───
echo "▸ Setting up SSL certificates..."
mkdir -p "$INSTALL_DIR/nginx/certs"
if [ -f "$SCRIPT_DIR/certs/cert.pem" ] && [ -f "$SCRIPT_DIR/certs/key.pem" ]; then
    read -p "  Use packaged certificates? (y/n) [n]: " USE_CERTS
    if [[ "${USE_CERTS:-n}" =~ ^[yY] ]]; then
        cp "$SCRIPT_DIR/certs/"*.pem "$INSTALL_DIR/nginx/certs/"
        echo "  ✓ Certificates imported"
    else
        echo "  Generating new self-signed certificate..."
        GENERATE_CERT=yes
    fi
else
    GENERATE_CERT=yes
fi

if [ "${GENERATE_CERT:-}" = "yes" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$INSTALL_DIR/nginx/certs/key.pem" \
        -out "$INSTALL_DIR/nginx/certs/cert.pem" \
        -subj "/CN=winus-intercom" \
        -addext "subjectAltName=IP:${SERVER_IP},IP:127.0.0.1" \
        2>/dev/null
    echo "  ✓ Self-signed certificate generated for IP $SERVER_IP"
fi

# ─── Environment file ───
echo "▸ Configuring environment..."
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$SCRIPT_DIR/config/env.example" "$INSTALL_DIR/.env"
    # Auto-detect IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if ! grep -q "^MEDIASOUP_ANNOUNCED_IP=" "$INSTALL_DIR/.env"; then
        echo "MEDIASOUP_ANNOUNCED_IP=$SERVER_IP" >> "$INSTALL_DIR/.env"
    fi
    echo "  ✓ .env created (edit $INSTALL_DIR/.env to customize)"
else
    echo "  ✓ .env already exists, not overwriting"
fi

# ─── Summary ───
echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   Installation complete!                  ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "  Location:  $INSTALL_DIR"
echo "  Config:    $INSTALL_DIR/.env"
echo ""
echo "  To start:  cd $INSTALL_DIR && ./intercom.sh start"
echo "  To stop:   cd $INSTALL_DIR && ./intercom.sh stop"
echo "  Logs:      cd $INSTALL_DIR && ./intercom.sh logs"
echo ""
echo "  Web app:   https://<server-ip>:8443"
echo "  APK:       https://<server-ip>:8443/intercom.apk"
echo ""
echo "  Bridge:    See $INSTALL_DIR/tie-line-bridge/README.md"
echo ""
INSTALLER
chmod +x "$PACKAGE_DIR/install.sh"

# ─── Create README ───
cat > "$PACKAGE_DIR/README.md" << 'README'
# Winus Intercom – Deployment Package

## Quick Install

```bash
# 1. Copy this folder to the target server
# 2. Run the installer:
sudo bash install.sh /opt/winus-intercom

# 3. Edit configuration if needed:
nano /opt/winus-intercom/.env

# 4. Start:
cd /opt/winus-intercom
./intercom.sh start
```

## Requirements
- Ubuntu 20.04+ (or any Linux with Docker)
- Docker Engine + Docker Compose plugin
- Ports: 8443 (HTTPS), 8080 (HTTP), 3478 (TURN), 10000-10200/udp (media)

## Contents
- `docker-images/` – Pre-built Docker images (no internet needed)
- `web/` – Pre-built Flutter web app
- `apk/` – Android APK installer
- `src/` – Source code (for rebuilds)
- `bridge/` – Tie-line bridge application
- `db/` – Database snapshot
- `certs/` – SSL certificates
- `config/` – Environment template
- `install.sh` – Automated installer
- `intercom.sh` – Service management script

## Post-Install
- Access web app: `https://<server-ip>:8443`
- Download APK: `https://<server-ip>:8443/intercom.apk`
- Default login: admin / admin (change in .env before first start)
README

# ─── Final archive ───
echo ""
echo "▸ Creating archive..."
ARCHIVE="$OUT_DIR/${PACKAGE_NAME}-${VERSION}.tar.gz"
tar czf "$ARCHIVE" -C "$OUT_DIR" "$(basename "$PACKAGE_DIR")"

# Show results
ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║   Package created successfully!           ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "  Archive:  $ARCHIVE"
echo "  Size:     $ARCHIVE_SIZE"
echo ""
echo "  To deploy on another server:"
echo "    1. Copy $ARCHIVE to the target server"
echo "    2. tar xzf $(basename "$ARCHIVE")"
echo "    3. cd $(basename "$PACKAGE_DIR")"
echo "    4. sudo bash install.sh"
echo ""

# Cleanup temp dir
rm -rf "$PACKAGE_DIR"
