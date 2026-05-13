#!/bin/bash
# ============================================================
# Server Bridge — Linux Installer (Ubuntu/Debian)
# Run: sudo bash setup_server_bridge_linux.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/server-bridge"
SERVICE_NAME="server-bridge"
VENV_DIR="$INSTALL_DIR/.venv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"

clear
echo "╔══════════════════════════════════════════╗"
echo "║   Server Bridge — Linux Installer        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- 1. System dependencies ----
echo "▸ [1/5] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip > /dev/null 2>&1
ok "Python 3 installed"

# ---- 2. Install application ----
echo "▸ [2/5] Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

for f in server_bridge.py server_bridge_gui.py rtp_handler.py logo.png; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/"
    fi
done

# Config (don't overwrite existing)
if [ ! -f "$INSTALL_DIR/server_bridge.json" ]; then
    if [ -f "$SCRIPT_DIR/server_bridge.json" ]; then
        cp "$SCRIPT_DIR/server_bridge.json" "$INSTALL_DIR/"
    else
        cat > "$INSTALL_DIR/server_bridge.json" << 'CFGEOF'
{
  "server_a": "https://server-a:8443",
  "server_b": "https://server-b:8443",
  "links": [
    {
      "label": "Link 1",
      "a_username": "bridge_b_1",
      "a_password": "changeme",
      "a_target_type": "user",
      "a_target_id": 0,
      "b_username": "bridge_a_1",
      "b_password": "changeme",
      "b_target_type": "user",
      "b_target_id": 0
    }
  ]
}
CFGEOF
    fi
fi

chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
ok "Files installed"

# ---- 3. Python venv ----
echo "▸ [3/5] Setting up Python environment..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null
"$VENV_DIR/bin/pip" install --quiet websockets aiohttp customtkinter Pillow 2>/dev/null
chown -R "$REAL_USER:$REAL_USER" "$VENV_DIR"
ok "Dependencies installed (CLI + GUI)"

# ---- 4. Systemd service ----
echo "▸ [4/5] Configuring systemd service..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << SERVICE_EOF
[Unit]
Description=Winus Server Bridge - Inter-server audio bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/server_bridge.py --config $INSTALL_DIR/server_bridge.json
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
ok "Service '$SERVICE_NAME' installed and enabled"

# ---- 5. Management command ----
echo "▸ [5/5] Creating management command..."
cat > "/usr/local/bin/server-bridge" << 'CMD_EOF'
#!/bin/bash
SERVICE="server-bridge"
CONFIG="/opt/server-bridge/server_bridge.json"

case "${1:-help}" in
    start)   sudo systemctl start $SERVICE && echo "▸ Started" && sudo systemctl status $SERVICE --no-pager -l ;;
    stop)    sudo systemctl stop $SERVICE && echo "▸ Stopped" ;;
    restart) sudo systemctl restart $SERVICE && echo "▸ Restarted" ;;
    status)  sudo systemctl status $SERVICE --no-pager -l ;;
    logs)    sudo journalctl -u $SERVICE -f --no-pager ;;
    config)  ${EDITOR:-nano} "$CONFIG"; echo ""; echo "Run: server-bridge restart" ;;
    test)
        echo "▸ Running interactively (Ctrl+C to stop)..."
        /opt/server-bridge/.venv/bin/python3 /opt/server-bridge/server_bridge.py --config "$CONFIG"
        ;;
    gui)
        echo "▸ Opening GUI..."
        /opt/server-bridge/.venv/bin/python3 /opt/server-bridge/server_bridge_gui.py
        ;;
    *)
        echo "Server Bridge — Commands:"
        echo ""
        echo "  server-bridge start     Start service (headless)"
        echo "  server-bridge stop      Stop service"
        echo "  server-bridge restart   Restart service"
        echo "  server-bridge status    Show status"
        echo "  server-bridge logs      Live logs"
        echo "  server-bridge config    Edit configuration"
        echo "  server-bridge test      Run interactively (CLI)"
        echo "  server-bridge gui       Open GUI"
        echo ""
        ;;
esac
CMD_EOF
chmod +x /usr/local/bin/server-bridge

# Desktop entry
DESKTOP_DIR="/usr/share/applications"
cat > "$DESKTOP_DIR/server-bridge.desktop" << DSKEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Winus Server Bridge
Comment=Connect two Winus Intercom servers
Exec=/opt/server-bridge/.venv/bin/python3 /opt/server-bridge/server_bridge_gui.py
Icon=${INSTALL_DIR}/logo.png
Terminal=false
Categories=AudioVideo;Audio;Network;
DSKEOF

ok "Command 'server-bridge' and desktop entry created"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ Installation complete                ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   1. Edit config:                        ║"
echo "║      server-bridge config                ║"
echo "║                                          ║"
echo "║   2. Test interactively:                 ║"
echo "║      server-bridge test                  ║"
echo "║                                          ║"
echo "║   3. Run as service:                     ║"
echo "║      server-bridge start                 ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
