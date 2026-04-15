#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
source .env 2>/dev/null
COMPOSE="docker compose"
docker compose version &>/dev/null || COMPOSE="docker-compose"

# Auto-detect server IP for mediasoup/TURN and persist to .env
detect_ip() {
    local IP=$(hostname -I | awk '{print $1}')
    sed -i '/^MEDIASOUP_ANNOUNCED_IP=/d' "$SCRIPT_DIR/.env" 2>/dev/null
    echo "MEDIASOUP_ANNOUNCED_IP=$IP" >> "$SCRIPT_DIR/.env"
    export MEDIASOUP_ANNOUNCED_IP="$IP"
    echo "[✓] IP detected: $IP"
}

case "$1" in
    start)
        detect_ip
        $COMPOSE up -d
        ;;
    stop)
        $COMPOSE down
        ;;
    restart)
        detect_ip
        $COMPOSE down && $COMPOSE up -d
        ;;
    rebuild)
        detect_ip
        $COMPOSE down && $COMPOSE up -d --build
        ;;
    logs)
        $COMPOSE logs -f
        ;;
    status)
        $COMPOSE ps
        ;;
    ip)
        detect_ip
        ;;
    *)
        echo "Uso: $0 {start|stop|restart|rebuild|logs|status|ip}"
        exit 1
        ;;
esac
