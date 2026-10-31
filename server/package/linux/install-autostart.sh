#!/bin/bash
# Включает автозапуск Winter Chat Server при включении компьютера (systemd).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
chmod +x "$DIR/winter-chat-server" "$DIR/livekit-server" 2>/dev/null || true

UNIT="[Unit]
Description=Winter Chat Server
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$DIR
ExecStart=$DIR/winter-chat-server --no-browser
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target"

echo "$UNIT" | sudo tee /etc/systemd/system/winter-chat-server.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now winter-chat-server

if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 8090/tcp
  sudo ufw allow 7881/tcp
  sudo ufw allow 7882/udp
fi

echo
echo "Готово! Сервер запущен и будет стартовать сам при включении компьютера."
echo "Панель: http://localhost:8090    Логи: journalctl -u winter-chat-server -f"
