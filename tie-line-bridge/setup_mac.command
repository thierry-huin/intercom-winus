#!/bin/bash
# ============================================================
# Tie Line Bridge — macOS Auto-Installer
# Double-click this file to install everything automatically.
# No technical knowledge required.
# ============================================================

trap 'echo ""; echo "❌ Error en la instalación. Revisa los mensajes arriba."; echo ""; read -p "Presiona Enter para cerrar..."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TieLine Bridge"
VENV_DIR="$SCRIPT_DIR/.venv"

clear
echo "╔══════════════════════════════════════════╗"
echo "║   Tie Line Bridge v3.2.2 — macOS          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ---- 1. Homebrew ----
echo "▸ [1/6] Verificando Homebrew..."
if ! command -v brew &>/dev/null; then
    echo "  Instalando Homebrew (puede pedir tu contraseña)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        SHELL_PROFILE="$HOME/.zprofile"
        if ! grep -q 'homebrew' "$SHELL_PROFILE" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_PROFILE"
        fi
    fi
    echo "  ✓ Homebrew instalado"
else
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    echo "  ✓ Homebrew OK"
fi

# ---- 2. System dependencies ----
echo "▸ [2/6] Instalando dependencias del sistema..."
for pkg in python@3.12 python-tk@3.12 portaudio opus; do
    if ! brew list "$pkg" &>/dev/null; then
        echo "  Instalando $pkg..."
        brew install "$pkg" 2>/dev/null
    fi
done
echo "  ✓ Python 3.12, PortAudio, Opus OK"

PY=""
for p in /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12; do
    if [ -x "$p" ]; then PY="$p"; break; fi
done
if [ -z "$PY" ]; then
    echo "❌ python3.12 no encontrado. Intenta: brew install python@3.12"
    read -p "Presiona Enter para cerrar..."
    exit 1
fi
echo "  Python: $($PY --version)"

# ---- 3. Virtual environment ----
echo "▸ [3/6] Configurando entorno Python..."
if [ -d "$VENV_DIR" ]; then
    VENV_PY_VER=$("$VENV_DIR/bin/python3" --version 2>/dev/null || echo "none")
    if [[ "$VENV_PY_VER" != *"3.12"* ]]; then
        echo "  Actualizando entorno a Python 3.12..."
        rm -rf "$VENV_DIR"
    fi
fi
if [ ! -d "$VENV_DIR" ]; then
    "$PY" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
echo "  ✓ Entorno virtual OK"

# ---- 4. Python packages ----
echo "▸ [4/6] Instalando paquetes Python..."
pip install --quiet --upgrade pip 2>/dev/null
pip install --quiet sounddevice numpy websockets aiohttp customtkinter Pillow 2>/dev/null
echo "  ✓ Paquetes Python OK"

# ---- 5. Create .app bundle ----
echo "▸ [5/6] Creando aplicación..."
APP_DIR="$HOME/Desktop/$APP_NAME.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"

# Create a .command inside the .app that Terminal can open
cat > "$APP_RESOURCES/run.command" << RUN_EOF
#!/bin/bash
if [ -f /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
fi
cd "$SCRIPT_DIR"
source "$VENV_DIR/bin/activate"
python3 "$SCRIPT_DIR/bridge_gui.py"
RUN_EOF
chmod +x "$APP_RESOURCES/run.command"

# App executable just opens the .command via Terminal
cat > "$APP_MACOS/launch" << 'LAUNCH_EOF'
#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
open -a Terminal "$DIR/run.command"
LAUNCH_EOF
chmod +x "$APP_MACOS/launch"

# Info.plist
cat > "$APP_CONTENTS/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TieLine Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>TieLine Bridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.intercom.tieline-bridge</string>
    <key>CFBundleVersion</key>
    <string>3.2.2</string>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TieLine Bridge necesita acceso al micrófono para capturar audio de la matriz.</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
PLIST_EOF

# Generate .icns from logo.png if available
LOGO="$SCRIPT_DIR/logo.png"
if [ -f "$LOGO" ]; then
    echo "  Generando icono de la aplicación..."
    ICONSET="$APP_RESOURCES/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$LOGO" --out "$ICONSET/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     "$LOGO" --out "$ICONSET/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     "$LOGO" --out "$ICONSET/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     "$LOGO" --out "$ICONSET/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   "$LOGO" --out "$ICONSET/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   "$LOGO" --out "$ICONSET/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   "$LOGO" --out "$ICONSET/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   "$LOGO" --out "$ICONSET/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   "$LOGO" --out "$ICONSET/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 "$LOGO" --out "$ICONSET/icon_512x512@2x.png" > /dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null
    rm -rf "$ICONSET"
    echo "  ✓ Icono de app generado"
fi

echo "  ✓ Aplicación creada en el Escritorio"

# ---- 6. Backup .command launcher ----
echo "▸ [6/6] Creando lanzador de respaldo..."
LAUNCHER="$HOME/Desktop/$APP_NAME.command"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
if [ -f /opt/homebrew/bin/brew ]; then
    eval "\$(/opt/homebrew/bin/brew shellenv)"
fi
source "$VENV_DIR/bin/activate"
python3 "$SCRIPT_DIR/bridge_gui.py"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
echo "  ✓ Lanzador .command creado"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   ✓ Instalación completada               ║"
echo "╠══════════════════════════════════════════╣"
echo "║                                          ║"
echo "║   En el Escritorio encontrarás:          ║"
echo "║                                          ║"
echo "║   📦 TieLine Bridge.app                  ║"
echo "║   📄 TieLine Bridge.command (respaldo)   ║"
echo "║                                          ║"
echo "║   Doble-click en cualquiera para abrir.  ║"
echo "║                                          ║"
echo "║   Al abrir, pulsa '↻ Usuarios' para      ║"
echo "║   cargar la lista de usuarios.           ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
read -p "Presiona Enter para cerrar..."
