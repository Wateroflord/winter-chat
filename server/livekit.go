package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/security"
)

// LiveKit запускает livekit-server рядом с сервером и следит за ним.
type LiveKit struct {
	app core.App

	mu       sync.Mutex
	cmd      *exec.Cmd
	stopped  bool
	running  bool
	lastErr  string
	binPath  string
	publicIP string
}

func newLiveKit(app core.App) *LiveKit { return &LiveKit{app: app} }

func (lk *LiveKit) Status() (running bool, lastErr, bin, publicIP string) {
	lk.mu.Lock()
	defer lk.mu.Unlock()
	return lk.running, lk.lastErr, lk.binPath, lk.publicIP
}

func findLiveKitBinary() string {
	name := "livekit-server"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	for _, p := range []string{
		filepath.Join(baseDir, name),
		filepath.Join(baseDir, "livekit", name),
		filepath.Join(baseDir, "bin", name),
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	return ""
}

func (lk *LiveKit) setErr(msg string) {
	lk.mu.Lock()
	lk.lastErr = msg
	lk.mu.Unlock()
}

// Run работает, пока сервер не остановят: при падении LiveKit перезапускается.
func (lk *LiveKit) Run() {
	bin := findLiveKitBinary()
	lk.mu.Lock()
	lk.binPath = bin
	lk.mu.Unlock()
	if bin == "" {
		lk.setErr("Не найден livekit-server рядом с программой — звонки не будут работать. Скачай полный архив сервера из Releases.")
		return
	}

	ip := detectPublicIP()
	lk.mu.Lock()
	lk.publicIP = ip
	lk.mu.Unlock()

	go lk.syncCallsLoop()

	backoff := 2 * time.Second
	for {
		lk.mu.Lock()
		if lk.stopped {
			lk.mu.Unlock()
			return
		}
		lk.mu.Unlock()

		confPath := filepath.Join(dataDir, "livekit.yaml")
		if err := os.WriteFile(confPath, []byte(liveKitConfig(ip)), 0o600); err != nil {
			lk.setErr("Не удалось записать livekit.yaml: " + err.Error())
			return
		}
		logFile, _ := os.Create(filepath.Join(dataDir, "livekit.log"))

		cmd := exec.Command(bin, "--config", confPath)
		cmd.Dir = dataDir
		if logFile != nil {
			cmd.Stdout = logFile
			cmd.Stderr = logFile
		}
		hideWindow(cmd)
		started := time.Now()
		if err := cmd.Start(); err != nil {
			lk.setErr("Не удалось запустить livekit-server: " + err.Error())
			if logFile != nil {
				logFile.Close()
			}
			time.Sleep(10 * time.Second)
			continue
		}
		lk.mu.Lock()
		lk.cmd = cmd
		lk.running = true
		lk.lastErr = ""
		lk.mu.Unlock()

		err := cmd.Wait()
		if logFile != nil {
			logFile.Close()
		}

		lk.mu.Lock()
		lk.running = false
		lk.cmd = nil
		stopped := lk.stopped
		lk.mu.Unlock()
		if stopped {
			return
		}

		tail := readTail(filepath.Join(dataDir, "livekit.log"), 600)
		lk.setErr(fmt.Sprintf("livekit-server остановился (%v). %s", err, tail))
		clearCalls(lk.app)

		if time.Since(started) > time.Minute {
			backoff = 2 * time.Second
		} else if backoff < 30*time.Second {
			backoff *= 2
		}
		time.Sleep(backoff)
	}
}

func (lk *LiveKit) Stop() {
	lk.mu.Lock()
	lk.stopped = true
	cmd := lk.cmd
	lk.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

func liveKitConfig(publicIP string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "port: %d\n", LKPort)
	b.WriteString("bind_addresses:\n  - 127.0.0.1\n")
	b.WriteString("rtc:\n")
	fmt.Fprintf(&b, "  tcp_port: %d\n", RTCTCPPort)
	fmt.Fprintf(&b, "  udp_port: %d\n", RTCUDPPort)
	b.WriteString("  use_external_ip: false\n")
	if publicIP != "" {
		fmt.Fprintf(&b, "  node_ip: %s\n", publicIP)
		b.WriteString("  advertise_internal_ip: true\n")
	}
	b.WriteString("keys:\n")
	fmt.Fprintf(&b, "  %s: %s\n", cfg.LKKey, cfg.LKSecret)
	b.WriteString("room:\n  auto_create: true\n  empty_timeout: 60\n  departure_timeout: 10\n")
	level := os.Getenv("WC_LK_LOG")
	if level == "" {
		level = "warn"
	}
	fmt.Fprintf(&b, "logging:\n  level: %s\n", level)
	return b.String()
}

func readTail(path string, n int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	if len(b) > n {
		b = b[len(b)-n:]
	}
	return strings.TrimSpace(string(b))
}

func detectPublicIP() string {
	client := &http.Client{Timeout: 6 * time.Second}
	for _, u := range []string{"https://api.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"} {
		resp, err := client.Get(u)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64))
		resp.Body.Close()
		ip := strings.TrimSpace(string(body))
		if resp.StatusCode == 200 && isIPv4(ip) {
			return ip
		}
	}
	return ""
}

// ---------- токены ----------

func liveKitToken(identity, name string, video map[string]any, ttl time.Duration) (string, error) {
	claims := jwt.MapClaims{
		"iss":   cfg.LKKey,
		"sub":   identity,
		"nbf":   time.Now().Add(-30 * time.Second).Unix(),
		"video": video,
	}
	if name != "" {
		claims["name"] = name
	}
	return security.NewJWT(claims, cfg.LKSecret, ttl)
}

func userCallToken(user *core.Record, room string) (string, error) {
	name := strings.TrimSpace(user.GetString("name"))
	if name == "" {
		name = user.GetString("username")
	}
	return liveKitToken(user.Id, name, map[string]any{
		"room":           room,
		"roomJoin":       true,
		"canPublish":     true,
		"canSubscribe":   true,
		"canPublishData": true,
	}, 12*time.Hour)
}

// ---------- кто сейчас в звонке ----------

func twirp(method string, room string, body any, out any) error {
	tok, err := liveKitToken("winter-chat-server", "", map[string]any{
		"roomList":  true,
		"roomAdmin": true,
		"room":      room,
	}, 5*time.Minute)
	if err != nil {
		return err
	}
	data, _ := json.Marshal(body)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("http://127.0.0.1:%d/twirp/livekit.RoomService/%s", LKPort, method), bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: %d %s", method, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return json.Unmarshal(raw, out)
}

func (lk *LiveKit) syncCallsLoop() {
	for {
		lk.mu.Lock()
		stopped, running := lk.stopped, lk.running
		lk.mu.Unlock()
		if stopped {
			return
		}
		if running {
			lk.syncCalls()
		}
		time.Sleep(2 * time.Second)
	}
}

func (lk *LiveKit) syncCalls() {
	var rooms struct {
		Rooms []struct {
			Name string `json:"name"`
		} `json:"rooms"`
	}
	if err := twirp("ListRooms", "", map[string]any{}, &rooms); err != nil {
		return
	}
	active := map[string][]string{}
	for _, r := range rooms.Rooms {
		var parts struct {
			Participants []struct {
				Identity string `json:"identity"`
			} `json:"participants"`
		}
		if err := twirp("ListParticipants", r.Name, map[string]any{"room": r.Name}, &parts); err != nil {
			continue
		}
		var ids []string
		for _, p := range parts.Participants {
			if p.Identity != "" {
				ids = append(ids, p.Identity)
			}
		}
		if len(ids) > 0 {
			sort.Strings(ids)
			active[r.Name] = ids
		}
	}

	app := lk.app
	existing, err := app.FindAllRecords("calls")
	if err != nil {
		return
	}
	seen := map[string]bool{}
	for _, rec := range existing {
		chat := rec.GetString("chat")
		ids, ok := active[chat]
		if !ok {
			_ = app.Delete(rec)
			continue
		}
		seen[chat] = true
		cur := rec.GetStringSlice("participants")
		sort.Strings(cur)
		if strings.Join(cur, ",") != strings.Join(ids, ",") {
			rec.Set("participants", ids)
			_ = app.Save(rec)
		}
	}
	col, err := app.FindCollectionByNameOrId("calls")
	if err != nil {
		return
	}
	for chat, ids := range active {
		if seen[chat] {
			continue
		}
		if _, err := app.FindRecordById("chats", chat); err != nil {
			continue
		}
		if r, _ := app.FindFirstRecordByFilter("calls", "chat = {:c}", dbx.Params{"c": chat}); r != nil {
			continue
		}
		rec := core.NewRecord(col)
		rec.Set("chat", chat)
		rec.Set("participants", ids)
		_ = app.Save(rec)
	}
}
