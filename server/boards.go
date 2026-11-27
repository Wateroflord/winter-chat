package main

import (
	"slices"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Общие доски задач (плагин «Фокус» в КБЖУ Трекере): один проект на несколько друзей,
// например игра FalseMemory. boards — доска (название, цвет, владелец, участники),
// board_tasks — задачи на ней (колонки «Надо / В работе / Готово»).

var boardStatuses = []string{"todo", "doing", "done"}

const (
	boardMember = "@request.auth.id != '' && (owner = @request.auth.id || members.id ?= @request.auth.id)"
	taskMember  = "@request.auth.id != '' && (board.owner = @request.auth.id || board.members.id ?= @request.auth.id)"
)

func ensureBoardsSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	boards, err := app.FindCollectionByNameOrId("boards")
	if err != nil {
		boards = core.NewBaseCollection("boards")
		boards.Fields.Add(&core.TextField{Name: "name", Required: true, Max: 60})
		boards.Fields.Add(&core.NumberField{Name: "color", OnlyInt: true})
		boards.Fields.Add(&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		boards.Fields.Add(&core.RelationField{Name: "members", CollectionId: users.Id, MaxSelect: 20})
		boards.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		boards.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
	}
	// Доску видят и меняют её участники, удалить может только владелец.
	boards.ListRule = types.Pointer(boardMember)
	boards.ViewRule = types.Pointer(boardMember)
	boards.CreateRule = types.Pointer(rulesAuthed)
	boards.UpdateRule = types.Pointer(boardMember)
	boards.DeleteRule = types.Pointer("owner = @request.auth.id")
	if err := app.Save(boards); err != nil {
		return err
	}

	tasks, err := app.FindCollectionByNameOrId("board_tasks")
	if err != nil {
		tasks = core.NewBaseCollection("board_tasks")
		tasks.Fields.Add(&core.RelationField{Name: "board", CollectionId: boards.Id, MaxSelect: 1, Required: true, CascadeDelete: true})
		tasks.Fields.Add(&core.TextField{Name: "title", Required: true, Max: 200})
		tasks.Fields.Add(&core.TextField{Name: "note", Max: 2000})
		tasks.Fields.Add(&core.SelectField{Name: "status", Values: boardStatuses, MaxSelect: 1, Required: true})
		tasks.Fields.Add(&core.RelationField{Name: "assignee", CollectionId: users.Id, MaxSelect: 1})
		tasks.Fields.Add(&core.RelationField{Name: "author", CollectionId: users.Id, MaxSelect: 1})
		tasks.Fields.Add(&core.NumberField{Name: "pomodoros", OnlyInt: true, Min: types.Pointer(0.0)})
		tasks.Fields.Add(&core.NumberField{Name: "sort"})
		tasks.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
		tasks.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
		tasks.AddIndex("idx_board_tasks_board", false, "board", "")
	}
	tasks.ListRule = types.Pointer(taskMember)
	tasks.ViewRule = types.Pointer(taskMember)
	tasks.CreateRule = types.Pointer(taskMember)
	tasks.UpdateRule = types.Pointer(taskMember)
	tasks.DeleteRule = types.Pointer(taskMember)
	return app.Save(tasks)
}

func registerBoardsHooks(app core.App) {
	// Владелец — всегда тот, кто создал доску; он же сразу участник.
	app.OnRecordCreateRequest("boards").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("owner", e.Auth.Id)
		members := e.Record.GetStringSlice("members")
		if !slices.Contains(members, e.Auth.Id) {
			e.Record.Set("members", append(members, e.Auth.Id))
		}
		return e.Next()
	})
	// Владельца сменить нельзя. Участников меняет владелец; остальные могут только выйти сами.
	app.OnRecordUpdateRequest("boards").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		orig := e.Record.Original()
		owner := orig.GetString("owner")
		e.Record.Set("owner", owner)
		// Хозяин всегда остаётся участником.
		if members := e.Record.GetStringSlice("members"); !slices.Contains(members, owner) {
			e.Record.Set("members", append(members, owner))
		}
		if e.Auth.Id != owner {
			before := orig.GetStringSlice("members")
			after := e.Record.GetStringSlice("members")
			leave := slices.DeleteFunc(slices.Clone(before), func(id string) bool { return id == e.Auth.Id })
			if !sameIDs(after, before) && !sameIDs(after, leave) {
				return e.ForbiddenError("Участников меняет только хозяин доски", nil)
			}
		}
		return e.Next()
	})
	// Автор задачи — тот, кто её создал.
	app.OnRecordCreateRequest("board_tasks").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Нужно войти", nil)
		}
		e.Record.Set("author", e.Auth.Id)
		if e.Record.GetString("status") == "" {
			e.Record.Set("status", "todo")
		}
		return e.Next()
	})
	// Задачу нельзя перенести на чужую доску.
	app.OnRecordUpdateRequest("board_tasks").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("board", e.Record.Original().GetString("board"))
		e.Record.Set("author", e.Record.Original().GetString("author"))
		return e.Next()
	})
}

// sameIDs — одинаковые наборы id (порядок не важен).
func sameIDs(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	x, y := slices.Clone(a), slices.Clone(b)
	slices.Sort(x)
	slices.Sort(y)
	return slices.Equal(x, y)
}
