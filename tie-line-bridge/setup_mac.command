#!/bin/bash
# ============================================================
# Tie Line Bridge — macOS Auto-Installer (Apple Silicon + Intel)
# Double-click this file to install everything automatically.
# ============================================================

# Don't abort the whole installer on a non-critical failure from `clear`
# or other PATH pollution (e.g. MacPorts Intel binaries under /opt/local).
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TieLine Bridge"
VENV_DIR="$SCRIPT_DIR/.venv"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

# ---- Sanitize PATH (macOS may put MacPorts /opt/local first) ----
# After Apple dropped Rosetta/Intel support on some machines, old
# /opt/local/* binaries fail with: Bad CPU type in executable.
_safe_path_prepend() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1${PATH:+:}$PATH" ;;
    esac
}
# Drop MacPorts from PATH for this script so we never pick Intel-only tools.
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/opt/local' | paste -sd ':' -)
_safe_path_prepend "/usr/bin"
_safe_path_prepend "/bin"
_safe_path_prepend "/usr/sbin"
_safe_path_prepend "/sbin"
# Prefer Apple Silicon Homebrew, then Intel Homebrew.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi
export PATH

safe_clear() {
    if [ -x /usr/bin/clear ]; then
        /usr/bin/clear 2>/dev/null || true
    elif command -v clear >/dev/null 2>&1; then
        _c="$(command -v clear)"
        case "$_c" in
            /opt/local/*) ;;
            *) "$_c" 2>/dev/null || true ;;
        esac
    fi
}

die() {
    echo ""
    echo "❌ $*"
    echo ""
    read -r -p "Presiona Enter para cerrar..." _
    exit 1
}

safe_clear
echo "╔══════════════════════════════════════════╗"
echo "║   Tie Line Bridge v3.7.1 — macOS         ║"
echo "║   Arch: ${ARCH}                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ "$ARCH" = "arm64" ]; then
    echo "  ✓ Apple Silicon detectado (arm64) — se usará Homebrew en /opt/homebrew"
elif [ "$ARCH" = "x86_64" ]; then
    echo "  ⚠ Intel (x86_64). En macOS recientes sin Rosetta, usa un Mac Apple Silicon."
fi
echo ""

# ---- 1. Homebrew ----
echo "▸ [1/6] Verificando Homebrew..."
if ! command -v brew >/dev/null 2>&1; then
    echo "  Instalando Homebrew (puede pedir tu contraseña)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "No se pudo instalar Homebrew"
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        SHELL_PROFILE="$HOME/.zprofile"
        if ! grep -q 'homebrew' "$SHELL_PROFILE" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_PROFILE"
        fi
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    command -v brew >/dev/null 2>&1 || die "Homebrew instalado pero no está en PATH"
    echo "  ✓ Homebrew instalado"
else
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    echo "  ✓ Homebrew OK ($(command -v brew))"
fi

if [ "$ARCH" = "arm64" ] && [ ! -x /opt/homebrew/bin/brew ]; then
    die "En Apple Silicon hace falta Homebrew en /opt/homebrew (no /usr/local ni MacPorts)"
fi

# ---- 2. System dependencies ----
echo "▸ [2/6] Instalando dependencias del sistema..."
for pkg in python@3.12 python-tk@3.12 portaudio opus; do
    if ! brew list "$pkg" >/dev/null 2>&1; then
        echo "  Instalando $pkg..."
        brew install "$pkg" || die "Falló brew install $pkg"
    fi
done
echo "  ✓ Python 3.12, PortAudio, Opus OK"

PY=""
for p in \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/bin/python3.12 \
    /usr/local/opt/python@3.12/bin/python3.12 \
    /usr/local/bin/python3.12
do
    if [ -x "$p" ]; then
        if [ "$ARCH" = "arm64" ]; then
            file "$p" 2>/dev/null | grep -qi 'x86_64' && ! file "$p" 2>/dev/null | grep -qi 'arm64' && continue
        fi
        PY="$p"
        break
    fi
done
if [ -z "$PY" ]; then
    die "python3.12 no encontrado. Intenta: brew install python@3.12"
fi
echo "  Python: $($PY --version)  ($PY)"

# ---- 3. Virtual environment ----
echo "▸ [3/6] Configurando entorno Python..."
if [ -d "$VENV_DIR" ]; then
    VENV_PY_VER="$("$VENV_DIR/bin/python3" --version 2>/dev/null || echo none)"
    NEED_RECREATE=0
    if [[ "$VENV_PY_VER" != *"3.12"* ]]; then
        NEED_RECREATE=1
    fi
    if [ -x "$VENV_DIR/bin/python3" ] && [ "$ARCH" = "arm64" ]; then
        if file "$VENV_DIR/bin/python3" 2>/dev/null | grep -qi 'x86_64' \
            && ! file "$VENV_DIR/bin/python3" 2>/dev/null | grep -qi 'arm64'; then
            echo "  Detectado venv Intel en Mac Apple Silicon — se recreará."
            NEED_RECREATE=1
        fi
    fi
    if [ "$NEED_RECREATE" = "1" ]; then
        echo "  Recreando entorno virtual..."
        rm -rf "$VENV_DIR"
    fi
fi
if [ ! -d "$VENV_DIR" ]; then
    "$PY" -m venv "$VENV_DIR" || die "No se pudo crear el venv"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate" || die "No se pudo activar el venv"
echo "  ✓ Entorno virtual OK"

# ---- 4. Python packages ----
echo "▸ [4/6] Instalando paquetes Python..."
python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
python3 -m pip install --upgrade \
    sounddevice numpy websockets aiohttp customtkinter Pillow \
    || die "Falló pip install de dependencias"
echo "  ✓ Paquetes Python OK"

# ---- 5. Create .app bundle ----
echo "▸ [5/6] Creando aplicación..."
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
exec python3 "$SCRIPT_DIR/bridge_gui.py"
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
    <string>TieLine Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>TieLine Bridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.intercom.tieline-bridge</string>
    <key>CFBundleVersion</key>
    <string>3.7.1</string>
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

LOGO=""
for cand in "$SCRIPT_DIR/logo.png" "$SCRIPT_DIR/Logo.png"; do
    [ -f "$cand" ] && LOGO="$cand" && break
done
if [ -n "$LOGO" ]; then
    echo "  Generando icono de la aplicación..."
    ICONSET="$APP_RESOURCES/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$LOGO" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1
    sips -z 32 32     "$LOGO" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -z 32 32     "$LOGO" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1
    sips -z 64 64     "$LOGO" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -z 128 128   "$LOGO" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1
    sips -z 256 256   "$LOGO" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$LOGO" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1
    sips -z 512 512   "$LOGO" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$LOGO" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1
    sips -z 1024 1024 "$LOGO" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
    echo "  ✓ Icono de app generado"
fi

echo "  ✓ Aplicación creada en el Escritorio"

# ---- 6. Backup .command launcher ----
echo "▸ [6/6] Creando lanzador de respaldo..."
LAUNCHER="$HOME/Desktop/$APP_NAME.command"
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
exec python3 "$SCRIPT_DIR/bridge_gui.py"
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
echo "║   Login: Empresa + Admin + Password      ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
read -r -p "Presiona Enter para cerrar..." _
