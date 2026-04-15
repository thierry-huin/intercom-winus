#!/bin/bash
if [ -f /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
BRIDGE_DIR="$(dirname "$0")"
if [ ! -f "$BRIDGE_DIR/bridge_gui.py" ]; then
    BRIDGE_DIR="$HOME/Projects/intercom-flutter/tie-line-bridge"
fi
cd "$BRIDGE_DIR"
source "$BRIDGE_DIR/.venv/bin/activate"
python3 "$BRIDGE_DIR/bridge_gui.py"
