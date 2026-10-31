package main

import (
	"fmt"
	"strings"
	"unicode/utf8"

	validation "github.com/pocketbase/ozzo-validation/v4"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const (
	rulesAuthed    = "@request.auth.id != ''"
	ruleChatMember = "members.id ?= @request.auth.id"
	ruleMsgMember  = "chat.members.id ?= @request.auth.id"
)

// ensureSchema создаёт таблицы при первом запуске и обновляет их в новых версиях.
func ensureSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}

	// --- users: вход по логину и паролю ---
	if users.Fields.GetByName("username") == nil {
		users.Fields.Add(&core.TextField{
			Name:     "username",
			Required: true,
			Min:      3,
			Max:      24,
			Pattern:  `^[a-zA-Z0-9_.\-]+$`,
		})
	}
	users.AddIndex("idx_users_username", true, "`username` COLLATE NOCASE", "")
	if f, ok := users.Fields.GetByName("email").(*core.EmailField); ok {
		f.Required = false
	}
	users.PasswordAuth.Enabled = true
	users.PasswordAuth.IdentityFields = []string{"username"}
	users.ListRule = types.Pointer(rulesAuthed)
	users.ViewRule = types.Pointer(rulesAuthed)
	users.CreateRule = types.Pointer("")
	users.UpdateRule = types.Pointer("id = @request.auth.id")
	users.DeleteRule = nil
	users.AuthAlert.Enabled = false
	users.AuthToken.Duration = 60 * 60 * 24 * 365 // год, чтобы друзьям не приходилось входить заново
	if err := app.Save(users); err != nil {
		return fmt.Errorf("users: %w", err)
	}

	// --- chats: личные чаты и группы ---
	chats, err := app.FindCollectionByNameOrId("chats")
	if err != nil {
		chats = core.NewBaseCollection("chats")
		chats.Fields.Add(&core.TextField{Name: "name", Max: 80})
		chats.Fields.Add(&core.BoolField{Name: "is_group"})
		chats.Fields.Add(&core.RelationField{Name: "members", CollectionId: users.Id, MaxSelect: 100, Required: true})
		chats.Fields.Add(&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1})
		chats.Fields.Add(&core.TextField{Name: "last_text", Max: 300})
		chats.Fields.Add(&core.DateField{Name: "last_at"})
		chats.Fields.Add(&core.RelationField{Name: "last_author", CollectionId: users.Id, MaxSelect: 1})
		chats.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		chats.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
	}
	chats.ListRule = types.Pointer(ruleChatMember)
	chats.ViewRule = types.Pointer(ruleChatMember)
	chats.CreateRule = types.Pointer(rulesAuthed)
	chats.UpdateRule = types.Pointer(ruleChatMember)
	chats.DeleteRule = types.Pointer("owner = @request.auth.id")
	if err := app.Save(chats); err != nil {
		return fmt.Errorf("chats: %w", err)
	}

	// --- messages ---
	messages, err := app.FindCollectionByNameOrId("messages")
	if err != nil {
		messages = core.NewBaseCollection("messages")
		messages.Fields.Add(&core.RelationField{Name: "chat", CollectionId: chats.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		messages.Fields.Add(&core.RelationField{Name: "author", CollectionId: users.Id, MaxSelect: 1})
		messages.Fields.Add(&core.TextField{Name: "text", Max: 8000})
		messages.Fields.Add(&core.FileField{
			Name:      "files",
			MaxSelect: 10,
			MaxSize:   1 << 30, // 1 ГБ на файл
			Thumbs:    []string{"480x0", "1280x0"},
		})
		messages.Fields.Add(&core.BoolField{Name: "edited"})
		messages.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		messages.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		messages.AddIndex("idx_messages_chat_created", false, "chat, created", "")
	}
	messages.ListRule = types.Pointer(ruleMsgMember)
	messages.ViewRule = types.Pointer(ruleMsgMember)
	messages.CreateRule = types.Pointer(rulesAuthed + " && " + ruleMsgMember)
	messages.UpdateRule = types.Pointer("author = @request.auth.id")
	messages.DeleteRule = types.Pointer("author = @request.auth.id")
	if err := app.Save(messages); err != nil {
		return fmt.Errorf("messages: %w", err)
	}

	// --- calls: кто сейчас в звонке (заполняет сам сервер) ---
	calls, err := app.FindCollectionByNameOrId("calls")
	if err != nil {
		calls = core.NewBaseCollection("calls")
		calls.Fields.Add(&core.RelationField{Name: "chat", CollectionId: chats.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		calls.Fields.Add(&core.RelationField{Name: "participants", CollectionId: users.Id, MaxSelect: 100})
		calls.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		calls.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		calls.AddIndex("idx_calls_chat", true, "chat", "")
	}
	calls.ListRule = types.Pointer(ruleMsgMember)
	calls.ViewRule = types.Pointer(ruleMsgMember)
	calls.CreateRule = nil
	calls.UpdateRule = nil
	calls.DeleteRule = nil
	if err := app.Save(calls); err != nil {
		return fmt.Errorf("calls: %w", err)
	}
	return nil
}

func ensureSuperuser(app core.App) error {
	col, err := app.FindCollectionByNameOrId(core.CollectionNameSuperusers)
	if err != nil {
		return err
	}
	rec, err := app.FindAuthRecordByEmail(col, cfg.AdminEmail)
	if err != nil {
		rec = core.NewRecord(col)
		rec.SetEmail(cfg.AdminEmail)
	}
	rec.SetPassword(cfg.AdminPassword)
	return app.Save(rec)
}

func clearCalls(app core.App) {
	recs, err := app.FindAllRecords("calls")
	if err != nil {
		return
	}
	for _, r := range recs {
		_ = app.Delete(r)
	}
}

// registerHooks — проверки, которые нельзя выразить правилами.
func registerHooks(app core.App) {
	// Регистрация только с кодом приглашения.
	app.OnRecordCreateRequest("users").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.HasSuperuserAuth() {
			return e.Next()
		}
		info, err := e.RequestInfo()
		if err != nil {
			return err
		}
		code := ""
		if v, ok := info.Body["invite"]; ok {
			code = fmt.Sprint(v)
		}
		if code == "" {
			code = info.Query["invite"]
		}
		if !strings.EqualFold(strings.TrimSpace(code), cfg.InviteCode) {
			return e.BadRequestError("Неверный код приглашения", nil)
		}
		name := strings.TrimSpace(e.Record.GetString("name"))
		if name == "" {
			e.Record.Set("name", e.Record.GetString("username"))
		}
		e.Record.SetEmailVisibility(false)
		return e.Next()
	})

	// Создатель чата всегда в участниках и становится владельцем.
	app.OnRecordCreateRequest("chats").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		members := e.Record.GetStringSlice("members")
		if !contains(members, e.Auth.Id) {
			members = append(members, e.Auth.Id)
		}
		e.Record.Set("members", members)
		e.Record.Set("owner", e.Auth.Id)
		if !e.Record.GetBool("is_group") {
			if len(members) != 2 {
				return e.BadRequestError("В личном чате должно быть два человека", nil)
			}
			// Не создаём второй личный чат с тем же человеком.
			other := members[0]
			if other == e.Auth.Id {
				other = members[1]
			}
			var existing *core.Record
			cands, _ := e.App.FindRecordsByFilter("chats", "is_group = false", "", 0, 0)
			for _, c := range cands {
				m := c.GetStringSlice("members")
				if len(m) == 2 && contains(m, e.Auth.Id) && contains(m, other) {
					existing = c
					break
				}
			}
			if existing != nil {
				return e.BadRequestError("Чат уже есть", map[string]validation.Error{
					"existing": validation.NewError(existing.Id, "chat exists"),
				})
			}
		}
		return e.Next()
	})

	// Автор сообщения — всегда тот, кто его отправил.
	app.OnRecordCreateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("author", e.Auth.Id)
		e.Record.Set("edited", false)
		return e.Next()
	})
	app.OnRecordUpdateRequest("messages").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("edited", true)
		return e.Next()
	})

	// Последнее сообщение показывается в списке чатов.
	app.OnRecordAfterCreateSuccess("messages").BindFunc(func(e *core.RecordEvent) error {
		updateChatPreview(e.App, e.Record)
		return e.Next()
	})
}

func updateChatPreview(app core.App, msg *core.Record) {
	chat, err := app.FindRecordById("chats", msg.GetString("chat"))
	if err != nil {
		return
	}
	text := strings.TrimSpace(msg.GetString("text"))
	files := msg.GetStringSlice("files")
	if text == "" && len(files) > 0 {
		text = previewForFiles(files)
	}
	if utf8.RuneCountInString(text) > 120 {
		text = string([]rune(text)[:120]) + "…"
	}
	chat.Set("last_text", text)
	chat.Set("last_at", msg.GetDateTime("created"))
	chat.Set("last_author", msg.GetString("author"))
	if err := app.Save(chat); err != nil {
		app.Logger().Warn("chat preview", "error", err)
	}
}

func previewForFiles(files []string) string {
	img, vid := 0, 0
	for _, f := range files {
		l := strings.ToLower(f)
		switch {
		case hasAnySuffix(l, ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".heic"):
			img++
		case hasAnySuffix(l, ".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v"):
			vid++
		}
	}
	switch {
	case img == len(files):
		return "🖼 Фото"
	case vid == len(files):
		return "🎬 Видео"
	default:
		return "📎 Файл"
	}
}

func hasAnySuffix(s string, suffixes ...string) bool {
	for _, x := range suffixes {
		if strings.HasSuffix(s, x) {
			return true
		}
	}
	return false
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
