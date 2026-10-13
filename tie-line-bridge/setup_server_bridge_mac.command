#!/bin/bash
# ============================================================
# Server Bridge — macOS Installer (Apple Silicon + Intel)
# Double-click to install. Connects two Winus Intercom servers.
# ============================================================

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Server Bridge"
VENV_DIR="$SCRIPT_DIR/.venv-server-bridge"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/opt/local' | paste -sd ':' -)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:}$PATH"
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

safe_clear() {
    if [ -x /usr/bin/clear ]; then
        /usr/bin/clear 2>/dev/null || true
    fi
}

die() {
    echo ""
    echo "❌ $*"
    echo ""
    read -r -p "Press Enter to close..." _
    exit 1
}

safe_clear
echo "╔══════════════════════════════════════════╗"
echo "║   Server Bridge — macOS Installer        ║"
echo "║   Arch: ${ARCH}                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

echo "▸ [1/5] Checking Homebrew..."
if ! command -v brew >/dev/null 2>&1; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew install failed"
fi
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null 2>&1 || die "brew not found in PATH"
if [ "$ARCH" = "arm64" ] && [ ! -x /opt/homebrew/bin/brew ]; then
    die "Apple Silicon requires Homebrew at /opt/homebrew"
fi
echo "  ✓ Homebrew OK"

echo "▸ [2/5] Checking Python..."
if ! brew list python@3.12 >/dev/null 2>&1; then
    echo "  Installing python@3.12..."
    brew install python@3.12 || die "brew install python@3.12 failed"
fi

PY=""
for p in \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/bin/python3.12 \
    /usr/local/opt/python@3.12/bin/python3.12 \
    /usr/local/bin/python3.12
do
    [ -x "$p" ] || continue
    if [ "$ARCH" = "arm64" ]; then
        file "$p" 2>/dev/null | grep -qi 'x86_64' && ! file "$p" 2>/dev/null | grep -qi 'arm64' && continue
    fi
    PY="$p"
    break
done
[ -n "$PY" ] || die "Python 3.12 not found"
echo "  ✓ $($PY --version) ($PY)"

echo "▸ [3/5] Setting up Python environment..."
if [ -d "$VENV_DIR" ] && [ "$ARCH" = "arm64" ] && [ -x "$VENV_DIR/bin/python3" ]; then
    if file "$VENV_DIR/bin/python3" 2>/dev/null | grep -qi 'x86_64' \
        && ! file "$VENV_DIR/bin/python3" 2>/dev/null | grep -qi 'arm64'; then
        echo "  Recreating Intel venv on Apple Silicon..."
        rm -rf "$VENV_DIR"
    fi
fi
if [ ! -d "$VENV_DIR" ]; then
    "$PY" -m venv "$VENV_DIR" || die "venv create failed"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate" || die "venv activate failed"
python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
python3 -m pip install --upgrade websockets aiohttp customtkinter Pillow \
    || die "pip install failed"
echo "  ✓ Dependencies installed (CLI + GUI)"

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

echo "▸ [5/5] Creating application..."
APP_DIR="$HOME/Desktop/$APP_NAME.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

cat > "$APP_RESOURCES/run.command" << RUN_EOF
#!/bin/bash
PATH=\$(echo "\$PATH" | tr ':' '\\n' | grep -v '^/opt/local' | paste -sd ':' -)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:\${PATH}"
if [ -x /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "\$(/usr/local/bin/brew shellenv)"
fi
cd "$SCRIPT_DIR" || exit 1
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate" || exit 1
exec python3 "$SCRIPT_DIR/server_bridge_gui.py"
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
    <string>1.0.1</string>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

LOGO=""
for cand in "$SCRIPT_DIR/logo.png" "$SCRIPT_DIR/Logo.png"; do
    [ -f "$cand" ] && LOGO="$cand" && break
done
if [ -n "$LOGO" ]; then
    ICONSET="$APP_RESOURCES/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512 1024; do
        sips -z "$s" "$s" "$LOGO" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
fi

LAUNCHER="$HOME/Desktop/$APP_NAME CLI.command"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
PATH=\$(echo "\$PATH" | tr ':' '\\n' | grep -v '^/opt/local' | paste -sd ':' -)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:\${PATH}"
if [ -x /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "\$(/usr/local/bin/brew shellenv)"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
cd "$SCRIPT_DIR" || exit 1
exec python3 server_bridge.py
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
read -r -p "Press Enter to close..." _
