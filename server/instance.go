package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Запуск в один клик: повторный запуск программы не ломает уже работающий сервер,
// а просто открывает панель. «--stop» выключает работающий сервер (ярлык «Выключить сервер»).

// background — сервер работает без окна (ярлык, автозапуск, запуск из Winter Hub).
var background bool

func panelURL() string { return fmt.Sprintf("http://localhost:%d", HTTPPort) }

// serverRunning — на этом компьютере уже работает Winter Chat Server.
func serverRunning() bool {
	c := &http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/api/wc/info", HTTPPort))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var info struct {
		App string `json:"app"`
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode == http.StatusOK && json.Unmarshal(body, &info) == nil && info.App == "winter-chat"
}

// stopRunningServer выключает работающий сервер и ждёт, пока он закроется. Код выхода программы.
func stopRunningServer() int {
	if !serverRunning() {
		fmt.Println("Сервер не запущен.")
		return 0
	}
	c := &http.Client{Timeout: 5 * time.Second}
	resp, err := c.Post(fmt.Sprintf("http://127.0.0.1:%d/api/wc/panel/stop", HTTPPort), "application/json", strings.NewReader("{}"))
	if err != nil {
		fmt.Println("Не удалось выключить сервер:", err)
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Println("Сервер не дал себя выключить: код", resp.StatusCode)
		return 1
	}
	for i := 0; i < 40; i++ {
		time.Sleep(250 * time.Millisecond)
		if !serverRunning() {
			// Дать livekit-server и базе спокойно закрыться (важно перед обновлением).
			time.Sleep(time.Second)
			fmt.Println("Сервер выключен.")
			return 0
		}
	}
	fmt.Println("Сервер не выключился за 10 секунд.")
	return 1
}

// startBackgroundMode: всё, что сервер пишет, — в файл winter-chat-data/server.log, окно консоли прячется.
func startBackgroundMode() {
	logPath := filepath.Join(dataDir, "server.log")
	_ = os.Rename(logPath, filepath.Join(dataDir, "server.old.log"))
	if f, err := os.Create(logPath); err == nil {
		os.Stdout = f
		os.Stderr = f
		log.SetOutput(f)
	}
	detachConsole()
}

// failAndWait показывает ошибку запуска: в окне — ждёт Enter, без окна — показывает сообщение Windows.
func failAndWait(err error) {
	msg := err.Error()
	low := strings.ToLower(msg)
	if strings.Contains(low, "address already in use") || strings.Contains(low, "only one usage of each socket address") || strings.Contains(low, "bind:") {
		msg = fmt.Sprintf("Порт %d занят другой программой, поэтому сервер не запустился.\n\nЗакрой программу, которая его заняла (или перезагрузи компьютер), и запусти Winter Chat Server снова.\n\n(%s)", HTTPPort, err.Error())
	}
	log.Println("Ошибка:", msg)
	if background {
		showErrorBox("Winter Chat Server", "Сервер не запустился.\n\n"+msg)
		return
	}
	pauseOnWindows()
}
