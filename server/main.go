// Winter Chat Server — сервер мессенджера Winter Chat для запуска на своём компьютере.
//
// Внутри: PocketBase (аккаунты, чаты, сообщения, файлы) и LiveKit
// (звонки, камера, демонстрация экрана), который запускается рядом
// отдельной программой livekit-server.
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
)

// Version подставляется при сборке (-ldflags "-X main.Version=...").
var Version = "dev"

const (
	HTTPPort   = 8090 // сайт/API, сюда подключаются приложения
	LKPort     = 7880 // сигналинг LiveKit (только для этого компьютера, наружу идёт через 8090)
	RTCTCPPort = 7881 // звонки через TCP
	RTCUDPPort = 7882 // звонки через UDP
)

// Config хранится в winter-chat-data/server.json.
type Config struct {
	InviteCode    string `json:"inviteCode"`
	LKKey         string `json:"livekitKey"`
	LKSecret      string `json:"livekitSecret"`
	AdminEmail    string `json:"adminEmail"`
	AdminPassword string `json:"adminPassword"`
}

var (
	baseDir string // папка с программой
	dataDir string // winter-chat-data
	cfg     Config
)

func main() {
	setupConsole()

	baseDir = programDir()
	dataDir = filepath.Join(baseDir, "winter-chat-data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		log.Fatalf("Не удалось создать папку %s: %v", dataDir, err)
	}
	loadOrCreateConfig()

	noBrowser := false
	var rest []string
	for _, a := range os.Args[1:] {
		if a == "--no-browser" {
			noBrowser = true
			continue
		}
		rest = append(rest, a)
	}
	// Двойной клик по программе = запуск сервера.
	if len(rest) == 0 {
		rest = []string{"serve", fmt.Sprintf("--http=0.0.0.0:%d", HTTPPort)}
	}
	os.Args = append([]string{os.Args[0]}, rest...)

	app := pocketbase.NewWithConfig(pocketbase.Config{
		DefaultDataDir:  filepath.Join(dataDir, "pb_data"),
		HideStartBanner: true,
	})

	registerHooks(app)
	registerRoutes(app)

	lk := newLiveKit(app)
	theLiveKit = lk
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		// Свой стартовый экран вместо установщика PocketBase.
		se.InstallerFunc = nil
		// Без лимита времени: большие файлы и долгие звонки.
		se.Server.ReadTimeout = 0
		se.Server.WriteTimeout = 0

		if err := ensureSchema(se.App); err != nil {
			return fmt.Errorf("подготовка базы: %w", err)
		}
		if err := ensureSuperuser(se.App); err != nil {
			return fmt.Errorf("создание администратора: %w", err)
		}
		clearCalls(se.App)

		if err := se.Next(); err != nil {
			return err
		}

		go lk.Run()
		go printBanner(noBrowser)
		return nil
	})
	app.OnTerminate().BindFunc(func(e *core.TerminateEvent) error {
		lk.Stop()
		return e.Next()
	})

	if err := app.Start(); err != nil {
		log.Println("Ошибка:", err)
		lk.Stop()
		pauseOnWindows()
		os.Exit(1)
	}
}

func programDir() string {
	exe, err := os.Executable()
	if err != nil {
		wd, _ := os.Getwd()
		return wd
	}
	if p, err := filepath.EvalSymlinks(exe); err == nil {
		exe = p
	}
	dir := filepath.Dir(exe)
	// go run собирает во временную папку — тогда работаем из текущей.
	if strings.Contains(dir, "go-build") {
		wd, _ := os.Getwd()
		return wd
	}
	return dir
}

func configPath() string { return filepath.Join(dataDir, "server.json") }

func loadOrCreateConfig() {
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	changed := false
	if cfg.InviteCode == "" {
		cfg.InviteCode = newInviteCode()
		changed = true
	}
	if cfg.LKKey == "" {
		cfg.LKKey = "WC" + randomString(12, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
		changed = true
	}
	if cfg.LKSecret == "" {
		cfg.LKSecret = randomString(48, "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
		changed = true
	}
	if cfg.AdminEmail == "" {
		cfg.AdminEmail = "admin@winterchat.local"
		changed = true
	}
	if cfg.AdminPassword == "" {
		cfg.AdminPassword = randomString(14, "abcdefghijkmnopqrstuvwxyz23456789")
		changed = true
	}
	if changed {
		saveConfig()
	}
}

func saveConfig() {
	b, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(configPath(), b, 0o600); err != nil {
		log.Println("Не удалось сохранить настройки:", err)
	}
}

func newInviteCode() string {
	words := []string{"SNOW", "FROST", "ICE", "WINTER", "STORM", "POLAR", "YETI", "AURORA"}
	return words[randInt(len(words))] + "-" + randomString(4, "0123456789")
}

func randInt(n int) int {
	v, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(v.Int64())
}

func randomString(n int, alphabet string) string {
	var sb strings.Builder
	for i := 0; i < n; i++ {
		sb.WriteByte(alphabet[randInt(len(alphabet))])
	}
	return sb.String()
}
