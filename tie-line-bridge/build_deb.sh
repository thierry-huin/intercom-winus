#!/bin/bash
# ============================================================
# Build .deb package for TieLine Bridge
# Usage: bash build_deb.sh
# Output: tieline-bridge_1.0_all.deb
# ============================================================

set -e

VERSION="3.2.2"
PKG_NAME="tieline-bridge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/${PKG_NAME}_${VERSION}_all"

echo "▸ Building $PKG_NAME $VERSION .deb package..."

# Clean
rm -rf "$BUILD_DIR"

# ---- Directory structure ----
mkdir -p "$BUILD_DIR/DEBIAN"
mkdir -p "$BUILD_DIR/opt/tieline-bridge"
mkdir -p "$BUILD_DIR/etc/systemd/system"
mkdir -p "$BUILD_DIR/usr/local/bin"
mkdir -p "$BUILD_DIR/usr/share/applications"

# ---- DEBIAN/control ----
cat > "$BUILD_DIR/DEBIAN/control" << EOF
Package: $PKG_NAME
Version: $VERSION
Section: sound
Priority: optional
Architecture: all
Depends: python3 (>= 3.9), python3-venv, python3-pip, python3-dev, portaudio19-dev, libopus-dev, libopus0, alsa-utils
Maintainer: Intercom Admin <admin@intercom.local>
Description: TieLine Bridge - Audio Matrix Bridge for IP Intercom
 Bridges multi-channel audio hardware (Dante, MADI, etc.)
 to the intercom server via PlainTransport RTP/Opus.
 Includes systemd service and CLI management tool.
EOF

# ---- DEBIAN/postinst (runs after install) ----
cat > "$BUILD_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e

INSTALL_DIR="/opt/tieline-bridge"
SERVICE_USER="tieline"

# Create service user if not exists
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --groups audio "$SERVICE_USER"
    echo "Created user: $SERVICE_USER"
fi

# Create venv and install Python deps
if [ ! -d "$INSTALL_DIR/.venv" ]; then
    python3 -m venv "$INSTALL_DIR/.venv"
fi
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip 2>/dev/null
"$INSTALL_DIR/.venv/bin/pip" install --quiet sounddevice numpy websockets aiohttp 2>/dev/null
"$INSTALL_DIR/.venv/bin/pip" install --quiet customtkinter Pillow 2>/dev/null

# Set ownership
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Enable service
systemctl daemon-reload
systemctl enable tieline-bridge 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ TieLine Bridge instalado              ║"
echo "║                                          ║"
echo "║   tieline wizard  → Configurar           ║"
echo "║   tieline start   → Iniciar              ║"
echo "║   tieline gui     → Interfaz gráfica     ║"
echo "║   tieline logs    → Ver logs             ║"
echo "╚══════════════════════════════════════════╝"
echo ""
EOF
chmod 755 "$BUILD_DIR/DEBIAN/postinst"

# ---- DEBIAN/prerm (runs before uninstall) ----
cat > "$BUILD_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/bash
set -e
systemctl stop tieline-bridge 2>/dev/null || true
systemctl disable tieline-bridge 2>/dev/null || true
EOF
chmod 755 "$BUILD_DIR/DEBIAN/prerm"

# ---- DEBIAN/postrm (runs after uninstall) ----
cat > "$BUILD_DIR/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
if [ "$1" = "purge" ]; then
    rm -rf /opt/tieline-bridge
    userdel tieline 2>/dev/null || true
    echo "TieLine Bridge completely removed."
fi
systemctl daemon-reload
EOF
chmod 755 "$BUILD_DIR/DEBIAN/postrm"

# ---- Application files ----
for f in bridge.py bridge_gui.py audio_engine.py channel.py opus_codec.py rtp_handler.py \
         requirements.txt config_wizard.sh README.md logo.png; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$BUILD_DIR/opt/tieline-bridge/"
    fi
done
chmod +x "$BUILD_DIR/opt/tieline-bridge/config_wizard.sh"

# Default config (won't overwrite existing via dpkg conffiles)
if [ -f "$SCRIPT_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$BUILD_DIR/opt/tieline-bridge/config.json"
fi

# Mark config as conffile (dpkg won't overwrite on upgrade)
cat > "$BUILD_DIR/DEBIAN/conffiles" << EOF
/opt/tieline-bridge/config.json
EOF

# ---- Systemd service ----
cat > "$BUILD_DIR/etc/systemd/system/tieline-bridge.service" << EOF
[Unit]
Description=TieLine Bridge - Intercom Audio Matrix Bridge
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=tieline
Group=audio
WorkingDirectory=/opt/tieline-bridge
ExecStart=/opt/tieline-bridge/.venv/bin/python3 /opt/tieline-bridge/bridge.py --config /opt/tieline-bridge/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SupplementaryGroups=audio
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# ---- CLI tool ----
cat > "$BUILD_DIR/usr/local/bin/tieline" << 'EOF'
#!/bin/bash
SERVICE="tieline-bridge"
CONFIG="/opt/tieline-bridge/config.json"

case "${1:-help}" in
    start)
        sudo systemctl start $SERVICE
        echo "▸ Servicio iniciado"
        sudo systemctl status $SERVICE --no-pager -l
        ;;
    stop)
        sudo systemctl stop $SERVICE
        echo "▸ Servicio detenido"
        ;;
    restart)
        sudo systemctl restart $SERVICE
        echo "▸ Servicio reiniciado"
        ;;
    status)
        sudo systemctl status $SERVICE --no-pager -l
        ;;
    logs)
        sudo journalctl -u $SERVICE -f --no-pager
        ;;
    config)
        if [ -n "$EDITOR" ]; then
            sudo $EDITOR "$CONFIG"
        else
            sudo nano "$CONFIG"
        fi
        echo ""
        echo "Para aplicar cambios: tieline restart"
        ;;
    wizard)
        sudo bash /opt/tieline-bridge/config_wizard.sh
        ;;
    devices)
        sudo -u tieline /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge.py --list-devices
        ;;
    test)
        echo "▸ Modo interactivo (Ctrl+C para parar)..."
        sudo -u tieline /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge.py --config "$CONFIG"
        ;;
    gui)
        echo "▸ Abriendo interfaz gráfica..."
        /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge_gui.py
        ;;
    *)
        echo "TieLine Bridge - Comandos:"
        echo ""
        echo "  tieline start     Iniciar servicio"
        echo "  tieline stop      Detener servicio"
        echo "  tieline restart   Reiniciar servicio"
        echo "  tieline status    Ver estado"
        echo "  tieline logs      Ver logs en tiempo real"
        echo "  tieline config    Editar configuración"
        echo "  tieline wizard    Asistente de configuración"
        echo "  tieline devices   Listar dispositivos de audio"
        echo "  tieline test      Ejecutar interactivo"
        echo "  tieline gui       Abrir interfaz gráfica"
        echo ""
        ;;
esac
EOF
chmod 755 "$BUILD_DIR/usr/local/bin/tieline"

# ---- Desktop shortcut ----
cat > "$BUILD_DIR/usr/share/applications/tieline-bridge.desktop" << EOF
[Desktop Entry]
Name=TieLine Bridge
Comment=Audio Matrix Bridge - Intercom
Exec=/opt/tieline-bridge/.venv/bin/python3 /opt/tieline-bridge/bridge_gui.py
Icon=/opt/tieline-bridge/logo.png
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
EOF

# ---- Build .deb ----
dpkg-deb --build "$BUILD_DIR"

# Move to script dir
mv "$BUILD_DIR.deb" "$SCRIPT_DIR/${PKG_NAME}_${VERSION}_all.deb"
rm -rf "$SCRIPT_DIR/build"

echo ""
echo "✓ Paquete creado: ${PKG_NAME}_${VERSION}_all.deb"
echo ""
echo "  Instalar:      sudo dpkg -i ${PKG_NAME}_${VERSION}_all.deb"
echo "  Dependencias:  sudo apt-get install -f"
echo "  Configurar:    tieline wizard"
echo "  Desinstalar:   sudo apt remove $PKG_NAME"
echo "  Purgar:        sudo apt purge $PKG_NAME"
