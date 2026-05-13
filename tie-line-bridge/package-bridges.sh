#!/bin/bash
# ============================================================
# Package TieLine Bridge & Server Bridge as distributable
# archives for Linux, macOS and Windows.
#
# Output (in /opt/winus-intercom/tie-line-bridge/dist/):
#   tieline-bridge-YYYYMMDD.tar.gz    (Linux/macOS)
#   tieline-bridge-YYYYMMDD.zip       (Windows)
#   server-bridge-YYYYMMDD.tar.gz     (Linux/macOS)
#   server-bridge-YYYYMMDD.zip        (Windows)
#
# Each archive includes the setup script for each OS plus all
# the Python source files needed. The end user just extracts
# and runs the setup for their platform.
#
# Usage: bash package-bridges.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d)"
DIST_DIR="$SCRIPT_DIR/dist"

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Package Bridges — TieLine + Server Bridge   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

mkdir -p "$DIST_DIR"

# ======================== TieLine Bridge ========================
echo -e "${CYAN}[1/4]${NC} Packaging TieLine Bridge (tar.gz)..."

TL_DIR="/tmp/tieline-bridge-${STAMP}"
rm -rf "$TL_DIR"
mkdir -p "$TL_DIR"

# Python sources + opus.dll for Windows
for f in bridge.py bridge_gui.py audio_engine.py channel.py opus_codec.py \
         rtp_handler.py requirements.txt config_wizard.sh config.default.json \
         Logo.png README.md opus.dll; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$TL_DIR/"
done

# Setup scripts (all platforms)
cp "$SCRIPT_DIR/setup_linux.sh"    "$TL_DIR/"
cp "$SCRIPT_DIR/setup_mac.command" "$TL_DIR/"
cp "$SCRIPT_DIR/setup_windows.bat" "$TL_DIR/"

# Launchers
[ -f "$SCRIPT_DIR/TieLine_Bridge.sh" ]      && cp "$SCRIPT_DIR/TieLine_Bridge.sh" "$TL_DIR/"
[ -f "$SCRIPT_DIR/TieLine_Bridge.command" ]  && cp "$SCRIPT_DIR/TieLine_Bridge.command" "$TL_DIR/"

chmod +x "$TL_DIR/setup_linux.sh" "$TL_DIR/setup_mac.command" 2>/dev/null || true
chmod +x "$TL_DIR/TieLine_Bridge.sh" "$TL_DIR/TieLine_Bridge.command" 2>/dev/null || true
chmod +x "$TL_DIR/config_wizard.sh" 2>/dev/null || true

# tar.gz (Linux + macOS)
TL_TAR="$DIST_DIR/tieline-bridge-${STAMP}.tar.gz"
tar czf "$TL_TAR" -C /tmp "tieline-bridge-${STAMP}"
TL_TAR_SIZE=$(du -h "$TL_TAR" | cut -f1)
echo -e "  ${GREEN}✓${NC} $TL_TAR (${TL_TAR_SIZE})"

# zip (Windows — also usable on Mac)
echo -e "${CYAN}[2/4]${NC} Packaging TieLine Bridge (zip)..."
TL_ZIP="$DIST_DIR/tieline-bridge-${STAMP}.zip"
(cd /tmp && zip -rq "$TL_ZIP" "tieline-bridge-${STAMP}")
TL_ZIP_SIZE=$(du -h "$TL_ZIP" | cut -f1)
echo -e "  ${GREEN}✓${NC} $TL_ZIP (${TL_ZIP_SIZE})"

rm -rf "$TL_DIR"

# ======================== Server Bridge ========================
echo -e "${CYAN}[3/4]${NC} Packaging Server Bridge (tar.gz)..."

SB_DIR="/tmp/server-bridge-${STAMP}"
rm -rf "$SB_DIR"
mkdir -p "$SB_DIR"

# Python sources (shared rtp_handler.py + logo) + opus.dll for Windows
for f in server_bridge.py server_bridge_gui.py rtp_handler.py Logo.png opus.dll; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$SB_DIR/"
done

# Default config template
if [ -f "$SCRIPT_DIR/server_bridge.json" ]; then
    cp "$SCRIPT_DIR/server_bridge.json" "$SB_DIR/server_bridge.json.example"
else
    cat > "$SB_DIR/server_bridge.json.example" << 'CFGEOF'
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

# Setup scripts (all platforms)
cp "$SCRIPT_DIR/setup_server_bridge_linux.sh"     "$SB_DIR/"
cp "$SCRIPT_DIR/setup_server_bridge_mac.command"   "$SB_DIR/"
cp "$SCRIPT_DIR/setup_server_bridge_windows.bat"   "$SB_DIR/"

chmod +x "$SB_DIR/setup_server_bridge_linux.sh" "$SB_DIR/setup_server_bridge_mac.command" 2>/dev/null || true

# tar.gz (Linux + macOS)
SB_TAR="$DIST_DIR/server-bridge-${STAMP}.tar.gz"
tar czf "$SB_TAR" -C /tmp "server-bridge-${STAMP}"
SB_TAR_SIZE=$(du -h "$SB_TAR" | cut -f1)
echo -e "  ${GREEN}✓${NC} $SB_TAR (${SB_TAR_SIZE})"

# zip (Windows)
echo -e "${CYAN}[4/4]${NC} Packaging Server Bridge (zip)..."
SB_ZIP="$DIST_DIR/server-bridge-${STAMP}.zip"
(cd /tmp && zip -rq "$SB_ZIP" "server-bridge-${STAMP}")
SB_ZIP_SIZE=$(du -h "$SB_ZIP" | cut -f1)
echo -e "  ${GREEN}✓${NC} $SB_ZIP (${SB_ZIP_SIZE})"

rm -rf "$SB_DIR"

# ======================== Summary ========================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Packages ready!                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}$DIST_DIR/${NC}"
ls -lh "$DIST_DIR/"*bridge*"${STAMP}"* 2>/dev/null | awk '{print "    " $NF " (" $5 ")"}'
echo ""
echo -e "  ${YELLOW}Installation:${NC}"
echo -e "  Linux:   tar xzf <bridge>.tar.gz && cd <bridge>-* && sudo bash setup_*.sh"
echo -e "  macOS:   tar xzf <bridge>.tar.gz && cd <bridge>-* && double-click setup_*.command"
echo -e "  Windows: Extract .zip, then double-click setup_*.bat"
echo ""
