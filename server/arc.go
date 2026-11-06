package main

import (
	"math"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Winter Arc — соревнование по дисциплине (очки приходят из КБЖУ Трекера).
// Каждый день у каждого — одна запись arc_scores с очками по частям.
const ArcDays = 365

// Части очков и максимум за день (вместе — 100).
var arcParts = []string{"food", "water", "sleep", "steps", "workout"}

var arcMax = map[string]float64{"food": 30, "water": 10, "sleep": 20, "steps": 20, "workout": 20}

const dayLayout = "2006-01-02"

func today() string { return time.Now().Format(dayLayout) }

// arcEnd — последний день Winter Arc.
func arcEnd(start string) string {
	t, err := time.Parse(dayLayout, start)
	if err != nil {
		return ""
	}
	return t.AddDate(0, 0, ArcDays-1).Format(dayLayout)
}

func ensureArcSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	col, err := app.FindCollectionByNameOrId("arc_scores")
	if err != nil {
		col = core.NewBaseCollection("arc_scores")
		col.Fields.Add(&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		col.Fields.Add(&core.TextField{Name: "day", Required: true, Max: 10, Pattern: `^\d{4}-\d{2}-\d{2}$`})
		for _, n := range arcParts {
			col.Fields.Add(&core.NumberField{Name: n, Min: types.Pointer(0.0), Max: types.Pointer(arcMax[n])})
		}
		col.Fields.Add(&core.NumberField{Name: "total", Min: types.Pointer(0.0), Max: types.Pointer(100.0)})
		col.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		col.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		col.AddIndex("idx_arc_user_day", true, "user, day", "")
	}
	// Рейтинг видят все участники сервера, менять можно только свои очки.
	col.ListRule = types.Pointer(rulesAuthed)
	col.ViewRule = types.Pointer(rulesAuthed)
	col.CreateRule = types.Pointer(rulesAuthed)
	col.UpdateRule = types.Pointer("user = @request.auth.id")
	col.DeleteRule = nil
	return app.Save(col)
}

// arcClamp приводит очки к допустимым и пересчитывает сумму.
// Возвращает текст ошибки или "".
func arcClamp(r *core.Record, now time.Time) string {
	day := r.GetString("day")
	t, err := time.Parse(dayLayout, day)
	if err != nil {
		return "Неверная дата"
	}
	if day < cfg.ArcStart || day > arcEnd(cfg.ArcStart) {
		return "Этот день не входит в Winter Arc"
	}
	if t.After(now.AddDate(0, 0, 1)) {
		return "Этот день ещё не наступил"
	}
	total := 0.0
	for _, n := range arcParts {
		v := math.Round(math.Max(0, math.Min(arcMax[n], r.GetFloat(n))))
		r.Set(n, v)
		total += v
	}
	r.Set("total", total)
	return ""
}

func registerArcHooks(app core.App) {
	check := func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("user", e.Auth.Id) // очки всегда записываются тому, кто вошёл
		if msg := arcClamp(e.Record, time.Now()); msg != "" {
			return e.BadRequestError(msg, nil)
		}
		return e.Next()
	}
	app.OnRecordCreateRequest("arc_scores").BindFunc(check)
	app.OnRecordUpdateRequest("arc_scores").BindFunc(check)
}

func arcInfo() map[string]any {
	return map[string]any{"start": cfg.ArcStart, "end": arcEnd(cfg.ArcStart), "days": ArcDays, "max": arcMax}
}
