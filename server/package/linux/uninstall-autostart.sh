#!/bin/bash
sudo systemctl disable --now winter-chat-server 2>/dev/null || true
sudo rm -f /etc/systemd/system/winter-chat-server.service
sudo systemctl daemon-reload
echo "Автозапуск выключен."
