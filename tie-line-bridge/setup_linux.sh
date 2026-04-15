#!/bin/bash
# ============================================================
# Tie Line Bridge — Linux Installer (Ubuntu/Debian)
# Run: sudo bash setup_linux.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/tieline-bridge"
SERVICE_NAME="tieline-bridge"
SERVICE_USER="tieline"
VENV_DIR="$INSTALL_DIR/.venv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Este instalador necesita permisos de administrador."
    echo "Ejecuta: sudo bash $0"
    exit 1
fi

clear
echo "╔══════════════════════════════════════════╗"
echo "║   Tie Line Bridge v3.2.2 — Linux          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- 1. System dependencies ----
echo "▸ [1/6] Instalando dependencias del sistema..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip python3-dev \
    portaudio19-dev libopus-dev libopus0 alsa-utils > /dev/null 2>&1
ok "Dependencias del sistema instaladas"

# Verify Python version
PY_VER=$(python3 --version 2>&1 | grep -oP '\d+\.\d+')
echo "  Python: $(python3 --version)"

# ---- 2. Create service user ----
echo "▸ [2/6] Creando usuario del servicio..."
if id "$SERVICE_USER" &>/dev/null; then
    ok "Usuario '$SERVICE_USER' ya existe"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --groups audio "$SERVICE_USER"
    ok "Usuario '$SERVICE_USER' creado (grupo audio)"
fi

# ---- 3. Install application ----
echo "▸ [3/6] Instalando aplicación en $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Copy application files
for f in bridge.py bridge_gui.py audio_engine.py channel.py opus_codec.py rtp_handler.py requirements.txt logo.png; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/"
    fi
done

# Copy config if not already present (don't overwrite existing config)
if [ ! -f "$INSTALL_DIR/config.json" ]; then
    if [ -f "$SCRIPT_DIR/config.json" ]; then
        cp "$SCRIPT_DIR/config.json" "$INSTALL_DIR/"
    fi
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
ok "Archivos copiados a $INSTALL_DIR"

# ---- 4. Python virtual environment ----
echo "▸ [4/6] Configurando entorno Python..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null
"$VENV_DIR/bin/pip" install --quiet sounddevice numpy websockets aiohttp 2>/dev/null
# GUI dependencies
"$VENV_DIR/bin/pip" install --quiet customtkinter Pillow 2>/dev/null
chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR"
ok "Entorno virtual y paquetes instalados (CLI + GUI)"

# ---- 5. Systemd service ----
echo "▸ [5/6] Configurando servicio systemd..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << SERVICE_EOF
[Unit]
Description=Tie Line Bridge - Intercom Audio Matrix Bridge
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=audio
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/bridge.py --config $INSTALL_DIR/config.json
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Audio access
SupplementaryGroups=audio
AmbientCapabilities=

# Environment
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
ok "Servicio '$SERVICE_NAME' instalado y habilitado"

# ---- 6. Management scripts ----
echo "▸ [6/6] Creando scripts de gestión..."

# tieline command
cat > "/usr/local/bin/tieline" << 'CMD_EOF'
#!/bin/bash
# Tie Line Bridge management command
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
        echo "Para aplicar los cambios: tieline restart"
        ;;
    wizard)
        sudo bash /opt/tieline-bridge/config_wizard.sh
        ;;
    devices)
        sudo -u tieline /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge.py --list-devices
        ;;
    test)
        echo "▸ Ejecutando bridge en modo interactivo (Ctrl+C para parar)..."
        sudo -u tieline /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge.py --config "$CONFIG"
        ;;
    gui)
        echo "▸ Abriendo interfaz gráfica..."
        /opt/tieline-bridge/.venv/bin/python3 \
            /opt/tieline-bridge/bridge_gui.py
        ;;
    *)
        echo "Tie Line Bridge - Comandos:"
        echo ""
        echo "  tieline start     Iniciar servicio"
        echo "  tieline stop      Detener servicio"
        echo "  tieline restart   Reiniciar servicio"
        echo "  tieline status    Ver estado del servicio"
        echo "  tieline logs      Ver logs en tiempo real"
        echo "  tieline config    Editar configuración"
        echo "  tieline wizard    Asistente de configuración"
        echo "  tieline devices   Listar dispositivos de audio"
        echo "  tieline test      Ejecutar en modo interactivo"
        echo "  tieline gui       Abrir interfaz gráfica"
        echo ""
        ;;
esac
CMD_EOF
chmod +x /usr/local/bin/tieline
ok "Comando 'tieline' instalado"

# Desktop shortcut for GUI
if [ -d "/usr/share/applications" ]; then
    cat > "/usr/share/applications/tieline-bridge.desktop" << DESKTOP_EOF
[Desktop Entry]
Name=TieLine Bridge
Comment=Audio Matrix Bridge - Intercom
Exec=/opt/tieline-bridge/.venv/bin/python3 /opt/tieline-bridge/bridge_gui.py
Icon=/opt/tieline-bridge/logo.png
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
DESKTOP_EOF
    ok "Acceso directo creado en menú de aplicaciones"
fi

# ---- Interactive config wizard ----
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ Instalación completada               ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   Comandos disponibles:                  ║"
echo "║                                          ║"
echo "║   tieline wizard   → Configurar          ║"
echo "║   tieline devices  → Ver dispositivos    ║"
echo "║   tieline start    → Iniciar servicio    ║"
echo "║   tieline stop     → Detener servicio    ║"
echo "║   tieline logs     → Ver logs            ║"
echo "║   tieline config   → Editar config       ║"
echo "║   tieline test     → Modo interactivo    ║"
echo "║   tieline gui      → Interfaz gráfica    ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Ask if user wants to run config wizard now
read -p "¿Deseas configurar ahora? (s/N): " RUN_WIZARD
if [[ "$RUN_WIZARD" =~ ^[sS]$ ]]; then
    bash "$INSTALL_DIR/config_wizard.sh"
fi
