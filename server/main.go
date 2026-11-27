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
	"time"

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
	ArcStart      string `json:"arcStart"`  // первый день Winter Arc (ГГГГ-ММ-ДД)
	BackupDir     string `json:"backupDir"` // куда ещё класть автокопии (флешка, облачный диск)
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

	noBrowser, stop := false, false
	var rest []string
	for _, a := range os.Args[1:] {
		switch a {
		case "--no-browser":
			noBrowser = true
		case "--background": // без чёрного окна: ярлык, автозапуск
			background = true
		case "--stop": // выключить уже работающий сервер
			stop = true
		default:
			rest = append(rest, a)
		}
	}
	if stop {
		os.Exit(stopRunningServer())
	}
	// Сервер уже работает (например, из автозапуска) — просто открываем панель.
	if len(rest) == 0 && serverRunning() {
		fmt.Println("Сервер уже работает — открываю панель", panelURL())
		if !noBrowser {
			openBrowser(panelURL())
		}
		return
	}
	// Запустили без окна (кнопка «Открыть» в Winter Hub) — тоже фоновый режим.
	if !background && noConsole() {
		background = true
	}
	if background {
		startBackgroundMode()
	}
	loadOrCreateConfig()

	// Двойной клик по программе = запуск сервера.
	if len(rest) == 0 {
		// --origins: браузерным страницам с чужих сайтов запрещено читать ответы сервера
		// (приложения Winter Chat — не браузер, их это не касается).
		rest = []string{"serve", fmt.Sprintf("--http=0.0.0.0:%d", HTTPPort),
			fmt.Sprintf("--origins=http://localhost:%d,http://127.0.0.1:%d", HTTPPort, HTTPPort)}
	}
	os.Args = append([]string{os.Args[0]}, rest...)

	app := pocketbase.NewWithConfig(pocketbase.Config{
		DefaultDataDir:  filepath.Join(dataDir, "pb_data"),
		HideStartBanner: true,
	})

	registerHooks(app)
	registerArcHooks(app)
	registerGamesHooks(app)
	registerSocialHooks(app)
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
		if err := ensureArcSchema(se.App); err != nil {
			return fmt.Errorf("подготовка Winter Arc: %w", err)
		}
		if err := ensureGamesSchema(se.App); err != nil {
			return fmt.Errorf("подготовка игр: %w", err)
		}
		if err := ensureSocialSchema(se.App); err != nil {
			return fmt.Errorf("подготовка реакций и закрепов: %w", err)
		}
		if err := ensureSuperuser(se.App); err != nil {
			return fmt.Errorf("создание администратора: %w", err)
		}
		if err := ensureRateLimits(se.App); err != nil {
			return fmt.Errorf("настройка защиты от перебора: %w", err)
		}
		clearCalls(se.App)
		cleanupGames(se.App)
		se.App.Cron().MustAdd("winter-games-cleanup", "*/10 * * * *", func() { cleanupGames(se.App) })
		// Автокопия базы раз в сутки (проверка каждый час — ноутбук ночью может быть выключен).
		se.App.Cron().MustAdd("winter-backup", "23 * * * *", func() { autoBackupIfDue(se.App) })
		go func() {
			time.Sleep(2 * time.Minute)
			autoBackupIfDue(se.App)
		}()

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
		lk.Stop()
		failAndWait(err)
		os.Exit(1)
	}
}

// shutdownServer — кнопка «Выключить сервер» в панели (и ярлык «Выключить»).
func shutdownServer(app core.App) {
	log.Println("Сервер выключается по команде из панели.")
	if theLiveKit != nil {
		theLiveKit.Stop()
	}
	_ = app.ResetBootstrapState() // закрыть базу
	os.Exit(0)
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
	// Старые коды вида SNOW-1234 (80 000 вариантов) легко подобрать — меняем на длинный.
	if len(cfg.InviteCode) < 14 {
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
	// Winter Arc начинается в день первого запуска сервера с рейтингом.
	if _, err := time.Parse(dayLayout, cfg.ArcStart); err != nil {
		cfg.ArcStart = today()
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

// newInviteCode — например SNOW-7K3P-9QXA: слово + 8 случайных знаков (~9 триллионов вариантов).
func newInviteCode() string {
	words := []string{"SNOW", "FROST", "ICE", "WINTER", "STORM", "POLAR", "YETI", "AURORA"}
	const abc = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	return words[randInt(len(words))] + "-" + randomString(4, abc) + "-" + randomString(4, abc)
}

// ensureRateLimits включает встроенное в PocketBase ограничение частоты запросов:
// перебор пароля или кода приглашения через интернет становится бесполезным.
func ensureRateLimits(app core.App) error {
	s := app.Settings()
	rules := []core.RateLimitRule{
		{Label: "users:create", Audience: core.RateLimitRuleAudienceGuest, MaxRequests: 5, Duration: 60},
		{Label: "*:auth", MaxRequests: 2, Duration: 3},
		{Label: "*:create", MaxRequests: 20, Duration: 5},
		{Label: "/api/batch", MaxRequests: 3, Duration: 1},
		{Label: "/api/", MaxRequests: 600, Duration: 10},
	}
	same := s.RateLimits.Enabled && len(s.RateLimits.Rules) == len(rules)
	for i := 0; same && i < len(rules); i++ {
		same = s.RateLimits.Rules[i] == rules[i]
	}
	if same {
		return nil
	}
	s.RateLimits.Enabled = true
	s.RateLimits.Rules = rules
	return app.Save(s)
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
