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

# --- Реакции, ответы, «прочитано», «в сети», закрепы ---
J='Content-Type: application/json'
R1=$(curl -s -X POST $B/api/wc/react -H "Authorization: $T1" -H "$J" -d "{\"message\":\"$MID\",\"emoji\":\"🔥\"}")
echo "$R1" | jq -e ".reactions[\"🔥\"]==[\"$U1\"]" >/dev/null || fail "реакция: $R1"
curl -s -X POST $B/api/wc/react -H "Authorization: $T2" -H "$J" -d "{\"message\":\"$MID\",\"emoji\":\"🔥\"}" | jq -e '.reactions["🔥"]|length==2' >/dev/null || fail "вторая реакция"
curl -s -X POST $B/api/wc/react -H "Authorization: $T1" -H "$J" -d "{\"message\":\"$MID\",\"emoji\":\"🔥\"}" | jq -e ".reactions[\"🔥\"]==[\"$U2\"]" >/dev/null || fail "снять реакцию"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/react -H "Authorization: $T3" -H "$J" -d "{\"message\":\"$MID\",\"emoji\":\"👍\"}")
[ "$code" = "403" ] || fail "посторонний ставит реакцию ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/react -H "Authorization: $T1" -H "$J" -d "{\"message\":\"$MID\",\"emoji\":\"<script>\"}")
[ "$code" = "400" ] || fail "кривая реакция принята ($code)"
E1=$(curl -s -X PATCH $B/api/collections/messages/records/$MID -H "Authorization: $T2" -H "$J" -d '{"text":"Привет!!","reactions":{"💀":["x"]}}')
echo "$E1" | jq -e '.reactions["💀"]==null and .reactions["🔥"]!=null' >/dev/null || fail "реакции подменили правкой: $E1"
REP=$(curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CHAT\",\"text\":\"Ответ\",\"reply_to\":\"$MID\"}")
[ "$(echo "$REP" | jq -r .reply_to)" = "$MID" ] || fail "ответ на сообщение: $REP"
curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/typing -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CHAT\"}" | grep -q 204 || fail "печатает…"
curl -s -o /dev/null -X POST $B/api/wc/read -H "Authorization: $T2" -H "$J" -d "{\"chat\":\"$CHAT\"}"
curl -s "$B/api/collections/chats/records/$CHAT" -H "Authorization: $T1" | jq -e ".reads[\"$U2\"]!=null" >/dev/null || fail "прочитано"
curl -s -X PATCH $B/api/collections/chats/records/$CHAT -H "Authorization: $T1" -H "$J" -d "{\"reads\":{\"$U2\":\"2000-01-01 00:00:00.000Z\"}}" | jq -e ".reads[\"$U2\"]!=\"2000-01-01 00:00:00.000Z\"" >/dev/null || fail "«прочитано» подделали"
curl -s -o /dev/null -X POST $B/api/wc/ping -H "Authorization: $T2"
curl -s "$B/api/collections/users/records/$U2" -H "Authorization: $T1" | jq -e '.last_seen!=""' >/dev/null || fail "в сети"
curl -s -X PATCH $B/api/collections/chats/records/$CHAT -H "Authorization: $T2" -H "$J" -d "{\"pins+\":\"$MID\"}" | jq -e ".pins==[\"$MID\"]" >/dev/null || fail "закрепить сообщение"
ok "реакции, ответы, печатает, прочитано, в сети, закрепы"

# --- Резервная копия из панели ---
BK=$(curl -s -X POST $B/api/wc/panel/backup)
echo "$BK" | jq -e '.name|startswith("winter_manual_")' >/dev/null || fail "резервная копия: $BK"
curl -s $B/api/wc/panel | jq -e '.backups|length>=1' >/dev/null || fail "список копий"
ok "резервная копия"

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

# --- Профиль и группы: статус, «о себе», цвет, описание группы ---
P=$(curl -s -X PATCH $B/api/collections/users/records/$U1 -H "Authorization: $T1" -H 'Content-Type: application/json' \
  -d '{"status":"Играю","status_emoji":"🎮","bio":"Люблю зиму","color":"#FF78AA","status_until":"2099-01-01 00:00:00.000Z"}')
[ "$(echo "$P" | jq -r .status)" = "Играю" ] && [ "$(echo "$P" | jq -r .color)" = "#FF78AA" ] && [ "$(echo "$P" | jq -r .bio)" = "Люблю зиму" ] || fail "профиль: $P"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/users/records/$U1 -H "Authorization: $T1" -H 'Content-Type: application/json' -d '{"color":"красный"}')
[ "$code" = "400" ] || fail "кривой цвет профиля принят ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/users/records/$U1 -H "Authorization: $T2" -H 'Content-Type: application/json' -d '{"status":"взлом"}')
[ "$code" != "200" ] || fail "чужой профиль можно поменять"
curl -s $B/api/collections/users/records/$U1 -H "Authorization: $T2" | jq -e '.status=="Играю" and .status_emoji=="🎮"' >/dev/null || fail "друг не видит статус"
curl -s -X PATCH $B/api/collections/users/records/$U1 -H "Authorization: $T1" -H 'Content-Type: application/json' -d '{"color":"","status":"","status_emoji":"","status_until":""}' | jq -e '.color==""' >/dev/null || fail "очистить профиль"
GRP=$(curl -s -X POST $B/api/collections/chats/records -H "Authorization: $T1" -H 'Content-Type: application/json' -d "{\"name\":\"Профиль-тест\",\"is_group\":true,\"members\":[\"$U2\"]}" | jq -r .id)
curl -s -X PATCH $B/api/collections/chats/records/$GRP -H "Authorization: $T2" -H 'Content-Type: application/json' -d '{"description":"Играем по пятницам"}' | jq -e '.description=="Играем по пятницам"' >/dev/null || fail "описание группы"
ok "профиль (статус, о себе, цвет) и описание группы"

# --- Каналы, опросы, пересылка, стикеры, звуки, GIF, отложенные, превью ссылок ---
sleep 3
J='Content-Type: application/json'
CHR=$(curl -s -X POST $B/api/collections/chats/records -H "Authorization: $T2" -H "$J" -d "{\"name\":\"#игры\",\"is_group\":true,\"parent\":\"$GRP\",\"members\":[\"$U2\"]}")
echo "$CHR" | jq -e ".name==\"игры\" and .parent==\"$GRP\" and (.members|length)==2" >/dev/null || fail "канал в группе: $CHR"
CH1=$(echo "$CHR" | jq -r .id)
VC=$(curl -s -X POST $B/api/collections/chats/records -H "Authorization: $T1" -H "$J" -d "{\"name\":\"Голосовая\",\"is_group\":true,\"parent\":\"$GRP\",\"kind\":\"voice\"}")
echo "$VC" | jq -e '.kind=="voice"' >/dev/null || fail "голосовой канал: $VC"
VC=$(echo "$VC" | jq -r .id)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/chats/records -H "Authorization: $T3" -H "$J" -d "{\"name\":\"взлом\",\"is_group\":true,\"parent\":\"$GRP\"}")
[ "$code" = "403" ] || fail "чужой сделал канал ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/chats/records -H "Authorization: $T1" -H "$J" -d "{\"name\":\"вложенный\",\"is_group\":true,\"parent\":\"$CH1\"}")
[ "$code" = "400" ] || fail "канал в канале ($code)"
U3=$(curl -s -G "$B/api/collections/users/records" --data-urlencode "filter=username='petya'" -H "Authorization: $T1" | jq -r '.items[0].id')
curl -s -o /dev/null -X PATCH $B/api/collections/chats/records/$GRP -H "Authorization: $T1" -H "$J" -d "{\"members+\":\"$U3\"}"
curl -s $B/api/collections/chats/records/$CH1 -H "Authorization: $T3" | jq -e '.members|length==3' >/dev/null || fail "новый участник группы не попал в канал"
R=$(curl -s -X PATCH $B/api/collections/chats/records/$CH1 -H "Authorization: $T1" -H "$J" -d "{\"members\":[\"$U1\"],\"name\":\"флуд\",\"parent\":\"\"}")
echo "$R" | jq -e ".name==\"флуд\" and (.members|length)==3 and .parent==\"$GRP\"" >/dev/null || fail "состав канала поменяли мимо группы: $R"
curl -s -o /dev/null -X PATCH $B/api/collections/chats/records/$GRP -H "Authorization: $T1" -H "$J" -d "{\"members-\":\"$U3\"}"
code=$(curl -s -o /dev/null -w '%{http_code}' $B/api/collections/chats/records/$CH1 -H "Authorization: $T3")
[ "$code" = "404" ] || fail "вышедший из группы видит канал ($code)"
ok "каналы: создание, состав как у группы, защита"

POLL=$(curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"poll\":{\"q\":\"Во сколько играем?\",\"o\":[\"19\",\" 20 \",\"\",\"21\"]},\"votes\":{\"x\":[0]}}")
echo "$POLL" | jq -e '.poll.o==["19","20","21"] and .poll.q=="Во сколько играем?" and (.votes==null or .votes=={})' >/dev/null || fail "опрос: $POLL"
PQ=$(echo "$POLL" | jq -r .id)
curl -s -X POST $B/api/wc/vote -H "Authorization: $T2" -H "$J" -d "{\"message\":\"$PQ\",\"options\":[1]}" | jq -e ".votes[\"$U2\"]==[1]" >/dev/null || fail "голос в опросе"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/vote -H "Authorization: $T2" -H "$J" -d "{\"message\":\"$PQ\",\"options\":[0,1]}")
[ "$code" = "400" ] || fail "два ответа в опросе с одним ответом ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/vote -H "Authorization: $T3" -H "$J" -d "{\"message\":\"$PQ\",\"options\":[0]}")
[ "$code" = "403" ] || fail "чужой голосует ($code)"
curl -s -X PATCH $B/api/collections/messages/records/$PQ -H "Authorization: $T1" -H "$J" -d '{"poll":{"q":"x","o":["a","b"]},"votes":{}}' | jq -e '.poll.q=="Во сколько играем?" and (.votes|length)==1' >/dev/null || fail "опрос подменили правкой"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"poll\":{\"q\":\"?\",\"o\":[\"один\"]}}")
[ "$code" = "400" ] || fail "опрос с одним вариантом ($code)"
curl -s $B/api/collections/chats/records/$CH1 -H "Authorization: $T1" | jq -e '.last_text=="📊 Во сколько играем?"' >/dev/null || fail "превью опроса в списке"
ok "опросы"

curl -s -X POST $B/api/wc/forward -H "Authorization: $T2" -H "$J" -d "{\"message\":\"$MID\",\"chats\":[\"$CH1\"]}" | jq -e '.sent==1' >/dev/null || fail "пересылка"
FW=$(curl -s -G "$B/api/collections/messages/records" --data-urlencode "filter=chat='$CH1' && fwd!=''" -H "Authorization: $T1")
echo "$FW" | jq -e '.items[0].fwd=="Вова" and (.items[0].files|length)==1' >/dev/null || fail "пересланное: $FW"
FID=$(echo "$FW" | jq -r '.items[0].id'); FF=$(echo "$FW" | jq -r '.items[0].files[0]')
curl -sf "$B/api/files/messages/$FID/$FF" | grep -q "hello file" || fail "файл в пересланном"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/forward -H "Authorization: $T3" -H "$J" -d "{\"message\":\"$MID\",\"chats\":[\"$CH1\"]}")
[ "$code" = "403" ] || fail "чужое сообщение переслали ($code)"
ok "пересылка с файлами"

sleep 2
echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > /tmp/s.png
ST=$(curl -s -X POST $B/api/collections/stickers/records -H "Authorization: $T1" -F "pack=Зима" -F "emoji=❄️" -F "owner=$U2" -F "file=@/tmp/s.png")
echo "$ST" | jq -e ".owner==\"$U1\" and .pack==\"Зима\"" >/dev/null || fail "стикер: $ST"
SID=$(echo "$ST" | jq -r .id)
curl -s "$B/api/collections/stickers/records" -H "Authorization: $T2" | jq -e '.items|length>=1' >/dev/null || fail "друг не видит стикеры"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/stickers/records/$SID -H "Authorization: $T2")
[ "$code" != "204" ] || fail "чужой стикер удалили"
curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T2" -H "$J" -d "{\"chat\":\"$CH1\",\"sticker\":\"$SID\"}" | jq -e ".sticker==\"$SID\"" >/dev/null || fail "сообщение-стикер"
curl -s $B/api/collections/chats/records/$CH1 -H "Authorization: $T1" | jq -e '.last_text=="🖼 Стикер"' >/dev/null || fail "превью стикера"
ok "стикеры"

python3 -c "import wave;w=wave.open('/tmp/s.wav','wb');w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(b'\x00\x00'*4000);w.close()"
SND=$(curl -s -X POST $B/api/collections/sounds/records -H "Authorization: $T2" -F "name=Бруh" -F "emoji=💥" -F "file=@/tmp/s.wav")
echo "$SND" | jq -e ".name==\"Бруh\" and .owner==\"$U2\"" >/dev/null || fail "звук для саундборда: $SND"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/sounds/records -H "Authorization: $T2" -F "name=txt" -F "file=@/tmp/note.txt")
[ "$code" = "400" ] || fail "текстовый файл принят как звук ($code)"
ok "саундборд"

curl -s "$B/api/wc/gifs?q=cat" -H "Authorization: $T1" | jq -e '.enabled==false' >/dev/null || fail "GIF без ключа"
curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"gif\":{\"url\":\"https://media.giphy.com/media/x/giphy.gif\",\"w\":200,\"h\":150}}" | jq -e '.gif.w==200' >/dev/null || fail "сообщение-GIF"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"gif\":{\"url\":\"javascript:alert(1)\",\"w\":1,\"h\":1}}")
[ "$code" = "400" ] || fail "кривая GIF принята ($code)"
curl -s -X POST $B/api/wc/panel/giphy -H "$J" -d '{"key":"abc123"}' | jq -e '.gifs==true' >/dev/null || fail "ключ Giphy в панели"
curl -s $B/api/wc/info | jq -e '.gifs==true and .extras==1' >/dev/null || fail "info: gifs"
curl -s -o /dev/null -X POST $B/api/wc/panel/giphy -H "$J" -d '{"key":""}'
ok "GIF"

sleep 2
AT=$(date -u -d '+3 seconds' '+%Y-%m-%d %H:%M:%S.000Z')
SC=$(curl -s -X POST $B/api/collections/scheduled/records -H "Authorization: $T2" -H "$J" -d "{\"chat\":\"$CH1\",\"text\":\"Катка в 20:00!\",\"at\":\"$AT\",\"remind\":true,\"author\":\"$U1\"}")
echo "$SC" | jq -e ".author==\"$U2\" and .remind==true" >/dev/null || fail "отложенное: $SC"
curl -s "$B/api/collections/scheduled/records" -H "Authorization: $T1" | jq -e '.items|length==0' >/dev/null || fail "чужие отложенные видны"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/scheduled/records -H "Authorization: $T2" -H "$J" -d "{\"chat\":\"$CH1\",\"text\":\"вчера\",\"at\":\"2020-01-01 10:00:00.000Z\"}")
[ "$code" = "400" ] || fail "отложенное в прошлое ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/scheduled/records -H "Authorization: $T3" -H "$J" -d "{\"chat\":\"$CH1\",\"text\":\"спам\",\"at\":\"$AT\"}")
[ "$code" != "200" ] || fail "чужой планирует сообщения в чат"
got=""
for i in $(seq 1 30); do
  got=$(curl -s -G "$B/api/collections/messages/records" --data-urlencode "filter=chat='$CH1' && remind=true" -H "Authorization: $T1" | jq -r '.items[0].text // empty')
  [ -n "$got" ] && break; sleep 1
done
[ "$got" = "Катка в 20:00!" ] || fail "отложенное не пришло вовремя"
curl -s "$B/api/collections/scheduled/records" -H "Authorization: $T2" | jq -e '.items|length==0' >/dev/null || fail "отправленное отложенное не удалилось"
ok "отложенные сообщения и напоминания"

LP=$(curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"text\":\"смотри http://127.0.0.1:8090/api/wc/info\"}" | jq -r .id)
pv=""
for i in $(seq 1 15); do
  pv=$(curl -s $B/api/collections/messages/records/$LP -H "Authorization: $T1" | jq -c '.preview // empty')
  [ -n "$pv" ] && [ "$pv" != "null" ] && break; sleep 1
done
echo "$pv" | jq -e '.fail==true' >/dev/null || fail "превью полезло в локальную сеть: $pv"
EX=$(curl -s -X POST $B/api/collections/messages/records -H "Authorization: $T1" -H "$J" -d "{\"chat\":\"$CH1\",\"text\":\"https://example.com\"}" | jq -r .id)
for i in $(seq 1 15); do
  pv=$(curl -s $B/api/collections/messages/records/$EX -H "Authorization: $T1" | jq -c '.preview // empty')
  [ -n "$pv" ] && [ "$pv" != "null" ] && break; sleep 1
done
if echo "$pv" | jq -e '.title=="Example Domain"' >/dev/null 2>&1; then ok "превью ссылки example.com"; else echo "::warning title=smoke::превью example.com не получилось (нет интернета?): $pv"; fi
curl -s -X PATCH $B/api/collections/messages/records/$EX -H "Authorization: $T1" -H "$J" -d '{"preview":{"title":"подмена"}}' | jq -e '.preview.title!="подмена"' >/dev/null || fail "превью подменили правкой"
ok "превью ссылок (локальная сеть закрыта)"

code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/chats/records/$CH1 -H "Authorization: $T1")
[ "$code" = "204" ] || fail "хозяин группы не может удалить канал ($code)"
ok "хозяин группы удаляет каналы"

# --- Игры с друзьями: шахматы и гонка в сапёр ---
curl -s $B/api/wc/info | jq -e '.games.kinds|index("chess")' >/dev/null || fail "сервер не сообщает об играх"
J='Content-Type: application/json'
G=$(curl -s -X POST $B/api/collections/games/records -H "Authorization: $T1" -H "$J" \
  -d "{\"kind\":\"chess\",\"host\":\"$U2\",\"status\":\"done\",\"state\":{\"hostWhite\":true,\"moves\":[]}}" | tee /dev/stderr)
GID=$(echo "$G" | jq -r .id)
[ "$(echo "$G" | jq -r .host)" = "$U1" ] && [ "$(echo "$G" | jq -r .status)" = "open" ] || fail "приглашение в шахматы: $G"
n=$(curl -s "$B/api/collections/games/records?filter=status='open'" -H "Authorization: $T2" | jq '.items|length')
[ "$n" = "1" ] || fail "друг не видит открытое приглашение ($n)"
J1=$(curl -s -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T2" -H "$J" -d '{"state":{"moves":["e2e4"]}}' | tee /dev/stderr)
[ "$(echo "$J1" | jq -r .status)" = "playing" ] && [ "$(echo "$J1" | jq -r .guest)" = "$U2" ] || fail "принять приглашение: $J1"
[ "$(echo "$J1" | jq -c .state.moves)" = "[]" ] || fail "при входе гость поменял партию"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T3" -H "$J" -d '{"seq":2}')
[ "$code" != "200" ] || fail "посторонний вмешался в партию"
M1=$(curl -s -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T1" -H "$J" -d '{"seq":2,"state":{"hostWhite":true,"moves":["e2e4"]}}')
[ "$(echo "$M1" | jq -r .seq)" = "2" ] || fail "ход: $M1"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T2" -H "$J" -d '{"seq":2,"state":{"hostWhite":true,"moves":["e2e4","e7e5"]}}')
[ "$code" = "400" ] || fail "ход по устаревшей партии принят ($code)"
M2=$(curl -s -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T2" -H "$J" -d "{\"seq\":3,\"status\":\"done\",\"winner\":\"$U1\",\"result\":\"resign\"}")
[ "$(echo "$M2" | jq -r .winner)" = "$U1" ] && [ "$(echo "$M2" | jq -r .status)" = "done" ] || fail "сдаться: $M2"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/games/records/$GID -H "Authorization: $T1" -H "$J" -d '{"seq":4,"status":"playing"}')
[ "$code" = "400" ] || fail "законченную партию можно продолжить ($code)"
ok "шахматы с другом: приглашение, ходы, защита от устаревших ходов"

R=$(curl -s -X POST $B/api/collections/games/records -H "Authorization: $T1" -H "$J" \
  -d "{\"kind\":\"mines\",\"guest\":\"$U2\",\"state\":{\"level\":\"easy\",\"seed\":42}}")
RID=$(echo "$R" | jq -r .id)
n=$(curl -s "$B/api/collections/games/records?filter=kind='mines'" -H "Authorization: $T3" | jq '.items|length')
[ "$n" = "0" ] || fail "личное приглашение видно постороннему"
curl -s -X PATCH $B/api/collections/games/records/$RID -H "Authorization: $T2" -H "$J" -d '{}' | jq -e '.status=="playing"' >/dev/null || fail "принять гонку"
H1=$(curl -s -X PATCH $B/api/collections/games/records/$RID -H "Authorization: $T1" -H "$J" -d '{"host_state":{"won":50000,"open":71},"guest_state":{"lost":true}}')
[ "$(echo "$H1" | jq -r .status)" = "playing" ] || fail "гонка закончилась раньше времени: $H1"
[ "$(echo "$H1" | jq -r .guest_state)" = "null" ] || fail "хозяин записал за гостя: $H1"
G1=$(curl -s -X PATCH $B/api/collections/games/records/$RID -H "Authorization: $T2" -H "$J" -d '{"guest_state":{"won":40000,"open":71},"host_state":{"lost":true}}' | tee /dev/stderr)
[ "$(echo "$G1" | jq -r .status)" = "done" ] && [ "$(echo "$G1" | jq -r .winner)" = "$U2" ] || fail "победитель гонки: $G1"
[ "$(echo "$G1" | jq -r .host_state.won)" = "50000" ] || fail "гость записал за хозяина"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/games/records/$RID -H "Authorization: $T1")
[ "$code" = "204" ] || fail "удалить законченную гонку ($code)"
ok "гонка в сапёр: личное приглашение, свой прогресс, победитель на сервере"

# Общие доски задач («Фокус» в КБЖУ Трекере)
curl -s $B/api/wc/info | jq -e '.boards==1' >/dev/null || fail "сервер не сообщает о досках"
U3=$(curl -s "$B/api/collections/users/records?filter=username='petya'" -H "Authorization: $T1" | jq -r '.items[0].id')
BD=$(curl -s -X POST $B/api/collections/boards/records -H "Authorization: $T1" -H "$J" -d "{\"name\":\"FalseMemory\",\"members\":[\"$U2\"],\"owner\":\"$U2\"}" | tee /dev/stderr)
BID=$(echo "$BD" | jq -r .id)
[ "$(echo "$BD" | jq -r .owner)" = "$U1" ] || fail "хозяин доски: $BD"
echo "$BD" | jq -e --arg u "$U1" '.members|index($u)' >/dev/null || fail "хозяин не в участниках: $BD"
R=$(curl -s "$B/api/collections/boards/records" -H "Authorization: $T2")
n=$(echo "$R" | jq '.items|length')
[ "$n" = "1" ] || fail "участник не видит доску ($n): $R"
n=$(curl -s "$B/api/collections/boards/records" -H "Authorization: $T3" | jq '.items|length')
[ "$n" = "0" ] || fail "посторонний видит доску ($n)"
R=$(curl -s "$B/api/collections/boards/records/$BID" -H "Authorization: $T2")
echo "$R" | jq -e '.name=="FalseMemory"' >/dev/null || fail "участник не открыл доску: $R"
TK=$(curl -s -X POST $B/api/collections/board_tasks/records -H "Authorization: $T2" -H "$J" -d "{\"board\":\"$BID\",\"title\":\"Сделать меню\",\"status\":\"todo\"}" | tee /dev/stderr)
TID=$(echo "$TK" | jq -r .id)
[ "$(echo "$TK" | jq -r .author)" = "$U2" ] || fail "автор задачи: $TK"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/collections/board_tasks/records -H "Authorization: $T3" -H "$J" -d "{\"board\":\"$BID\",\"title\":\"чужая\",\"status\":\"todo\"}")
[ "$code" != "200" ] || fail "посторонний добавил задачу на чужую доску"
curl -s -X PATCH $B/api/collections/board_tasks/records/$TID -H "Authorization: $T1" -H "$J" -d '{"status":"done"}' | jq -e '.status=="done"' >/dev/null || fail "перенести задачу в «Готово»"
n=$(curl -s "$B/api/collections/board_tasks/records?filter=board='$BID'" -H "Authorization: $T3" | jq '.items|length')
[ "$n" = "0" ] || fail "посторонний видит задачи ($n)"
curl -s -X PATCH $B/api/collections/board_tasks/records/$TID -H "Authorization: $T2" -H "$J" -d '{"pomodoros+":2}' | jq -e '.pomodoros==2' >/dev/null || fail "помидоры задаче"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/boards/records/$BID -H "Authorization: $T2" -H "$J" -d "{\"members\":[\"$U1\",\"$U2\",\"$U3\"]}")
[ "$code" = "403" ] || fail "участник сам добавил человека на доску ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/boards/records/$BID -H "Authorization: $T2")
[ "$code" != "204" ] || fail "участник удалил чужую доску"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/boards/records/$BID -H "Authorization: $T1")
[ "$code" = "204" ] || fail "хозяин не смог удалить доску ($code)"
ok "общие доски: видят только участники, задачи двигают все участники, состав меняет хозяин"

# Раздел «Друзья»: игровые вечера, Winter Cloud, Dota-номер
curl -s $B/api/wc/info | jq -e '.friends==1' >/dev/null || fail "сервер не сообщает о разделе «Друзья»"
GN=$(curl -s -X POST $B/api/collections/game_nights/records -H "Authorization: $T1" -H "$J" -d '{"game":"Dota 2","at":"2030-01-01 19:00:00.000Z","note":"турбо"}' | tee /dev/stderr)
GID=$(echo "$GN" | jq -r .id)
echo "$GN" | jq -e --arg u "$U1" '.author==$u and (.going|index($u))!=null' >/dev/null || fail "автор вечера идёт: $GN"
curl -s -X PATCH $B/api/collections/game_nights/records/$GID -H "Authorization: $T2" -H "$J" -d "{\"maybe+\":\"$U2\"}" | jq -e --arg u "$U2" '.maybe|index($u)!=null' >/dev/null || fail "друг не отметился «может быть»"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $B/api/collections/game_nights/records/$GID -H "Authorization: $T2" -H "$J" -d "{\"going-\":\"$U1\"}")
[ "$code" = "403" ] || fail "друг убрал автора из идущих ($code)"
R=$(curl -s -X PATCH $B/api/collections/game_nights/records/$GID -H "Authorization: $T2" -H "$J" -d '{"game":"CS2"}')
echo "$R" | jq -e '.game=="Dota 2"' >/dev/null || fail "друг поменял игру: $R"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/game_nights/records/$GID -H "Authorization: $T2")
[ "$code" != "204" ] || fail "друг удалил чужой вечер"
echo "привет из облака" > /tmp/wc_cloud.txt
CF=$(curl -s -X POST $B/api/collections/cloud_files/records -H "Authorization: $T1" -F "file=@/tmp/wc_cloud.txt" -F "owner=$U2" | tee /dev/stderr)
CID=$(echo "$CF" | jq -r .id)
echo "$CF" | jq -e --arg u "$U1" '.owner==$u and .name=="wc_cloud.txt" and .size>0' >/dev/null || fail "файл в облаке: $CF"
n=$(curl -s "$B/api/collections/cloud_files/records" -H "Authorization: $T2" | jq '.items|length')
[ "$n" = "1" ] || fail "друг не видит файл в облаке ($n)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/cloud_files/records/$CID -H "Authorization: $T2")
[ "$code" != "204" ] || fail "друг удалил чужой файл"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/collections/cloud_files/records/$CID -H "Authorization: $T1")
[ "$code" = "204" ] || fail "хозяин не удалил файл ($code)"
curl -s -X PATCH $B/api/collections/users/records/$U1 -H "Authorization: $T1" -H "$J" -d '{"dota_id":"123456789"}' | jq -e '.dota_id=="123456789"' >/dev/null || fail "dota_id в профиле"
curl -s $B/api/wc/cloud -H "Authorization: $T2" | jq -e '.limit>0 and .fileMax==524288000 and .used==0' >/dev/null || fail "место в облаке"
code=$(curl -s -o /dev/null -w '%{http_code}' $B/api/wc/cloud)
[ "$code" = "401" ] || fail "место в облаке без входа ($code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/panel/cloud-limit -H "$J" -d '{"gb":0}')
[ "$code" = "400" ] || fail "лимит облака 0 ГБ принят ($code)"
curl -s -X POST $B/api/wc/panel/cloud-limit -H "$J" -d '{"gb":25}' | jq -e '.limit==26843545600' >/dev/null || fail "лимит облака из панели"
ok "друзья: игровые вечера, Winter Cloud, Dota-номер"

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
# Запуск в один клик: второй запуск не мешает работающему серверу, «--stop» его выключает
timeout 20 ./winter-chat-server --no-browser > /tmp/second.log 2>&1 || fail "второй запуск завершился с ошибкой: $(cat /tmp/second.log)"
grep -q "уже работает" /tmp/second.log || fail "второй запуск не заметил работающий сервер: $(cat /tmp/second.log)"
curl -sf $B/api/wc/info >/dev/null || fail "второй запуск сломал сервер"
ok "второй запуск только открывает панель"
for h in "Origin: https://evil.example" "Sec-Fetch-Site: cross-site" "X-Forwarded-For: 8.8.8.8"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/wc/panel/stop -H "$h")
  [ "$code" = "403" ] || fail "сервер можно выключить при заголовке '$h' ($code)"
done
curl -sf $B/api/wc/info >/dev/null || fail "сервер выключился от чужого запроса"
timeout 30 ./winter-chat-server --stop > /tmp/stop.log 2>&1 || fail "--stop: $(cat /tmp/stop.log)"
alive() { st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }
for i in $(seq 1 20); do alive $PID || break; sleep 0.5; done
alive $PID && fail "сервер не выключился по --stop"
pgrep -f "livekit-server --config" >/dev/null && fail "после выключения остался livekit-server"
ok "«--stop» выключает сервер вместе со звонками"
echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
