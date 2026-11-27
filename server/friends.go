package main

import (
	"fmt"
	"net/http"
	"slices"
	"strings"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Winter Cloud: файл до 500 МБ, всего по умолчанию 10 ГБ (хозяин сервера меняет в панели).
// Помни: автокопии сервера включают и эти файлы.
const (
	cloudFileMax   = 500 << 20
	cloudDefaultGB = 10
	cloudMaxGB     = 2000
)

func cloudLimit() int64 {
	gb := cfg.CloudGB
	if gb <= 0 {
		gb = cloudDefaultGB
	}
	return int64(gb) << 30
}

// cloudUsed — сколько байт занято в облаке.
func cloudUsed(app core.App) int64 {
	var res struct {
		Total int64 `db:"total"`
	}
	if err := app.DB().NewQuery("SELECT COALESCE(SUM([[size]]), 0) AS total FROM {{cloud_files}}").One(&res); err != nil {
		return 0
	}
	return res.Total
}

func cloudInfo(app core.App) map[string]any {
	return map[string]any{"used": cloudUsed(app), "limit": cloudLimit(), "fileMax": cloudFileMax}
}

func gbText(b int64) string {
	return strings.Replace(fmt.Sprintf("%.1f", float64(b)/float64(1<<30)), ".", ",", 1)
}

// Раздел «Друзья» в Winter Chat:
//   game_nights — игровые вечера: во что, когда, кто идёт / может быть / не сможет;
//   cloud_files — Winter Cloud: общие файлы для всех на сервере;
//   users.dota_id — номер аккаунта Dota 2 для статистики (её приложение берёт с OpenDota).

var rsvpFields = []string{"going", "maybe", "no"}

func ensureFriendsSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	addField(users, &core.TextField{Name: "dota_id", Max: 20, Pattern: `^[0-9]*$`})
	if err := app.Save(users); err != nil {
		return err
	}

	nights, err := app.FindCollectionByNameOrId("game_nights")
	if err != nil {
		nights = core.NewBaseCollection("game_nights")
		nights.Fields.Add(&core.RelationField{Name: "author", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		nights.Fields.Add(&core.TextField{Name: "game", Required: true, Max: 60})
		nights.Fields.Add(&core.TextField{Name: "note", Max: 300})
		nights.Fields.Add(&core.DateField{Name: "at", Required: true})
		for _, f := range rsvpFields {
			nights.Fields.Add(&core.RelationField{Name: f, CollectionId: users.Id, MaxSelect: 50})
		}
		nights.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		nights.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		nights.AddIndex("idx_game_nights_at", false, "at", "")
	}
	// Вечера видят все друзья на сервере; отметиться может каждый, менять и удалять — автор.
	nights.ListRule = types.Pointer(rulesAuthed)
	nights.ViewRule = types.Pointer(rulesAuthed)
	nights.CreateRule = types.Pointer(rulesAuthed)
	nights.UpdateRule = types.Pointer(rulesAuthed)
	nights.DeleteRule = types.Pointer("author = @request.auth.id")
	if err := app.Save(nights); err != nil {
		return err
	}

	cloud, err := app.FindCollectionByNameOrId("cloud_files")
	if err != nil {
		cloud = core.NewBaseCollection("cloud_files")
		cloud.Fields.Add(&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		cloud.Fields.Add(&core.FileField{Name: "file", MaxSelect: 1, MaxSize: cloudFileMax, Required: true, Thumbs: []string{"480x0"}})
		cloud.Fields.Add(&core.TextField{Name: "name", Max: 200})
		cloud.Fields.Add(&core.TextField{Name: "folder", Max: 60})
		cloud.Fields.Add(&core.NumberField{Name: "size", OnlyInt: true})
		cloud.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		cloud.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
	}
	if f, ok := cloud.Fields.GetByName("file").(*core.FileField); ok {
		f.MaxSize = cloudFileMax
	}
	// Файлы видят и качают все друзья; удалить или переименовать может только тот, кто загрузил.
	cloud.ListRule = types.Pointer(rulesAuthed)
	cloud.ViewRule = types.Pointer(rulesAuthed)
	cloud.CreateRule = types.Pointer(rulesAuthed)
	cloud.UpdateRule = types.Pointer("owner = @request.auth.id")
	cloud.DeleteRule = types.Pointer("owner = @request.auth.id")
	return app.Save(cloud)
}

func registerFriendsHooks(app core.App) {
	app.OnRecordCreateRequest("game_nights").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("author", e.Auth.Id)
		// Автор, конечно, идёт.
		e.Record.Set("going", []string{e.Auth.Id})
		e.Record.Set("maybe", []string{})
		e.Record.Set("no", []string{})
		return e.Next()
	})
	app.OnRecordUpdateRequest("game_nights").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		orig := e.Record.Original()
		e.Record.Set("author", orig.GetString("author"))
		if e.Auth.Id == orig.GetString("author") {
			return e.Next()
		}
		// Остальные меняют только свою отметку: игру, время и описание правит автор.
		for _, f := range []string{"game", "note", "at"} {
			e.Record.Set(f, orig.Get(f))
		}
		for _, f := range rsvpFields {
			if !onlyChanged(orig.GetStringSlice(f), e.Record.GetStringSlice(f), e.Auth.Id) {
				return e.ForbiddenError("Можно отметить только себя", nil)
			}
		}
		return e.Next()
	})

	app.OnRecordCreateRequest("cloud_files").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("owner", e.Auth.Id)
		if files := e.Record.GetUnsavedFiles("file"); len(files) > 0 {
			size := files[0].Size
			if size > cloudFileMax {
				return e.BadRequestError("Файл больше 500 МБ — такой в облако не влезет", nil)
			}
			if used, limit := cloudUsed(e.App), cloudLimit(); used+size > limit {
				return e.BadRequestError(fmt.Sprintf("Облако заполнено: занято %s из %s ГБ. Удалите ненужное или попросите хозяина сервера увеличить место (панель сервера → Winter Cloud).", gbText(used), gbText(limit)), nil)
			}
			e.Record.Set("size", size)
			if strings.TrimSpace(e.Record.GetString("name")) == "" {
				e.Record.Set("name", files[0].OriginalName)
			}
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("cloud_files").BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		e.Record.Set("owner", orig.GetString("owner"))
		e.Record.Set("size", orig.GetInt("size"))
		return e.Next()
	})
}

// onlyChanged — в списке после изменения добавился или убран только [id] (или ничего).
func onlyChanged(before, after []string, id string) bool {
	strip := func(l []string) []string {
		out := slices.DeleteFunc(slices.Clone(l), func(x string) bool { return x == id })
		slices.Sort(out)
		return slices.Compact(out)
	}
	return slices.Equal(strip(before), strip(after))
}

// registerCloudRoutes — сколько места в облаке (для приложения) и настройка лимита (панель сервера).
func registerCloudRoutes(se *core.ServeEvent) {
	r := se.Router
	r.GET("/api/wc/cloud", func(e *core.RequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		return e.JSON(http.StatusOK, cloudInfo(e.App))
	})
	r.POST("/api/wc/panel/cloud-limit", func(e *core.RequestEvent) error {
		if !isLocalRequest(e.Request) {
			return e.ForbiddenError("", nil)
		}
		var body struct {
			GB int `json:"gb"`
		}
		if err := e.BindBody(&body); err != nil || body.GB < 1 || body.GB > cloudMaxGB {
			return e.BadRequestError(fmt.Sprintf("Укажи число от 1 до %d ГБ", cloudMaxGB), nil)
		}
		cfg.CloudGB = body.GB
		saveConfig()
		return e.JSON(http.StatusOK, cloudInfo(e.App))
	})
}
