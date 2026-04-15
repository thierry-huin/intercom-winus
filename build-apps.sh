#!/bin/bash
# Build web + APK and deploy
set -e
cd "$(dirname "$0")/flutter_app"

echo "=== Building Web ==="
flutter build web --release

# --- Post-build patches for compatibility ---
echo "Applying post-build patches..."

# 1. Force local CanvasKit (avoid downloading ~6MB from gstatic.com CDN)
sed -i 's/"engineRevision"/"useLocalCanvasKit":true,"engineRevision"/' build/web/flutter_bootstrap.js

# 2. Safari fix: convert canvaskit.js from ES module to classic script
#    Safari blocks import() on self-signed HTTPS certificates
for ck in build/web/canvaskit/canvaskit.js build/web/canvaskit/chromium/canvaskit.js; do
  if [ -f "$ck" ]; then
    sed -i "s|import\.meta\.url|document.currentScript\&\&document.currentScript.src\|\|location.href|g" "$ck"
    sed -i 's|export default CanvasKitInit;|if(typeof window!=="undefined")window.CanvasKitInit=CanvasKitInit;|' "$ck"
  fi
done

# 3. Patch bootstrap to use pre-loaded CanvasKitInit global (fallback to import())
sed -i 's|u=await import(o)|u=window.CanvasKitInit?{default:window.CanvasKitInit}:await import(o)|' build/web/flutter_bootstrap.js

# 4. Ensure canvaskit.js loads as classic script before bootstrap (set in index.html source)
#    Replace async bootstrap with sync canvaskit + bootstrap pair
sed -i 's|<script src="flutter_bootstrap.js" async></script>|<script src="canvaskit/canvaskit.js"></script>\n  <script src="flutter_bootstrap.js"></script>|' build/web/index.html

echo "✓ Web built (local CanvasKit + Safari compatibility)"

echo "=== Building APK ==="
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ../nginx/downloads/intercom.apk
echo "✓ APK built and deployed"

echo "=== Restarting nginx ==="
cd ..
docker compose restart nginx
echo "✓ Done! Web + APK updated."
