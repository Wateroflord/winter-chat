package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"
	"github.com/pocketbase/pocketbase/tools/security"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Каналы в группах, опросы, пересылка, стикеры, саундборд, GIF, превью ссылок
// и отложенные сообщения / напоминания.

const (
	maxChannels       = 30  // каналов в одной группе
	maxStickersPerOne = 300 // своих стикеров у человека
	maxSoundsPerOne   = 30  // своих звуков у человека
	maxScheduledOne   = 50  // ждущих отложенных сообщений у человека
)

func ensureExtrasSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}

	// --- каналы: чат-«ребёнок» группы ---
	chats, err := app.FindCollectionByNameOrId("chats")
	if err != nil {
		return err
	}
	addField(chats, &core.RelationField{Name: "parent", CollectionId: chats.Id, MaxSelect: 1, CascadeDelete: true})
	addField(chats, &core.TextField{Name: "kind", Max: 10, Pattern: `^voice$`})
	addField(chats, &core.NumberField{Name: "position", OnlyInt: true})
	addField(chats, &core.JSONField{Name: "last_mention", MaxSize: 4 << 10}) // кого упомянули в последнем сообщении
	chats.AddIndex("idx_chats_parent", false, "parent", "")
	// Канал может удалить и тот, кто его сделал, и хозяин группы.
	chats.DeleteRule = types.Pointer("owner = @request.auth.id || parent.owner = @request.auth.id")
	if err := app.Save(chats); err != nil {
		return fmt.Errorf("chats: %w", err)
	}

	images := []string{"image/png", "image/webp", "image/gif", "image/jpeg"}
	stickers, err := app.FindCollectionByNameOrId("stickers")
	if err != nil {
		stickers = core.NewBaseCollection("stickers")
		stickers.Fields.Add(&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		stickers.Fields.Add(&core.TextField{Name: "pack", Max: 40, Required: true})
		stickers.Fields.Add(&core.TextField{Name: "emoji", Max: 16})
		stickers.Fields.Add(&core.FileField{Name: "file", MaxSelect: 1, MaxSize: 1 << 20, MimeTypes: images, Required: true})
		stickers.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		stickers.AddIndex("idx_stickers_owner", false, "owner", "")
	}
	stickers.ListRule = types.Pointer(rulesAuthed)
	stickers.ViewRule = types.Pointer(rulesAuthed)
	stickers.CreateRule = types.Pointer(rulesAuthed)
	stickers.UpdateRule = types.Pointer("owner = @request.auth.id")
	stickers.DeleteRule = types.Pointer("owner = @request.auth.id")
	if err := app.Save(stickers); err != nil {
		return fmt.Errorf("stickers: %w", err)
	}

	sounds, err := app.FindCollectionByNameOrId("sounds")
	if err != nil {
		sounds = core.NewBaseCollection("sounds")
		sounds.Fields.Add(&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		sounds.Fields.Add(&core.TextField{Name: "name", Max: 30, Required: true})
		sounds.Fields.Add(&core.TextField{Name: "emoji", Max: 16})
		sounds.Fields.Add(&core.FileField{Name: "file", MaxSelect: 1, MaxSize: 1 << 20, Required: true, MimeTypes: []string{
			"audio/mpeg", "audio/mp3", "audio/ogg", "audio/opus", "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave",
			"audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/x-aac", "audio/webm", "audio/flac", "audio/x-flac",
			"video/mp4", "video/webm", "application/ogg",
		}})
		sounds.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
	}
	sounds.ListRule = types.Pointer(rulesAuthed)
	sounds.ViewRule = types.Pointer(rulesAuthed)
	sounds.CreateRule = types.Pointer(rulesAuthed)
	sounds.UpdateRule = types.Pointer("owner = @request.auth.id")
	sounds.DeleteRule = types.Pointer("owner = @request.auth.id")
	if err := app.Save(sounds); err != nil {
		return fmt.Errorf("sounds: %w", err)
	}

	messages, err := app.FindCollectionByNameOrId("messages")
	if err != nil {
		return err
	}
	addField(messages, &core.TextField{Name: "fwd", Max: 80}) // от кого переслано
	addField(messages, &core.JSONField{Name: "poll", MaxSize: 8 << 10})
	addField(messages, &core.JSONField{Name: "votes", MaxSize: 64 << 10})
	addField(messages, &core.JSONField{Name: "preview", MaxSize: 4 << 10})
	addField(messages, &core.RelationField{Name: "sticker", CollectionId: stickers.Id, MaxSelect: 1})
	addField(messages, &core.JSONField{Name: "gif", MaxSize: 2 << 10})
	addField(messages, &core.BoolField{Name: "remind"})
	if err := app.Save(messages); err != nil {
		return fmt.Errorf("messages: %w", err)
	}

	scheduled, err := app.FindCollectionByNameOrId("scheduled")
	if err != nil {
		scheduled = core.NewBaseCollection("scheduled")
		scheduled.Fields.Add(&core.RelationField{Name: "chat", CollectionId: chats.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		scheduled.Fields.Add(&core.RelationField{Name: "author", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: true})
		scheduled.Fields.Add(&core.TextField{Name: "text", Max: 2000, Required: true})
		scheduled.Fields.Add(&core.DateField{Name: "at", Required: true})
		scheduled.Fields.Add(&core.BoolField{Name: "remind"})
		scheduled.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		scheduled.AddIndex("idx_scheduled_at", false, "at", "")
	}
	scheduled.ListRule = types.Pointer("author = @request.auth.id")
	scheduled.ViewRule = types.Pointer("author = @request.auth.id")
	scheduled.CreateRule = types.Pointer(rulesAuthed + " && chat.members.id ?= @request.auth.id")
	scheduled.UpdateRule = types.Pointer("author = @request.auth.id")
	scheduled.DeleteRule = types.Pointer("author = @request.auth.id")
	if err := app.Save(scheduled); err != nil {
		return fmt.Errorf("scheduled: %w", err)
	}
	return nil
}

// ---------- проверки ----------

type pollData struct {
	Q string   `json:"q"`
	O []string `json:"o"`
	M bool     `json:"m"` // можно выбрать несколько
}

func readPoll(r *core.Record) *pollData {
	raw := strings.TrimSpace(r.GetString("poll"))
	if raw == "" || raw == "null" {
		return nil
	}
	var p pollData
	if json.Unmarshal([]byte(raw), &p) != nil {
		return nil
	}
	return &p
}

func cleanPoll(p *pollData) (*pollData, error) {
	q := strings.TrimSpace(p.Q)
	if q == "" || utf8.RuneCountInString(q) > 200 {
		return nil, errors.New("Вопрос опроса — от 1 до 200 символов")
	}
	var opts []string
	for _, o := range p.O {
		o = strings.TrimSpace(o)
		if o == "" {
			continue
		}
		if utf8.RuneCountInString(o) > 100 {
			return nil, errors.New("Вариант ответа — до 100 символов")
		}
		opts = append(opts, o)
	}
	if len(opts) < 2 || len(opts) > 10 {
		return nil, errors.New("В опросе нужно от 2 до 10 вариантов")
	}
	return &pollData{Q: q, O: opts, M: p.M}, nil
}

type gifData struct {
	URL string `json:"url"`
	W   int    `json:"w"`
	H   int    `json:"h"`
}

func cleanGif(raw string) (*gifData, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "null" {
		return nil, nil
	}
	var g gifData
	if json.Unmarshal([]byte(raw), &g) != nil {
		return nil, errors.New("Неверная GIF")
	}
	u, err := url.Parse(g.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" || len(g.URL) > 600 {
		return nil, errors.New("Неверная ссылка на GIF")
	}
	if g.W < 1 || g.W > 4000 || g.H < 1 || g.H > 4000 {
		g.W, g.H = 200, 200
	}
	return &g, nil
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for _, x := range a {
		if !contains(b, x) {
			return false
		}
	}
	return true
}

func registerExtrasHooks(app core.App) {
	// --- каналы ---
	app.OnRecordCreateRequest("chats").BindFunc(func(e *core.RecordRequestEvent) error {
		parentID := e.Record.GetString("parent")
		if parentID == "" {
			e.Record.Set("kind", "")
			return e.Next()
		}
		parent, err := e.App.FindRecordById("chats", parentID)
		if err != nil || !parent.GetBool("is_group") || parent.GetString("parent") != "" {
			return e.BadRequestError("Каналы бывают только у группы", nil)
		}
		if e.Auth == nil || !contains(parent.GetStringSlice("members"), e.Auth.Id) {
			return e.ForbiddenError("Ты не в этой группе", nil)
		}
		n, _ := e.App.CountRecords("chats", dbx.HashExp{"parent": parentID})
		if n >= maxChannels {
			return e.BadRequestError(fmt.Sprintf("В группе уже %d каналов — больше нельзя", maxChannels), nil)
		}
		name := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(e.Record.GetString("name")), "#"))
		if name == "" {
			return e.BadRequestError("Назови канал", nil)
		}
		e.Record.Set("name", name)
		e.Record.Set("is_group", true)
		e.Record.Set("members", parent.GetStringSlice("members"))
		e.Record.Set("position", n+1)
		return e.Next()
	})
	app.OnRecordUpdateRequest("chats").BindFunc(func(e *core.RecordRequestEvent) error {
		old := e.Record.Original()
		e.Record.Set("parent", old.GetString("parent"))
		e.Record.Set("kind", old.GetString("kind"))
		e.Record.Set("last_mention", old.Get("last_mention"))
		if old.GetString("parent") != "" {
			// Состав канала = состав группы.
			e.Record.Set("members", old.GetStringSlice("members"))
			e.Record.Set("owner", old.GetString("owner"))
			e.Record.Set("is_group", true)
			if strings.TrimSpace(e.Record.GetString("name")) == "" {
				e.Record.Set("name", old.GetString("name"))
			}
		}
		return e.Next()
	})
	// Сменился состав группы — меняется и состав её каналов.
	app.OnRecordAfterUpdateSuccess("chats").BindFunc(func(e *core.RecordEvent) error {
		if e.Record.GetString("parent") == "" && e.Record.GetBool("is_group") {
			syncChannels(e.App, e.Record)
		}
		return e.Next()
	})

	// --- сообщения: опросы, GIF, пересылка, превью ---
	app.OnRecordCreateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("fwd", "")
		e.Record.Set("votes", nil)
		e.Record.Set("preview", nil)
		e.Record.Set("remind", false)
		if p := readPoll(e.Record); p != nil {
			clean, err := cleanPoll(p)
			if err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
			e.Record.Set("poll", clean)
		} else {
			e.Record.Set("poll", nil)
		}
		g, err := cleanGif(e.Record.GetString("gif"))
		if err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		if g != nil {
			e.Record.Set("gif", g)
		} else {
			e.Record.Set("gif", nil)
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		old := e.Record.Original()
		for _, k := range []string{"fwd", "poll", "votes", "sticker", "gif", "remind", "preview"} {
			e.Record.Set(k, old.Get(k))
		}
		// Поменялась ссылка в тексте — превью построим заново.
		if firstURL(e.Record.GetString("text")) != firstURL(old.GetString("text")) {
			e.Record.Set("preview", nil)
		}
		return e.Next()
	})
	app.OnRecordAfterCreateSuccess("messages").BindFunc(func(e *core.RecordEvent) error {
		maybeFetchPreview(e.App, e.Record)
		return e.Next()
	})
	app.OnRecordAfterUpdateSuccess("messages").BindFunc(func(e *core.RecordEvent) error {
		maybeFetchPreview(e.App, e.Record)
		return e.Next()
	})

	// --- стикеры и звуки: хозяин — тот, кто загрузил ---
	ownerHook := func(col string, limit int, what string) {
		app.OnRecordCreateRequest(col).BindFunc(func(e *core.RecordRequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("Нужно войти", nil)
			}
			e.Record.Set("owner", e.Auth.Id)
			n, _ := e.App.CountRecords(col, dbx.HashExp{"owner": e.Auth.Id})
			if int(n) >= limit {
				return e.BadRequestError(fmt.Sprintf("У тебя уже %d %s — удали лишние", n, what), nil)
			}
			return e.Next()
		})
		app.OnRecordUpdateRequest(col).BindFunc(func(e *core.RecordRequestEvent) error {
			e.Record.Set("owner", e.Record.Original().GetString("owner"))
			return e.Next()
		})
	}
	ownerHook("stickers", maxStickersPerOne, "стикеров")
	ownerHook("sounds", maxSoundsPerOne, "звуков")
	app.OnRecordCreateRequest("stickers").BindFunc(func(e *core.RecordRequestEvent) error {
		pack := strings.TrimSpace(e.Record.GetString("pack"))
		if pack == "" {
			pack = "Мои стикеры"
		}
		e.Record.Set("pack", pack)
		return e.Next()
	})

	// --- отложенные сообщения ---
	app.OnRecordCreateRequest("scheduled").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("author", e.Auth.Id)
		if err := checkScheduled(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		n, _ := e.App.CountRecords("scheduled", dbx.HashExp{"author": e.Auth.Id})
		if n >= maxScheduledOne {
			return e.BadRequestError(fmt.Sprintf("Уже %d отложенных сообщений — это максимум", n), nil)
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("scheduled").BindFunc(func(e *core.RecordRequestEvent) error {
		old := e.Record.Original()
		e.Record.Set("author", old.GetString("author"))
		e.Record.Set("chat", old.GetString("chat"))
		if err := checkScheduled(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
}

func checkScheduled(r *core.Record) error {
	text := strings.TrimSpace(r.GetString("text"))
	if text == "" {
		return errors.New("Напиши текст")
	}
	r.Set("text", text)
	at := r.GetDateTime("at").Time()
	if at.IsZero() {
		return errors.New("Выбери время")
	}
	if at.Before(time.Now().Add(-time.Minute)) {
		return errors.New("Это время уже прошло")
	}
	if at.After(time.Now().AddDate(1, 0, 1)) {
		return errors.New("Можно запланировать максимум на год вперёд")
	}
	return nil
}

func syncChannels(app core.App, group *core.Record) {
	kids, err := app.FindRecordsByFilter("chats", "parent = {:p}", "", 0, 0, dbx.Params{"p": group.Id})
	if err != nil {
		return
	}
	members := group.GetStringSlice("members")
	for _, k := range kids {
		if sameSet(k.GetStringSlice("members"), members) {
			continue
		}
		k.Set("members", members)
		if err := app.Save(k); err != nil {
			app.Logger().Warn("channel members", "error", err)
		}
	}
}

// ---------- упоминания ----------

var mentionRe = regexp.MustCompile(`(?:^|[^\p{L}\p{N}_@])@([\p{L}\p{N}_.\-]{2,32})`)

// mentionsIn — кого зовут в сообщении: id участников и «all» для @все.
func mentionsIn(app core.App, chat, msg *core.Record) []string {
	if msg.GetBool("remind") {
		return []string{"all"}
	}
	var names []string
	all := false
	for _, m := range mentionRe.FindAllStringSubmatch(msg.GetString("text"), 20) {
		n := strings.ToLower(strings.TrimRight(m[1], ".-"))
		switch n {
		case "все", "всем", "all", "everyone", "here", "тут":
			all = true
		default:
			names = append(names, n)
		}
	}
	var out []string
	if all {
		out = append(out, "all")
	}
	if len(names) == 0 {
		return out
	}
	members := chat.GetStringSlice("members")
	users, err := app.FindRecordsByIds("users", members)
	if err != nil {
		return out
	}
	for _, u := range users {
		if contains(names, strings.ToLower(u.GetString("username"))) && !contains(out, u.Id) {
			out = append(out, u.Id)
		}
	}
	return out
}

// ---------- отложенные: отправляет сам сервер ----------

func runScheduler(app core.App) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for range t.C {
		sendDueScheduled(app)
	}
}

func sendDueScheduled(app core.App) {
	due, err := app.FindRecordsByFilter("scheduled", "at <= {:now}", "at", 50, 0, dbx.Params{"now": types.NowDateTime().String()})
	if err != nil || len(due) == 0 {
		return
	}
	col, err := app.FindCollectionByNameOrId("messages")
	if err != nil {
		return
	}
	for _, s := range due {
		author := s.GetString("author")
		if _, ok := memberOf(app, s.GetString("chat"), author); ok && author != "" {
			m := core.NewRecord(col)
			m.Set("chat", s.GetString("chat"))
			m.Set("author", author)
			m.Set("text", s.GetString("text"))
			m.Set("remind", s.GetBool("remind"))
			if err := app.Save(m); err != nil {
				app.Logger().Warn("scheduled send", "error", err)
			}
		}
		_ = app.Delete(s)
	}
}

// ---------- пересылка ----------

var storedSuffix = regexp.MustCompile(`_[a-z0-9]{10}(\.[^.]*)?$`)

// copyName: «photo_ab12cd34ef.jpg» → «photo_<новый хвост>.jpg».
func copyName(stored string) (original, fresh string) {
	ext := ""
	if m := storedSuffix.FindStringSubmatch(stored); m != nil {
		ext = m[1]
		original = strings.TrimSuffix(stored, m[0]) + ext
	} else {
		original = stored
		ext = filepath.Ext(stored)
	}
	base := strings.TrimSuffix(original, ext)
	if base == "" {
		base = "file"
	}
	return original, base + "_" + security.RandomStringWithAlphabet(10, "abcdefghijklmnopqrstuvwxyz0123456789") + ext
}

func authorName(app core.App, msg *core.Record) string {
	if f := msg.GetString("fwd"); f != "" {
		return f
	}
	u, err := app.FindRecordById("users", msg.GetString("author"))
	if err != nil {
		return "Неизвестный"
	}
	return firstNonEmpty(u.GetString("name"), u.GetString("username"))
}

func forwardMessage(app core.App, orig *core.Record, chatID, userID string) error {
	col := orig.Collection()
	rec := core.NewRecord(col)
	rec.Set("chat", chatID)
	rec.Set("author", userID)
	rec.Set("text", orig.GetString("text"))
	rec.Set("fwd", authorName(app, orig))
	rec.Set("sticker", orig.GetString("sticker"))
	if g := strings.TrimSpace(orig.GetString("gif")); g != "" && g != "null" {
		rec.Set("gif", orig.Get("gif"))
	}
	if p := readPoll(orig); p != nil {
		rec.Set("poll", p)
	}
	var files []*filesystem.File
	for _, name := range orig.GetStringSlice("files") {
		path := filepath.Join(app.DataDir(), core.LocalStorageDirName, orig.BaseFilesPath(), name)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		f, err := filesystem.NewFileFromPath(path)
		if err != nil {
			continue
		}
		f.OriginalName, f.Name = copyName(name)
		files = append(files, f)
	}
	if len(files) > 0 {
		rec.Set("files", files)
	}
	return app.Save(rec)
}

// ---------- превью ссылок ----------

var urlRe = regexp.MustCompile(`https?://[^\s<>"'` + "`" + `]+`)

func firstURL(text string) string {
	u := urlRe.FindString(text)
	return strings.TrimRight(u, ".,;:!?)]}»…'\"")
}

var (
	previewSem   = make(chan struct{}, 4)
	previewMu    sync.Mutex
	previewCache = map[string]map[string]any{}
)

func hasJSON(r *core.Record, key string) bool {
	v := strings.TrimSpace(r.GetString(key))
	return v != "" && v != "null"
}

func maybeFetchPreview(app core.App, msg *core.Record) {
	if hasJSON(msg, "preview") || len(msg.GetStringSlice("files")) > 0 || msg.GetString("sticker") != "" || hasJSON(msg, "gif") {
		return
	}
	u := firstURL(msg.GetString("text"))
	if u == "" {
		return
	}
	id := msg.Id
	go func() {
		previewSem <- struct{}{}
		defer func() { <-previewSem }()
		p := cachedPreview(u)
		fresh, err := app.FindRecordById("messages", id)
		if err != nil || firstURL(fresh.GetString("text")) != u || hasJSON(fresh, "preview") {
			return
		}
		fresh.Set("preview", p)
		if err := app.Save(fresh); err != nil {
			app.Logger().Debug("link preview", "error", err)
		}
	}()
}

func cachedPreview(u string) map[string]any {
	previewMu.Lock()
	if p, ok := previewCache[u]; ok {
		previewMu.Unlock()
		return p
	}
	previewMu.Unlock()
	p, err := fetchPreview(u)
	if err != nil || p == nil {
		p = map[string]any{"url": u, "fail": true}
	}
	previewMu.Lock()
	if len(previewCache) > 300 {
		previewCache = map[string]map[string]any{}
	}
	previewCache[u] = p
	previewMu.Unlock()
	return p
}

// Превью не ходит в домашнюю сеть сервера (чтобы ссылкой нельзя было «прощупать» роутер).
func publicOnly(network, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() {
		return errors.New("адрес в локальной сети")
	}
	if v4 := ip.To4(); v4 != nil && v4[0] == 100 && v4[1]&0xC0 == 64 { // 100.64.0.0/10
		return errors.New("адрес в локальной сети")
	}
	return nil
}

var webClient = &http.Client{
	Timeout: 8 * time.Second,
	Transport: &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, Control: publicOnly}).DialContext,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 6 * time.Second,
		MaxIdleConns:          10,
		IdleConnTimeout:       30 * time.Second,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("слишком много переадресаций")
		}
		return nil
	},
}

func webGet(u string) (*http.Response, error) {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; WinterChat/1.0; facebookexternalhit/1.1)")
	req.Header.Set("Accept-Language", "ru,en;q=0.8")
	return webClient.Do(req)
}

func cut(s string, n int) string {
	s = strings.Join(strings.Fields(html.UnescapeString(s)), " ")
	if utf8.RuneCountInString(s) > n {
		return string([]rune(s)[:n]) + "…"
	}
	return s
}

func isYouTube(host string) bool {
	host = strings.TrimPrefix(strings.ToLower(host), "www.")
	return host == "youtube.com" || host == "m.youtube.com" || host == "youtu.be" || host == "music.youtube.com"
}

var (
	metaRe  = regexp.MustCompile(`(?is)<meta\s[^>]*>`)
	attrRe  = regexp.MustCompile(`(?is)([a-zA-Z:_-]+)\s*=\s*("([^"]*)"|'([^']*)')`)
	titleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

func fetchPreview(raw string) (map[string]any, error) {
	pu, err := url.Parse(raw)
	if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" {
		return nil, errors.New("bad url")
	}
	if isYouTube(pu.Hostname()) {
		if p := youtubePreview(raw); p != nil {
			return p, nil
		}
	}
	resp, err := webGet(raw)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	site := strings.TrimPrefix(resp.Request.URL.Hostname(), "www.")
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if strings.HasPrefix(ct, "image/") {
		return map[string]any{"url": raw, "site": site, "image": raw}, nil
	}
	if !strings.Contains(ct, "html") {
		return nil, errors.New("not html")
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 768<<10))
	page := string(body)
	if i := strings.Index(strings.ToLower(page), "</head>"); i > 0 {
		page = page[:i]
	}
	meta := map[string]string{}
	for _, tag := range metaRe.FindAllString(page, -1) {
		attrs := map[string]string{}
		for _, m := range attrRe.FindAllStringSubmatch(tag, -1) {
			v := m[3]
			if v == "" {
				v = m[4]
			}
			attrs[strings.ToLower(m[1])] = v
		}
		key := strings.ToLower(firstNonEmpty(attrs["property"], attrs["name"]))
		if key != "" && attrs["content"] != "" {
			if _, seen := meta[key]; !seen {
				meta[key] = attrs["content"]
			}
		}
	}
	title := firstNonEmpty(meta["og:title"], meta["twitter:title"])
	if title == "" {
		if m := titleRe.FindStringSubmatch(page); m != nil {
			title = m[1]
		}
	}
	desc := firstNonEmpty(meta["og:description"], meta["twitter:description"], meta["description"])
	img := firstNonEmpty(meta["og:image"], meta["og:image:url"], meta["twitter:image"], meta["twitter:image:src"])
	if img != "" {
		if iu, err := resp.Request.URL.Parse(html.UnescapeString(img)); err == nil && (iu.Scheme == "https" || iu.Scheme == "http") {
			img = iu.String()
		} else {
			img = ""
		}
	}
	if s := meta["og:site_name"]; s != "" {
		site = s
	}
	title, desc = cut(title, 150), cut(desc, 300)
	if title == "" && desc == "" && img == "" {
		return nil, errors.New("nothing")
	}
	return map[string]any{"url": raw, "site": cut(site, 60), "title": title, "desc": desc, "image": img}, nil
}

func youtubePreview(raw string) map[string]any {
	resp, err := webGet("https://www.youtube.com/oembed?format=json&url=" + url.QueryEscape(raw))
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var o struct {
		Title  string `json:"title"`
		Author string `json:"author_name"`
		Thumb  string `json:"thumbnail_url"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&o) != nil || o.Title == "" {
		return nil
	}
	return map[string]any{"url": raw, "site": "YouTube", "title": cut(o.Title, 150), "desc": cut(o.Author, 100), "image": o.Thumb, "yt": true}
}

// ---------- GIF (Giphy, ключ вставляет хозяин сервера в панели) ----------

type gifItem struct {
	ID      string `json:"id"`
	URL     string `json:"url"`
	Preview string `json:"preview"`
	W       int    `json:"w"`
	H       int    `json:"h"`
}

var (
	gifMu    sync.Mutex
	gifCache = map[string]struct {
		at    time.Time
		items []gifItem
	}{}
)

func searchGifs(q string, offset int) ([]gifItem, error) {
	key := fmt.Sprintf("%s|%d", strings.ToLower(q), offset)
	gifMu.Lock()
	if c, ok := gifCache[key]; ok && time.Since(c.at) < 10*time.Minute {
		gifMu.Unlock()
		return c.items, nil
	}
	gifMu.Unlock()
	v := url.Values{}
	v.Set("api_key", cfg.GiphyKey)
	v.Set("limit", "24")
	v.Set("offset", strconv.Itoa(offset))
	v.Set("rating", "pg-13")
	endpoint := "https://api.giphy.com/v1/gifs/trending?"
	if q != "" {
		v.Set("q", q)
		v.Set("lang", "ru")
		endpoint = "https://api.giphy.com/v1/gifs/search?"
	}
	resp, err := webGet(endpoint + v.Encode())
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Giphy ответил %d — проверь ключ в панели сервера", resp.StatusCode)
	}
	type img struct {
		URL    string `json:"url"`
		Width  string `json:"width"`
		Height string `json:"height"`
	}
	var out struct {
		Data []struct {
			ID     string `json:"id"`
			Images struct {
				FixedHeight      img `json:"fixed_height"`
				FixedHeightSmall img `json:"fixed_height_small"`
			} `json:"images"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&out); err != nil {
		return nil, err
	}
	var items []gifItem
	for _, d := range out.Data {
		w, _ := strconv.Atoi(d.Images.FixedHeight.Width)
		h, _ := strconv.Atoi(d.Images.FixedHeight.Height)
		if d.Images.FixedHeight.URL == "" {
			continue
		}
		items = append(items, gifItem{d.ID, d.Images.FixedHeight.URL, firstNonEmpty(d.Images.FixedHeightSmall.URL, d.Images.FixedHeight.URL), w, h})
	}
	gifMu.Lock()
	if len(gifCache) > 200 {
		gifCache = map[string]struct {
			at    time.Time
			items []gifItem
		}{}
	}
	gifCache[key] = struct {
		at    time.Time
		items []gifItem
	}{time.Now(), items}
	gifMu.Unlock()
	return items, nil
}

// ---------- пути API ----------

func registerExtrasRoutes(se *core.ServeEvent) {
	r := se.Router
	auth := apis.RequireAuth("users")

	// Голос в опросе (пустой список — отменить свой голос).
	r.POST("/api/wc/vote", func(e *core.RequestEvent) error {
		var body struct {
			Message string `json:"message"`
			Options []int  `json:"options"`
		}
		if err := e.BindBody(&body); err != nil || body.Message == "" {
			return e.BadRequestError("Не указан опрос", nil)
		}
		var saved *core.Record
		err := e.App.RunInTransaction(func(tx core.App) error {
			msg, err := tx.FindRecordById("messages", body.Message)
			if err != nil {
				return apis.NewNotFoundError("Опрос не найден", nil)
			}
			if _, ok := memberOf(tx, msg.GetString("chat"), e.Auth.Id); !ok {
				return apis.NewForbiddenError("Ты не участник этого чата", nil)
			}
			poll := readPoll(msg)
			if poll == nil {
				return apis.NewBadRequestError("Это не опрос", nil)
			}
			var picked []int
			for _, o := range body.Options {
				if o < 0 || o >= len(poll.O) {
					return apis.NewBadRequestError("Нет такого варианта", nil)
				}
				dup := false
				for _, p := range picked {
					dup = dup || p == o
				}
				if !dup {
					picked = append(picked, o)
				}
			}
			if !poll.M && len(picked) > 1 {
				return apis.NewBadRequestError("Тут можно выбрать только один вариант", nil)
			}
			votes := map[string][]int{}
			_ = json.Unmarshal([]byte(msg.GetString("votes")), &votes)
			if votes == nil {
				votes = map[string][]int{}
			}
			if len(picked) == 0 {
				delete(votes, e.Auth.Id)
			} else {
				votes[e.Auth.Id] = picked
			}
			msg.Set("votes", votes)
			saved = msg
			return tx.Save(msg)
		})
		if err != nil {
			return err
		}
		return e.JSON(http.StatusOK, map[string]any{"votes": saved.Get("votes")})
	}).Bind(auth)

	// Переслать сообщение в другие чаты (файлы копируются на сервере).
	r.POST("/api/wc/forward", func(e *core.RequestEvent) error {
		var body struct {
			Message string   `json:"message"`
			Chats   []string `json:"chats"`
		}
		if err := e.BindBody(&body); err != nil || body.Message == "" || len(body.Chats) == 0 {
			return e.BadRequestError("Не указано, что и куда пересылать", nil)
		}
		if len(body.Chats) > 10 {
			return e.BadRequestError("Можно переслать максимум в 10 чатов сразу", nil)
		}
		orig, err := e.App.FindRecordById("messages", body.Message)
		if err != nil {
			return e.NotFoundError("Сообщение не найдено", nil)
		}
		if _, ok := memberOf(e.App, orig.GetString("chat"), e.Auth.Id); !ok {
			return e.ForbiddenError("Ты не участник этого чата", nil)
		}
		sent := 0
		for _, c := range body.Chats {
			if _, ok := memberOf(e.App, c, e.Auth.Id); !ok {
				continue
			}
			if err := forwardMessage(e.App, orig, c, e.Auth.Id); err != nil {
				e.App.Logger().Warn("forward", "error", err)
				continue
			}
			sent++
		}
		if sent == 0 {
			return e.BadRequestError("Не получилось переслать", nil)
		}
		return e.JSON(http.StatusOK, map[string]any{"sent": sent})
	}).Bind(auth)

	// Поиск GIF.
	r.GET("/api/wc/gifs", func(e *core.RequestEvent) error {
		if strings.TrimSpace(cfg.GiphyKey) == "" {
			return e.JSON(http.StatusOK, map[string]any{"enabled": false, "items": []gifItem{}})
		}
		q := strings.TrimSpace(e.Request.URL.Query().Get("q"))
		if utf8.RuneCountInString(q) > 50 {
			q = string([]rune(q)[:50])
		}
		offset, _ := strconv.Atoi(e.Request.URL.Query().Get("offset"))
		if offset < 0 || offset > 500 {
			offset = 0
		}
		items, err := searchGifs(q, offset)
		if err != nil {
			return e.JSON(http.StatusOK, map[string]any{"enabled": true, "items": []gifItem{}, "error": err.Error()})
		}
		if items == nil {
			items = []gifItem{}
		}
		return e.JSON(http.StatusOK, map[string]any{"enabled": true, "items": items})
	}).Bind(auth)

	// Панель: ключ Giphy.
	r.POST("/api/wc/panel/giphy", func(e *core.RequestEvent) error {
		if !isLocalRequest(e.Request) {
			return e.ForbiddenError("Только с этого компьютера", nil)
		}
		var body struct {
			Key string `json:"key"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("", nil)
		}
		key := strings.TrimSpace(body.Key)
		if len(key) > 100 || strings.ContainsAny(key, " \t\n&?/") {
			return e.BadRequestError("Это не похоже на ключ Giphy", nil)
		}
		cfg.GiphyKey = key
		saveConfig()
		gifMu.Lock()
		gifCache = map[string]struct {
			at    time.Time
			items []gifItem
		}{}
		gifMu.Unlock()
		return e.JSON(http.StatusOK, map[string]any{"ok": true, "gifs": key != ""})
	})
}
