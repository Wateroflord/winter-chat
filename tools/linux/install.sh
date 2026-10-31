#!/bin/bash
# Устанавливает Winter Chat в профиль пользователя и добавляет его в меню приложений.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/share/winter-chat"
rm -rf "$DEST"
mkdir -p "$DEST" "$HOME/.local/share/applications"
cp -r "$SRC/bundle/." "$DEST/"
chmod +x "$DEST/winter_chat"

printf '%s\n' \
  "[Desktop Entry]" \
  "Type=Application" \
  "Name=Winter Chat" \
  "Comment=Чаты и звонки для своих" \
  "Exec=$DEST/winter_chat" \
  "Icon=$DEST/data/flutter_assets/assets/icon/icon.png" \
  "Terminal=false" \
  "Categories=Network;Chat;InstantMessaging;" \
  > "$HOME/.local/share/applications/winter-chat.desktop"

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "Готово! Winter Chat появился в меню приложений."
echo "Для выбора файлов нужен zenity (обычно уже есть): sudo apt install zenity"
