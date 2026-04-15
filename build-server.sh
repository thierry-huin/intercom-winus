#!/bin/bash
# Rebuild backend Docker image and restart
set -e
cd "$(dirname "$0")"

echo "=== Building backend ==="
docker compose build backend
echo "✓ Backend built"

echo "=== Restarting backend ==="
docker compose up -d backend
echo "✓ Backend restarted"

sleep 3
docker compose logs --tail=3 backend
echo "✓ Done!"
