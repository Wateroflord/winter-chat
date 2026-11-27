package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/subscriptions"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Живое общение: реакции, ответы, «печатает…», «прочитано», «в сети», закрепы,
// голосовые комнаты и автокопии базы.

const typingTopic = "wc_typing"

func ensureSocialSchema(app core.App) error {
	messages, err := app.FindCollectionByNameOrId("messages")
	if err != nil {
		return err
	}
	addField(messages, &core.RelationField{Name: "reply_to", CollectionId: messages.Id, MaxSelect: 1})
	addField(messages, &core.JSONField{Name: "reactions", MaxSize: 16 << 10})
	if err := app.Save(messages); err != nil {
		return err
	}

	chats, err := app.FindCollectionByNameOrId("chats")
	if err != nil {
		return err
	}
	addField(chats, &core.JSONField{Name: "reads", MaxSize: 16 << 10})
	addField(chats, &core.RelationField{Name: "pins", CollectionId: messages.Id, MaxSelect: 50})
	if err := app.Save(chats); err != nil {
		return err
	}

	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	addField(users, &core.DateField{Name: "last_seen"})
	if err := app.Save(users); err != nil {
		return err
	}

	calls, err := app.FindCollectionByNameOrId("calls")
	if err != nil {
		return err
	}
	addField(calls, &core.BoolField{Name: "quiet"})
	return app.Save(calls)
}

// memberOf — участник ли пользователь чата.
func memberOf(app core.App, chatID, userID string) (*core.Record, bool) {
	chat, err := app.FindRecordById("chats", chatID)
	if err != nil || !contains(chat.GetStringSlice("members"), userID) {
		return nil, false
	}
	return chat, true
}

func registerSocialHooks(app core.App) {
	// Ответ можно дать только на сообщение из того же чата.
	app.OnRecordCreateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		if to := e.Record.GetString("reply_to"); to != "" {
			orig, err := e.App.FindRecordById("messages", to)
			if err != nil || orig.GetString("chat") != e.Record.GetString("chat") {
				e.Record.Set("reply_to", "")
			}
		}
		e.Record.Set("reactions", nil)
		return e.Next()
	})
	// Реакции и «ответ на» меняются только через свои пути, не правкой сообщения.
	app.OnRecordUpdateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		old := e.Record.Original()
		e.Record.Set("reactions", old.Get("reactions"))
		e.Record.Set("reply_to", old.GetString("reply_to"))
		return e.Next()
	})
	// «Прочитано» и «в сети» ставит только сервер.
	app.OnRecordUpdateRequest("chats").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("reads", e.Record.Original().Get("reads"))
		return e.Next()
	})
	app.OnRecordUpdateRequest("users").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("last_seen", e.Record.Original().GetDateTime("last_seen"))
		return e.Next()
	})
}

// Голосовые комнаты: в «тихий» звонок можно зайти, но остальным он не звонит.
var (
	quietMu    sync.Mutex
	quietRooms = map[string]bool{}
)

func setQuiet(chat string, quiet bool) {
	quietMu.Lock()
	defer quietMu.Unlock()
	if quiet {
		quietRooms[chat] = true
	}
}

func isQuiet(chat string) bool {
	quietMu.Lock()
	defer quietMu.Unlock()
	return quietRooms[chat]
}

func forgetQuiet(chat string) {
	quietMu.Lock()
	defer quietMu.Unlock()
	delete(quietRooms, chat)
}

var reactionLimit = 12

func registerSocialRoutes(se *core.ServeEvent) {
	r := se.Router
	auth := apis.RequireAuth("users")

	// Поставить / снять реакцию.
	r.POST("/api/wc/react", func(e *core.RequestEvent) error {
		var body struct {
			Message string `json:"message"`
			Emoji   string `json:"emoji"`
		}
		if err := e.BindBody(&body); err != nil || body.Message == "" {
			return e.BadRequestError("Не указано сообщение", nil)
		}
		emoji := strings.TrimSpace(body.Emoji)
		if emoji == "" || utf8.RuneCountInString(emoji) > 8 || strings.ContainsAny(emoji, "<>\"'") {
			return e.BadRequestError("Такую реакцию поставить нельзя", nil)
		}
		var saved *core.Record
		err := e.App.RunInTransaction(func(tx core.App) error {
			msg, err := tx.FindRecordById("messages", body.Message)
			if err != nil {
				return apis.NewNotFoundError("Сообщение не найдено", nil)
			}
			if _, ok := memberOf(tx, msg.GetString("chat"), e.Auth.Id); !ok {
				return apis.NewForbiddenError("Ты не участник этого чата", nil)
			}
			reactions := map[string][]string{}
			_ = json.Unmarshal([]byte(msg.GetString("reactions")), &reactions)
			if reactions == nil { // в базе было null
				reactions = map[string][]string{}
			}
			users := reactions[emoji]
			if contains(users, e.Auth.Id) {
				var rest []string
				for _, u := range users {
					if u != e.Auth.Id {
						rest = append(rest, u)
					}
				}
				users = rest
			} else {
				if _, exists := reactions[emoji]; !exists && len(reactions) >= reactionLimit {
					return apis.NewBadRequestError("Слишком много разных реакций", nil)
				}
				users = append(users, e.Auth.Id)
			}
			if len(users) == 0 {
				delete(reactions, emoji)
			} else {
				reactions[emoji] = users
			}
			if len(reactions) == 0 {
				msg.Set("reactions", nil)
			} else {
				msg.Set("reactions", reactions)
			}
			saved = msg
			return tx.Save(msg)
		})
		if err != nil {
			return err
		}
		return e.JSON(http.StatusOK, map[string]any{"reactions": saved.Get("reactions")})
	}).Bind(auth)

	// «Печатает…»: пересылаем остальным участникам чата, в базу не пишем.
	r.POST("/api/wc/typing", func(e *core.RequestEvent) error {
		var body struct {
			Chat string `json:"chat"`
		}
		if err := e.BindBody(&body); err != nil || body.Chat == "" {
			return e.BadRequestError("Не указан чат", nil)
		}
		chat, ok := memberOf(e.App, body.Chat, e.Auth.Id)
		if !ok {
			return e.ForbiddenError("Ты не участник этого чата", nil)
		}
		data, _ := json.Marshal(map[string]string{"chat": chat.Id, "user": e.Auth.Id})
		members := chat.GetStringSlice("members")
		for _, c := range e.App.SubscriptionsBroker().Clients() {
			if !c.HasSubscription(typingTopic) {
				continue
			}
			who, _ := c.Get(apis.RealtimeClientAuthKey).(*core.Record)
			if who == nil || who.Id == e.Auth.Id || !contains(members, who.Id) {
				continue
			}
			c.Send(subscriptions.Message{Name: typingTopic, Data: data})
		}
		return e.NoContent(http.StatusNoContent)
	}).Bind(auth)

	// «Прочитано»: когда я последний раз смотрел чат.
	r.POST("/api/wc/read", func(e *core.RequestEvent) error {
		var body struct {
			Chat string `json:"chat"`
		}
		if err := e.BindBody(&body); err != nil || body.Chat == "" {
			return e.BadRequestError("Не указан чат", nil)
		}
		err := e.App.RunInTransaction(func(tx core.App) error {
			chat, ok := memberOf(tx, body.Chat, e.Auth.Id)
			if !ok {
				return apis.NewForbiddenError("Ты не участник этого чата", nil)
			}
			reads := map[string]string{}
			_ = json.Unmarshal([]byte(chat.GetString("reads")), &reads)
			if reads == nil {
				reads = map[string]string{}
			}
			now := types.NowDateTime().String()
			// Только если с прошлой отметки пришло что-то новое.
			if prev := reads[e.Auth.Id]; prev != "" && prev >= chat.GetString("last_at") {
				return nil
			}
			reads[e.Auth.Id] = now
			chat.Set("reads", reads)
			return tx.Save(chat)
		})
		if err != nil {
			return err
		}
		return e.NoContent(http.StatusNoContent)
	}).Bind(auth)

	// «В сети»: приложение отмечается раз в минуту, пока открыто.
	r.POST("/api/wc/ping", func(e *core.RequestEvent) error {
		u, err := e.App.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("", nil)
		}
		if time.Since(u.GetDateTime("last_seen").Time()) > 30*time.Second {
			u.Set("last_seen", types.NowDateTime())
			if err := e.App.Save(u); err != nil {
				return e.InternalServerError("", err)
			}
		}
		return e.NoContent(http.StatusNoContent)
	}).Bind(auth)
}

// ---------- автокопии базы ----------

const autoBackupPrefix = "winter_auto_"
const autoBackupKeep = 7

func backupsDir(app core.App) string { return filepath.Join(app.DataDir(), core.LocalBackupsDirName) }

type backupInfo struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	Time string `json:"time"`
}

func listBackups(app core.App) []backupInfo {
	entries, _ := os.ReadDir(backupsDir(app))
	var out []backupInfo
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".zip") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, backupInfo{e.Name(), info.Size(), info.ModTime().Format("2006-01-02 15:04")})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Time > out[j].Time })
	return out
}

// makeBackup создаёт копию базы и файлов, копирует её в выбранную папку и удаляет старые автокопии.
func makeBackup(app core.App, auto bool) (string, error) {
	prefix := "winter_manual_"
	if auto {
		prefix = autoBackupPrefix
	}
	name := prefix + time.Now().Format("20060102_150405") + ".zip"
	if err := app.CreateBackup(context.Background(), name); err != nil {
		return "", err
	}
	if cfg.BackupDir != "" {
		if err := copyFile(filepath.Join(backupsDir(app), name), filepath.Join(cfg.BackupDir, name)); err != nil {
			app.Logger().Warn("копия в папку не удалась", "error", err)
		} else {
			pruneBackups(cfg.BackupDir, autoBackupKeep*2)
		}
	}
	pruneBackups(backupsDir(app), autoBackupKeep)
	return name, nil
}

// pruneBackups оставляет [keep] свежих автокопий в папке.
func pruneBackups(dir string, keep int) {
	entries, _ := os.ReadDir(dir)
	var auto []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), autoBackupPrefix) && strings.HasSuffix(e.Name(), ".zip") {
			auto = append(auto, e.Name())
		}
	}
	sort.Strings(auto) // имя содержит дату — сортировка по времени
	for len(auto) > keep {
		_ = os.Remove(filepath.Join(dir, auto[0]))
		auto = auto[1:]
	}
}

// lastAutoBackup — время последней автокопии.
func lastAutoBackup(app core.App) time.Time {
	var last time.Time
	for _, b := range listBackups(app) {
		if !strings.HasPrefix(b.Name, autoBackupPrefix) {
			continue
		}
		if t, err := time.ParseInLocation("2006-01-02 15:04", b.Time, time.Local); err == nil && t.After(last) {
			last = t
		}
	}
	return last
}

// autoBackupIfDue — раз в сутки (ноутбук может быть выключен ночью, поэтому проверяем каждый час).
func autoBackupIfDue(app core.App) {
	if time.Since(lastAutoBackup(app)) < 23*time.Hour {
		return
	}
	if _, err := makeBackup(app, true); err != nil {
		app.Logger().Warn("автокопия не удалась", "error", err)
	}
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst + ".part")
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(dst+".part", dst)
}

func registerBackupPanelRoutes(se *core.ServeEvent) {
	r := se.Router
	r.POST("/api/wc/panel/backup", func(e *core.RequestEvent) error {
		if !isLocalRequest(e.Request) {
			return e.ForbiddenError("", nil)
		}
		name, err := makeBackup(e.App, false)
		if err != nil {
			return e.BadRequestError("Не удалось: "+err.Error(), nil)
		}
		return e.JSON(http.StatusOK, map[string]any{"name": name})
	})
	r.POST("/api/wc/panel/backup-dir", func(e *core.RequestEvent) error {
		if !isLocalRequest(e.Request) {
			return e.ForbiddenError("", nil)
		}
		var body struct {
			Dir string `json:"dir"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("", nil)
		}
		dir := strings.TrimSpace(body.Dir)
		if dir != "" {
			if !filepath.IsAbs(dir) {
				return e.BadRequestError("Нужен полный путь, например D:\\Копии Winter Chat", nil)
			}
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return e.BadRequestError("Папку не создать: "+err.Error(), nil)
			}
		}
		cfg.BackupDir = dir
		saveConfig()
		return e.JSON(http.StatusOK, map[string]any{"dir": dir})
	})
	r.POST("/api/wc/panel/open-backups", func(e *core.RequestEvent) error {
		if !isLocalRequest(e.Request) {
			return e.ForbiddenError("", nil)
		}
		dir := backupsDir(e.App)
		_ = os.MkdirAll(dir, 0o755)
		openBrowser(dir)
		return e.JSON(http.StatusOK, map[string]any{"dir": dir})
	})
}
