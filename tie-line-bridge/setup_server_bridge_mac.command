#!/bin/bash
# ============================================================
# Server Bridge — macOS Installer
# Double-click to install. Connects two Winus Intercom servers.
# ============================================================

trap 'echo ""; echo "❌ Error. Check messages above."; read -p "Press Enter to close..."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Server Bridge"
VENV_DIR="$SCRIPT_DIR/.venv-server-bridge"

clear
echo "╔══════════════════════════════════════════╗"
echo "║   Server Bridge — macOS Installer        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- 1. Homebrew ----
echo "▸ [1/5] Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [ -f /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo "  ✓ Homebrew OK"

# ---- 2. Python ----
echo "▸ [2/5] Checking Python..."
for pkg in python@3.12; do
    if ! brew list "$pkg" &>/dev/null; then
        echo "  Installing $pkg..."
        brew install "$pkg" 2>/dev/null
    fi
done

PY=""
for p in /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 python3; do
    if command -v "$p" &>/dev/null; then PY="$p"; break; fi
done
if [ -z "$PY" ]; then
    echo "❌ Python 3 not found."
    read -p "Press Enter to close..."
    exit 1
fi
echo "  ✓ $($PY --version)"

# ---- 3. Virtual environment ----
echo "▸ [3/5] Setting up Python environment..."
if [ ! -d "$VENV_DIR" ]; then
    "$PY" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip 2>/dev/null
pip install --quiet websockets aiohttp customtkinter Pillow 2>/dev/null
echo "  ✓ Dependencies installed (CLI + GUI)"

# ---- 4. Create config template ----
echo "▸ [4/5] Checking configuration..."
CONFIG="$SCRIPT_DIR/server_bridge.json"
if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" << 'CFGEOF'
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
    echo "  ✓ Created server_bridge.json (edit before running!)"
else
    echo "  ✓ server_bridge.json exists"
fi

# ---- 5. Create .app + .command ----
echo "▸ [5/5] Creating application..."
APP_DIR="$HOME/Desktop/$APP_NAME.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

cat > "$APP_RESOURCES/run.command" << RUN_EOF
#!/bin/bash
if [ -f /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
fi
cd "$SCRIPT_DIR"
source "$VENV_DIR/bin/activate"
python3 "$SCRIPT_DIR/server_bridge_gui.py"
RUN_EOF
chmod +x "$APP_RESOURCES/run.command"

cat > "$APP_MACOS/launch" << 'LAUNCH_EOF'
#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
open -a Terminal "$DIR/run.command"
LAUNCH_EOF
chmod +x "$APP_MACOS/launch"

cat > "$APP_CONTENTS/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Server Bridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.intercom.server-bridge</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

# Icon from logo.png
LOGO="$SCRIPT_DIR/logo.png"
if [ -f "$LOGO" ]; then
    ICONSET="$APP_RESOURCES/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512 1024; do
        sips -z $s $s "$LOGO" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null
    rm -rf "$ICONSET"
fi

# CLI .command launcher (headless, for running as background process)
LAUNCHER="$HOME/Desktop/$APP_NAME CLI.command"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
if [ -f /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
fi
source "$VENV_DIR/bin/activate"
cd "$SCRIPT_DIR"
python3 server_bridge.py
LAUNCHER_EOF
chmod +x "$LAUNCHER"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ Installation complete                ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   On your Desktop:                       ║"
echo "║   📦 Server Bridge.app  (GUI)            ║"
echo "║   📄 Server Bridge CLI.command (headless)║"
echo "║                                          ║"
echo "║   1. Edit server_bridge.json first       ║"
echo "║   2. Then double-click to run            ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
read -p "Press Enter to close..."
