package main

import (
	"encoding/json"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Игры с друзьями (из КБЖУ Трекера): шахматы по сети и гонка в сапёре.
//
// Одна запись games — одна партия. host создаёт приглашение (всем или конкретному другу),
// guest принимает — партия идёт. Ходы шахмат лежат в state (каждое изменение увеличивает seq,
// чтобы два одновременных хода не затёрли друг друга). В сапёре каждый пишет только своё поле
// host_state / guest_state, а победителя сервер считает сам.

var gameKinds = []string{"chess", "mines"}

func ensureGamesSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	col, err := app.FindCollectionByNameOrId("games")
	if err != nil {
		col = core.NewBaseCollection("games")
		col.Fields.Add(&core.SelectField{Name: "kind", Values: gameKinds, MaxSelect: 1, Required: true})
		col.Fields.Add(&core.RelationField{Name: "host", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		col.Fields.Add(&core.RelationField{Name: "guest", CollectionId: users.Id, MaxSelect: 1, CascadeDelete: true})
		col.Fields.Add(&core.SelectField{Name: "status", Values: []string{"open", "playing", "done"}, MaxSelect: 1, Required: true})
		col.Fields.Add(&core.JSONField{Name: "state", MaxSize: 64 << 10})
		col.Fields.Add(&core.JSONField{Name: "host_state", MaxSize: 8 << 10})
		col.Fields.Add(&core.JSONField{Name: "guest_state", MaxSize: 8 << 10})
		col.Fields.Add(&core.NumberField{Name: "seq", OnlyInt: true})
		col.Fields.Add(&core.RelationField{Name: "winner", CollectionId: users.Id, MaxSelect: 1})
		col.Fields.Add(&core.TextField{Name: "result", Max: 40})
		col.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		col.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		col.AddIndex("idx_games_status", false, "status", "")
	}
	// Свои партии видят участники; открытые приглашения — все, кто вошёл.
	see := "host = @request.auth.id || guest = @request.auth.id || (status = 'open' && @request.auth.id != '' && (guest = '' || guest = @request.auth.id))"
	col.ListRule = types.Pointer(see)
	col.ViewRule = types.Pointer(see)
	col.CreateRule = types.Pointer(rulesAuthed)
	col.UpdateRule = types.Pointer(see)
	// Удалить можно своё приглашение или законченную партию (у себя в списке её просто не будет у обоих).
	col.DeleteRule = types.Pointer("host = @request.auth.id && status != 'playing'")
	return app.Save(col)
}

func jsonMap(r *core.Record, field string) map[string]any {
	out := map[string]any{}
	raw := r.Get(field)
	var b []byte
	switch v := raw.(type) {
	case types.JSONRaw:
		b = v
	case []byte:
		b = v
	case string:
		b = []byte(v)
	default:
		b, _ = json.Marshal(v)
	}
	_ = json.Unmarshal(b, &out)
	return out
}

func num(m map[string]any, k string) (float64, bool) {
	v, ok := m[k].(float64)
	return v, ok
}

// minesOutcome — итог гонки в сапёр по состояниям игроков.
// Состояние: {"open": клеток открыто, "won": мс (прошёл), "lost": true (подорвался / сдался / медленнее)}.
// Возвращает: done, winner ("host"/"guest"/""), result.
func minesOutcome(h, g map[string]any) (bool, string, string) {
	hw, hWon := num(h, "won")
	gw, gWon := num(g, "won")
	hLost := h["lost"] == true
	gLost := g["lost"] == true
	hDone := hWon || hLost
	gDone := gWon || gLost
	if !hDone || !gDone {
		return false, "", ""
	}
	switch {
	case hWon && gWon:
		if hw < gw {
			return true, "host", "faster"
		} else if gw < hw {
			return true, "guest", "faster"
		}
		return true, "", "draw"
	case hWon:
		return true, "host", "cleared"
	case gWon:
		return true, "guest", "cleared"
	}
	ho, _ := num(h, "open")
	gop, _ := num(g, "open")
	if ho > gop {
		return true, "host", "more"
	} else if gop > ho {
		return true, "guest", "more"
	}
	return true, "", "draw"
}

func registerGamesHooks(app core.App) {
	app.OnRecordCreateRequest("games").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		r := e.Record
		r.Set("host", e.Auth.Id)
		if r.GetString("guest") == e.Auth.Id {
			r.Set("guest", "")
		}
		r.Set("status", "open")
		r.Set("seq", 0)
		r.Set("winner", "")
		r.Set("result", "")
		r.Set("host_state", nil)
		r.Set("guest_state", nil)
		return e.Next()
	})

	app.OnRecordUpdateRequest("games").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		r := e.Record
		old := r.Original()
		me := e.Auth.Id
		host := old.GetString("host")
		guest := old.GetString("guest")
		status := old.GetString("status")

		// Никто не меняет вид игры и хозяина.
		r.Set("kind", old.GetString("kind"))
		r.Set("host", host)

		if status == "done" {
			return e.BadRequestError("Партия уже закончена", nil)
		}

		// Принять приглашение.
		if me != host && me != guest || (status == "open" && me != host) {
			if status != "open" || (guest != "" && guest != me) || me == host {
				return e.ForbiddenError("Это не твоя партия", nil)
			}
			r.Set("guest", me)
			r.Set("status", "playing")
			r.Set("state", old.Get("state"))
			r.Set("host_state", old.Get("host_state"))
			r.Set("guest_state", old.Get("guest_state"))
			r.Set("seq", old.GetInt("seq")+1)
			r.Set("winner", "")
			r.Set("result", "")
			return e.Next()
		}

		// Хозяин, пока никто не принял: может только поменять приглашение (кого позвать).
		if status == "open" {
			if g := r.GetString("guest"); g == me {
				r.Set("guest", "")
			}
			r.Set("status", "open")
			r.Set("seq", old.GetInt("seq"))
			r.Set("winner", "")
			r.Set("result", "")
			return e.Next()
		}

		// Партия идёт: участники.
		r.Set("guest", guest)
		if w := r.GetString("winner"); w != "" && w != host && w != guest {
			return e.BadRequestError("Победитель — не участник", nil)
		}
		if st := r.GetString("status"); st != "playing" && st != "done" {
			r.Set("status", "playing")
		}

		if old.GetString("kind") == "mines" {
			// Каждый пишет только своё; общий state не меняется.
			r.Set("state", old.Get("state"))
			if me == host {
				r.Set("guest_state", old.Get("guest_state"))
			} else {
				r.Set("host_state", old.Get("host_state"))
			}
			done, who, res := minesOutcome(jsonMap(r, "host_state"), jsonMap(r, "guest_state"))
			if done {
				r.Set("status", "done")
				r.Set("result", res)
				switch who {
				case "host":
					r.Set("winner", host)
				case "guest":
					r.Set("winner", guest)
				default:
					r.Set("winner", "")
				}
			} else {
				r.Set("status", "playing")
				r.Set("winner", "")
				r.Set("result", "")
			}
			r.Set("seq", old.GetInt("seq")+1)
			return e.Next()
		}

		// Шахматы: ход принимается, только если клиент видел последнюю версию партии.
		if r.GetInt("seq") != old.GetInt("seq")+1 {
			return e.BadRequestError("Партия изменилась — обнови", nil)
		}
		r.Set("host_state", old.Get("host_state"))
		r.Set("guest_state", old.Get("guest_state"))
		if r.GetString("status") != "done" {
			r.Set("winner", "")
			r.Set("result", "")
		}
		return e.Next()
	})
}

// cleanupGames: приглашения старше суток удаляем, брошенные партии (неделю без ходов) закрываем.
func cleanupGames(app core.App) {
	now := time.Now().UTC()
	dayAgo := now.Add(-24 * time.Hour).Format(types.DefaultDateLayout)
	weekAgo := now.Add(-7 * 24 * time.Hour).Format(types.DefaultDateLayout)
	if old, err := app.FindRecordsByFilter("games", "status = 'open' && updated < {:t}", "", 200, 0, dbx.Params{"t": dayAgo}); err == nil {
		for _, r := range old {
			_ = app.Delete(r)
		}
	}
	// Гонка в сапёр, где кто-то закрыл приложение: через 30 минут без новостей недоигравший считается проигравшим.
	halfHour := now.Add(-30 * time.Minute).Format(types.DefaultDateLayout)
	if stuck, err := app.FindRecordsByFilter("games", "kind = 'mines' && status = 'playing' && updated < {:t}", "", 200, 0, dbx.Params{"t": halfHour}); err == nil {
		for _, r := range stuck {
			h, g := jsonMap(r, "host_state"), jsonMap(r, "guest_state")
			for _, m := range []map[string]any{h, g} {
				if _, won := num(m, "won"); !won {
					m["lost"] = true
				}
			}
			_, who, res := minesOutcome(h, g)
			r.Set("host_state", h)
			r.Set("guest_state", g)
			r.Set("status", "done")
			r.Set("result", res)
			switch who {
			case "host":
				r.Set("winner", r.GetString("host"))
			case "guest":
				r.Set("winner", r.GetString("guest"))
			}
			_ = app.Save(r)
		}
	}
	if stale, err := app.FindRecordsByFilter("games", "status = 'playing' && updated < {:t}", "", 200, 0, dbx.Params{"t": weekAgo}); err == nil {
		for _, r := range stale {
			r.Set("status", "done")
			r.Set("result", "abandoned")
			_ = app.Save(r)
		}
	}
}

func gamesInfo() map[string]any {
	return map[string]any{"kinds": gameKinds, "version": 1}
}
