#!/bin/bash
# Build web + APK and deploy
set -e
cd "$(dirname "$0")/flutter_app"

echo "=== Building Web ==="
flutter build web --release

# --- Post-build patches for compatibility ---
echo "Applying post-build patches..."

# 1. Force local CanvasKit (avoid downloading ~6MB from gstatic.com CDN)
#    The bootstrap already supports useLocalCanvasKit via the build config,
#    we just need to flip the flag. This is safe across Flutter 3.x versions.
sed -i 's/"engineRevision"/"useLocalCanvasKit":true,"engineRevision"/' build/web/flutter_bootstrap.js

# NOTE: earlier versions of this script also rewrote canvaskit.js from an ES
# module into a classic <script> to work around Safari blocking import() on
# self-signed HTTPS certificates. Those sed patches are incompatible with
# Flutter 3.41's CanvasKit build (the rewritten module fails to resolve
# MakeFreeTypeFaceFromData and produces a white screen with
# "Cannot read properties of undefined"). They have been removed. For Safari
# over self-signed certs you now need a device-trusted CA (mkcert install
# on the device) so that native import() works.

echo "✓ Web built (local CanvasKit)"

echo "=== Building APK ==="
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ../nginx/downloads/intercom.apk
echo "✓ APK built and deployed"

# Build the Android App Bundle for Play Store uploads. The Play Console
# rejects any name other than the one we declare here, and previous
# versions of the script left it as `app-release.aab` which forced manual
# renames. Always emit the exact filename the store expects.
echo "=== Building AAB (Android App Bundle) ==="
# Flutter may emit a non-fatal "failed to strip debug symbols" warning
# (exit code 1) for pre-compiled native libs (mediasfu_mediasoup_client)
# even though the AAB is produced successfully. Allow the command to fail
# and verify the output file exists instead.
flutter build appbundle --release || true
if [ ! -f build/app/outputs/bundle/release/app-release.aab ]; then
    echo "✖ AAB build failed — output file not found"
    exit 1
fi
cp build/app/outputs/bundle/release/app-release.aab \
   ../nginx/downloads/winus_intercom.aab
echo "✓ AAB built and deployed as winus_intercom.aab (nginx/downloads)"
# Also drop a copy in the user's Documentos folder so the operator can
# pick it up directly without going through the served URL. Pick the
# real owner of the working tree (when the script is invoked via sudo)
# so we don't end up writing root-owned files into their home.
DOCS_USER="${SUDO_USER:-$USER}"
DOCS_HOME=$(getent passwd "$DOCS_USER" | cut -d: -f6)
DOCS_DIR="${DOCS_HOME}/Documentos"
if [ -d "$DOCS_HOME" ]; then
    mkdir -p "$DOCS_DIR"
    cp build/app/outputs/bundle/release/app-release.aab \
       "$DOCS_DIR/winus_intercom.aab"
    chown "$DOCS_USER:$DOCS_USER" "$DOCS_DIR/winus_intercom.aab" 2>/dev/null || true
    echo "✓ AAB also copied to $DOCS_DIR/winus_intercom.aab"
fi

echo "=== Restarting nginx ==="
cd ..
docker compose restart nginx
echo "✓ Done! Web + APK + AAB updated."
