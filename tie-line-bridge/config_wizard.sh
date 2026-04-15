#!/bin/bash
# ============================================================
# Tie Line Bridge — Config Wizard
# Interactive configuration for headless Linux deployments.
# ============================================================

INSTALL_DIR="/opt/tieline-bridge"
CONFIG="$INSTALL_DIR/config.json"
VENV_PY="$INSTALL_DIR/.venv/bin/python3"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   TieLine Bridge — Asistente de Config   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- Server URL ----
CURRENT_SERVER=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('server',''))" 2>/dev/null || echo "")
read -p "URL del servidor [$CURRENT_SERVER]: " SERVER
SERVER="${SERVER:-$CURRENT_SERVER}"
if [ -z "$SERVER" ]; then
    read -p "URL del servidor (ej: https://192.168.4.8:8443): " SERVER
fi

# ---- Audio devices ----
echo ""
echo "Dispositivos de audio disponibles:"
echo "─────────────────────────────────────"
sudo -u tieline "$VENV_PY" "$INSTALL_DIR/bridge.py" --list-devices 2>/dev/null || \
    "$VENV_PY" "$INSTALL_DIR/bridge.py" --list-devices 2>/dev/null
echo ""

CURRENT_INPUT=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('input_device','default'))" 2>/dev/null || echo "default")
read -p "Dispositivo de entrada (nombre o ID) [$CURRENT_INPUT]: " INPUT_DEV
INPUT_DEV="${INPUT_DEV:-$CURRENT_INPUT}"

CURRENT_OUTPUT=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('output_device','default'))" 2>/dev/null || echo "default")
read -p "Dispositivo de salida (nombre o ID) [$CURRENT_OUTPUT]: " OUTPUT_DEV
OUTPUT_DEV="${OUTPUT_DEV:-$CURRENT_OUTPUT}"

CURRENT_NUMCH=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('num_device_channels',16))" 2>/dev/null || echo "16")
read -p "Número de canales del dispositivo [$CURRENT_NUMCH]: " NUM_CH
NUM_CH="${NUM_CH:-$CURRENT_NUMCH}"

# ---- Channels ----
echo ""
echo "Configuración de canales"
echo "─────────────────────────────────────"
echo "Cada canal conecta un canal de la matriz a un usuario del intercom."
echo "(Deja usuario vacío para terminar)"
echo ""

CHANNELS="["
CH_NUM=1
while true; do
    read -p "Canal $CH_NUM — Usuario (ej: MTX_$CH_NUM): " CH_USER
    if [ -z "$CH_USER" ]; then
        break
    fi

    read -p "  Password [changeme]: " CH_PASS
    CH_PASS="${CH_PASS:-changeme}"

    read -p "  Tipo de target (user/group) [user]: " CH_TTYPE
    CH_TTYPE="${CH_TTYPE:-user}"

    read -p "  Target ID (número): " CH_TID
    CH_TID="${CH_TID:-0}"

    read -p "  VOX threshold dB [-40]: " CH_VOX
    CH_VOX="${CH_VOX:--40}"

    if [ "$CH_NUM" -gt 1 ]; then
        CHANNELS="$CHANNELS,"
    fi

    CHANNELS="$CHANNELS
    {
      \"index\": $CH_NUM,
      \"username\": \"$CH_USER\",
      \"password\": \"$CH_PASS\",
      \"target_type\": \"$CH_TTYPE\",
      \"target_id\": $CH_TID,
      \"vox_threshold_db\": $CH_VOX,
      \"vox_hold_ms\": 300
    }"

    CH_NUM=$((CH_NUM + 1))
    echo ""
done

CHANNELS="$CHANNELS
  ]"

# ---- Write config ----
cat > "$CONFIG" << CONFIG_EOF
{
  "server": "$SERVER",
  "input_device": "$INPUT_DEV",
  "output_device": "$OUTPUT_DEV",
  "num_device_channels": $NUM_CH,
  "sample_rate": 48000,
  "channels": $CHANNELS
}
CONFIG_EOF

chown tieline:tieline "$CONFIG" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ Configuración guardada               ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   Archivo: $CONFIG"
echo "║                                          ║"
echo "║   Comandos:                              ║"
echo "║     tieline test    → Probar             ║"
echo "║     tieline start   → Iniciar servicio   ║"
echo "║     tieline logs    → Ver logs           ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

read -p "¿Probar ahora? (s/N): " TEST_NOW
if [[ "$TEST_NOW" =~ ^[sS]$ ]]; then
    echo "Ejecutando bridge (Ctrl+C para parar)..."
    sudo -u tieline "$VENV_PY" "$INSTALL_DIR/bridge.py" --config "$CONFIG"
fi
