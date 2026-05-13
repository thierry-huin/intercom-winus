#!/bin/bash
# ============================================================
# Winus Intercom — Control Center launcher
#   - Creates a local venv on first run
#   - Installs customtkinter if missing
#   - Launches the GUI
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv"

# 1. Create venv if missing
if [ ! -d "$VENV" ]; then
    echo "▸ Creando venv en $VENV..."
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet customtkinter
fi

# 2. Ensure customtkinter present (in case the venv existed but was broken)
if ! "$VENV/bin/python" -c "import customtkinter" 2>/dev/null; then
    echo "▸ Instalando customtkinter..."
    "$VENV/bin/pip" install --quiet customtkinter
fi

# 3. Launch the GUI
exec "$VENV/bin/python" "$SCRIPT_DIR/control_center.py" "$@"
