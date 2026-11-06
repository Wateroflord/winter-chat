#!/bin/bash
# Проверка сервера: запуск, регистрация, вход, чат, сообщение с файлом, токен звонка, прокси LiveKit.
# Запуск: bash smoke_test.sh <папка с winter-chat-server и livekit-server>
set -u
DIR="$1"
cd "$DIR"
rm -rf winter-chat-data
./winter-chat-server --no-browser > server.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
B=http://127.0.0.1:8090
fail() { echo "::error title=smoke::$1"; echo "--- server.log"; tail -50 server.log; echo "--- livekit.log"; tail -30 winter-chat-data/livekit.log 2>/dev/null; exit 1; }
ok() { echo "OK: $1"; }

for i in $(seq 1 60); do curl -sf $B/api/wc/info >/dev/null && break; sleep 1; done
curl -sf $B/api/wc/info | tee /dev/stderr | jq -e '.app=="winter-chat"' >/dev/null || fail "сервер не отвечает"
ok "сервер запущен"

INVITE=$(jq -r .inviteCode winter-chat-data/server.json)
[ -n "$INVITE" ] || fail "нет кода приглашения"

# Регистрация с неверным кодом должна не пройти
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST $B/api/collections/users/records -H 'Content-Type: application/json' \
  -d '{"username":"bad","password":"password123","passwordConfirm":"password123","invite":"WRONG"}')
[ "$code" = "400" ] || fail "регистрация без кода прошла ($code): $(cat /tmp/r.json)"
ok "без кода регистрация запрещена"

reg() {
  curl -s -X POST "$B/api/collections/users/records?invite=$INVITE" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"name\":\"$2\",\"password\":\"password123\",\"passwordConfirm\":\"password123\",\"invite\":\"$INVITE\"}"
}
U1=$(reg stas "Стас" | tee /dev/stderr | jq -r .id); [ "$U1" != "null" ] || fail "регистрация stas"
U2=$(reg vova "Вова" | jq -r .id); [ "$U2" != "null" ] || fail "регистрация vova"
ok "регистрация"

login() { sleep 2; curl -s -X POST $B/api/collections/users/auth-with-password -H 'Content-Type: application/json' -d "{\"identity\":\"$1\",\"password\":\"password123\"}" | jq -r .token; }
T1=$(login stas); [ "$T1" != "null" ] && [ -n "$T1" ] || fail "вход stas"
T2=$(login VOVA); [ "$T2" != "null" ] && [ -n "$T2" ] || fail "вход по логину без учёта регистра"
ok "вход по логину"

n=$(curl -s "$B/api/collections/users/records" -H "Authorization: $T1" | jq '.items|length')
[ "$n" = "2" ] || fail "список пользователей: $n"

CHAT=$(curl -s -X POST $B/api/collections/chats/records -H "Authorization: $T1" -H 'Content-Type: application/json' \
  -d "{\"is_group\":false,\"members\":[\"$U2\"]}" | tee /dev/stderr | jq -r .id)
[ "$CHAT" != "null" ] || fail "создание личного чата"
dup=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/chats/records -H "Authorization: $T2" -H 'Content-Type: application/json' -d "{\"is_group\":false,\"members\":[\"$U1\"]}")
[ "$dup" = "400" ] || fail "второй личный чат не должен создаваться ($dup)"
ok "личный чат"

echo "hello file" > /tmp/note.txt
MSG=$(curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T2" \
  -F "chat=$CHAT" -F "text=Привет!" -F "author=$U1" -F "files=@/tmp/note.txt" | tee /dev/stderr)
echo "$MSG" | jq -e ".author==\"$U2\" and (.files|length)==1" >/dev/null || fail "сообщение с файлом"
FILE=$(echo "$MSG" | jq -r '.files[0]'); MID=$(echo "$MSG" | jq -r .id)
curl -sf "$B/api/files/messages/$MID/$FILE" | grep -q "hello file" || fail "скачивание файла"
last=$(curl -s "$B/api/collections/chats/records/$CHAT" -H "Authorization: $T1" | jq -r .last_text)
[ "$last" = "Привет!" ] || fail "превью чата: $last"
ok "сообщение, файл, превью"

# Чужой не видит чат
T3=$(reg petya "Петя" >/dev/null; login petya)
n=$(curl -s "$B/api/collections/messages/records?filter=chat='$CHAT'" -H "Authorization: $T3" | jq '.items|length')
[ "$n" = "0" ] || fail "посторонний видит сообщения"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/messages/records -H "Authorization: $T3" -F "chat=$CHAT" -F "text=spam")
[ "$code" != "200" ] || fail "посторонний может писать в чат"
ok "приватность"

# --- Winter Arc: очки дисциплины ---
TODAY=$(date +%F)
arc=$(curl -s $B/api/wc/info | jq -c .arc)
[ "$(echo "$arc" | jq -r .start)" = "$TODAY" ] || fail "Winter Arc начинается не сегодня: $arc"
[ "$(echo "$arc" | jq -r .end)" = "$(date -d "$TODAY +364 day" +%F)" ] || fail "Winter Arc не 365 дней: $arc"
S1=$(curl -s -X POST $B/api/collections/arc_scores/records -H "Authorization: $T1" -H 'Content-Type: application/json' \
  -d "{\"user\":\"$U2\",\"day\":\"$TODAY\",\"food\":999,\"water\":5,\"sleep\":20,\"steps\":-3,\"workout\":0}" | tee /dev/stderr)
[ "$(echo "$S1" | jq -r .user)" = "$U1" ] || fail "очки записались другому человеку"
[ "$(echo "$S1" | jq -r .food)" = "30" ] || fail "очки не обрезаются до максимума"
[ "$(echo "$S1" | jq -r .steps)" = "0" ] || fail "отрицательные очки"
[ "$(echo "$S1" | jq -r .total)" = "55" ] || fail "сумма очков посчитана неверно"
SID=$(echo "$S1" | jq -r .id)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/arc_scores/records -H "Authorization: $T1" -H 'Content-Type: application/json' -d "{\"day\":\"$TODAY\",\"food\":10}")
[ "$code" = "400" ] || fail "второй раз за тот же день ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/arc_scores/records/$SID -H "Authorization: $T2" -H 'Content-Type: application/json' -d '{"food":0}')
[ "$code" != "200" ] || fail "чужие очки можно менять"
for d in "$(date -d "$TODAY -1 day" +%F)" "$(date -d "$TODAY +5 day" +%F)" "2026-13-01"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/arc_scores/records -H "Authorization: $T1" -H 'Content-Type: application/json' -d "{\"day\":\"$d\",\"food\":10}")
  [ "$code" = "400" ] || fail "день $d вне Winter Arc принят ($code)"
done
upd=$(curl -s -X PATCH $B/api/collections/arc_scores/records/$SID -H "Authorization: $T1" -H 'Content-Type: application/json' -d '{"workout":20,"total":100}')
[ "$(echo "$upd" | jq -r .total)" = "75" ] || fail "сумма после изменения: $upd"
n=$(curl -s "$B/api/collections/arc_scores/records?filter=day='$TODAY'&expand=user" -H "Authorization: $T2" | jq '.items|length')
[ "$n" = "1" ] || fail "друзья не видят рейтинг ($n)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$B/api/collections/arc_scores/records")
n=$(curl -s "$B/api/collections/arc_scores/records" | jq '.items|length')
[ "$n" = "0" ] || fail "рейтинг виден без входа"
[ "$(curl -s -X POST $B/api/wc/panel/arc-restart | jq -r .start)" = "$TODAY" ] || fail "перезапуск Winter Arc"
ok "Winter Arc: очки, защита, рейтинг"

# Звонки
for i in $(seq 1 20); do curl -sf $B/api/wc/info | jq -e .calls >/dev/null && break; sleep 1; done
curl -sf $B/api/wc/info | jq -e .calls >/dev/null || fail "LiveKit не запустился"
LKT=$(curl -s -X POST $B/api/wc/call-token -H "Authorization: $T1" -H 'Content-Type: application/json' -d "{\"chat\":\"$CHAT\"}" | tee /dev/stderr | jq -r .token)
[ "$LKT" != "null" ] && [ -n "$LKT" ] || fail "токен звонка"
code=$(curl -s -o /tmp/v.txt -w '%{http_code}' "$B/lk/rtc/validate" -H "Authorization: Bearer $LKT")
echo "validate: $code $(cat /tmp/v.txt)"
[ "$code" = "200" ] || fail "прокси LiveKit /lk/rtc/validate: $code $(cat /tmp/v.txt)"
hdr=$(curl -s --http1.1 -i -N --max-time 4 "$B/lk/rtc?auto_subscribe=1&adaptive_stream=0&protocol=16" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Authorization: Bearer $LKT" 2>&1 | head -5)
echo "websocket: $hdr"
echo "$hdr" | grep -q " 101" || fail "WebSocket звонка через прокси не открылся: $hdr"
ok "WebSocket звонка через прокси"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/call-token -H "Authorization: $T3" -H 'Content-Type: application/json' -d "{\"chat\":\"$CHAT\"}")
[ "$code" = "403" ] || fail "посторонний получил токен звонка ($code)"
ok "звонки: токен и прокси"

curl -sf $B/ | grep -q "Winter" || fail "панель"
curl -sf $B/api/wc/panel | jq -e '.users|length==3' >/dev/null || fail "данные панели"
ok "панель"

# Защита панели: чужой сайт, туннель и подмена Host не должны видеть данные
for h in "Origin: https://evil.example" "Sec-Fetch-Site: cross-site" "X-Forwarded-For: 8.8.8.8" "Host: evil.example:8090"; do
  code=$(curl -s -o /tmp/p.json -w '%{http_code}' $B/api/wc/panel -H "$h")
  [ "$code" = "403" ] || fail "панель открыта при заголовке '$h' ($code)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/panel/invite -H "$h")
  [ "$code" = "403" ] || fail "смена кода приглашения при заголовке '$h' ($code)"
done
cors=$(curl -s -i $B/api/wc/info -H "Origin: https://evil.example" | grep -i "access-control-allow-origin" || true)
[ -z "$cors" ] || fail "сервер разрешает чтение чужим сайтам: $cors"
ok "панель защищена от чужих сайтов и туннелей"

# Код приглашения длинный, перебор упирается в лимит
echo "$INVITE" | grep -Eq '^[A-Z]+-[A-Z0-9]{4}-[A-Z0-9]{4}$' || fail "короткий код приглашения: $INVITE"
limited=0
for i in $(seq 1 8); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/users/records -H 'Content-Type: application/json' \
    -d "{\"username\":\"brute$i\",\"password\":\"password123\",\"passwordConfirm\":\"password123\",\"invite\":\"SNOW-AAAA-$i$i$i$i\"}")
  [ "$code" = "429" ] && limited=1 && break
done
[ "$limited" = "1" ] || fail "перебор кода приглашения не ограничен"
ok "перебор кода приглашения ограничен"
echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
