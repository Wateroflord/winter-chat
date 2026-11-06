package main

import (
	_ "embed"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

//go:embed panel.html
var panelHTML string

var theLiveKit *LiveKit

func registerRoutes(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		r := se.Router

		// Проверка адреса сервера из приложения.
		r.GET("/api/wc/info", func(e *core.RequestEvent) error {
			running := false
			if theLiveKit != nil {
				running, _, _, _ = theLiveKit.Status()
			}
			return e.JSON(http.StatusOK, map[string]any{
				"app":     "winter-chat",
				"version": Version,
				"calls":   running,
				"arc":     arcInfo(),
			})
		})

		// Токен для входа в звонок чата.
		r.POST("/api/wc/call-token", func(e *core.RequestEvent) error {
			var body struct {
				Chat string `json:"chat"`
			}
			if err := e.BindBody(&body); err != nil || body.Chat == "" {
				return e.BadRequestError("Не указан чат", nil)
			}
			chat, err := e.App.FindRecordById("chats", body.Chat)
			if err != nil || !contains(chat.GetStringSlice("members"), e.Auth.Id) {
				return e.ForbiddenError("Ты не участник этого чата", nil)
			}
			if theLiveKit != nil {
				if running, lastErr, _, _ := theLiveKit.Status(); !running {
					msg := "Звонки на сервере сейчас не работают"
					if lastErr != "" {
						msg += ": " + lastErr
					}
					return e.Error(http.StatusServiceUnavailable, msg, nil)
				}
			}
			tok, err := userCallToken(e.Auth, chat.Id)
			if err != nil {
				return e.InternalServerError("Не удалось выдать токен", err)
			}
			return e.JSON(http.StatusOK, map[string]any{"token": tok, "path": "/lk"})
		}).Bind(apis.RequireAuth("users"))

		// LiveKit наружу идёт через этот же порт: /lk/rtc -> 127.0.0.1:7880/rtc
		target, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", LKPort))
		proxy := httputil.NewSingleHostReverseProxy(target)
		baseDirector := proxy.Director
		proxy.Director = func(req *http.Request) {
			baseDirector(req)
			req.URL.Path = strings.TrimPrefix(req.URL.Path, "/lk")
			if req.URL.Path == "" {
				req.URL.Path = "/"
			}
			req.URL.RawPath = ""
			req.Host = target.Host
		}
		proxy.FlushInterval = -1
		proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Звонки на сервере сейчас не работают", http.StatusBadGateway)
		}
		r.Any("/lk/{path...}", func(e *core.RequestEvent) error {
			proxy.ServeHTTP(e.Response, e.Request)
			return nil
		})

		// Панель управления — только на самом компьютере-сервере.
		r.GET("/{$}", func(e *core.RequestEvent) error {
			if !isLocalRequest(e.Request) {
				return e.String(http.StatusOK, "Winter Chat server работает.")
			}
			return e.HTML(http.StatusOK, panelHTML)
		})
		r.GET("/api/wc/panel", func(e *core.RequestEvent) error {
			if !isLocalRequest(e.Request) {
				return e.ForbiddenError("", nil)
			}
			return e.JSON(http.StatusOK, panelData(e.App))
		})
		// Начать Winter Arc заново с сегодняшнего дня (старые очки остаются, но в рейтинг не идут).
		r.POST("/api/wc/panel/arc-restart", func(e *core.RequestEvent) error {
			if !isLocalRequest(e.Request) {
				return e.ForbiddenError("", nil)
			}
			cfg.ArcStart = today()
			saveConfig()
			return e.JSON(http.StatusOK, arcInfo())
		})
		r.POST("/api/wc/panel/invite", func(e *core.RequestEvent) error {
			if !isLocalRequest(e.Request) {
				return e.ForbiddenError("", nil)
			}
			cfg.InviteCode = newInviteCode()
			saveConfig()
			return e.JSON(http.StatusOK, map[string]any{"invite": cfg.InviteCode})
		})
		r.POST("/api/wc/panel/password", func(e *core.RequestEvent) error {
			if !isLocalRequest(e.Request) {
				return e.ForbiddenError("", nil)
			}
			var body struct {
				ID       string `json:"id"`
				Password string `json:"password"`
			}
			if err := e.BindBody(&body); err != nil || len(body.Password) < 8 {
				return e.BadRequestError("Пароль — минимум 8 символов", nil)
			}
			u, err := e.App.FindRecordById("users", body.ID)
			if err != nil {
				return e.NotFoundError("Нет такого пользователя", nil)
			}
			u.SetPassword(body.Password)
			if err := e.App.Save(u); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
			return e.JSON(http.StatusOK, map[string]any{"ok": true})
		})
		return se.Next()
	})
}

// isLocalRequest — запрос к панели пришёл с этого же компьютера и не от чужого сайта.
//
// Проверяем: адрес — этот компьютер; запрос не прошёл через туннель/прокси
// (ngrok, cloudflared и т.п. подключаются с 127.0.0.1, но добавляют свои заголовки);
// Host — localhost (защита от DNS rebinding); браузер не сообщает, что запрос
// пришёл со стороннего сайта (защита от подделки запросов).
func isLocalRequest(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return false
	}
	for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Host", "Forwarded", "X-Real-Ip", "Cf-Connecting-Ip", "True-Client-Ip", "Ngrok-Agent-Ips"} {
		if r.Header.Get(h) != "" {
			return false
		}
	}
	if !isLocalHost(r.Host) {
		return false
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		return false
	}
	if o := r.Header.Get("Origin"); o != "" {
		u, err := url.Parse(o)
		if err != nil || !isLocalHost(u.Host) {
			return false
		}
	}
	return true
}

func isLocalHost(hostport string) bool {
	h := hostport
	if hh, _, err := net.SplitHostPort(hostport); err == nil {
		h = hh
	}
	h = strings.Trim(strings.ToLower(h), "[]")
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

func panelData(app core.App) map[string]any {
	running, lastErr, bin, publicIP := false, "", "", ""
	if theLiveKit != nil {
		running, lastErr, bin, publicIP = theLiveKit.Status()
	}
	type u struct {
		ID       string `json:"id"`
		Username string `json:"username"`
		Name     string `json:"name"`
		Created  string `json:"created"`
	}
	var users []u
	if recs, err := app.FindRecordsByFilter("users", "", "-created", 500, 0); err == nil {
		for _, r := range recs {
			users = append(users, u{r.Id, r.GetString("username"), r.GetString("name"), r.GetDateTime("created").String()})
		}
	}
	chats, _ := app.CountRecords("chats")
	msgs, _ := app.CountRecords("messages")
	return map[string]any{
		"version":       Version,
		"port":          HTTPPort,
		"lan":           lanIPs(),
		"publicIP":      publicIP,
		"invite":        cfg.InviteCode,
		"arc":           arcInfo(),
		"adminEmail":    cfg.AdminEmail,
		"adminPassword": cfg.AdminPassword,
		"calls":         running,
		"callsError":    lastErr,
		"livekitBin":    bin,
		"users":         users,
		"chats":         chats,
		"messages":      msgs,
		"dataDir":       dataDir,
		"ports": []map[string]any{
			{"port": HTTPPort, "proto": "TCP", "what": "приложение, чаты, файлы"},
			{"port": RTCTCPPort, "proto": "TCP", "what": "звонки (запасной путь)"},
			{"port": RTCUDPPort, "proto": "UDP", "what": "звонки"},
		},
	}
}

func isIPv4(s string) bool {
	ip := net.ParseIP(s)
	return ip != nil && ip.To4() != nil
}

// lanIPs — адреса этого компьютера в домашней сети (и в VPN вроде Tailscale/ZeroTier/Radmin).
func lanIPs() []map[string]string {
	var out []map[string]string
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipn.IP.To4()
			if ip == nil || ip.IsLinkLocalUnicast() {
				continue
			}
			kind := "сеть"
			lname := strings.ToLower(ifc.Name)
			switch {
			case strings.Contains(lname, "tailscale") || (ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127):
				kind = "Tailscale"
			case strings.Contains(lname, "zt") || strings.Contains(lname, "zerotier"):
				kind = "ZeroTier"
			case ip[0] == 26:
				kind = "Radmin VPN"
			case ip.IsPrivate():
				kind = "домашняя сеть"
			}
			out = append(out, map[string]string{"ip": ip.String(), "iface": ifc.Name, "kind": kind})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i]["kind"] == "домашняя сеть" && out[j]["kind"] != "домашняя сеть"
	})
	return out
}

func printBanner(noBrowser bool) {
	time.Sleep(4 * time.Second) // ждём, пока определится внешний IP
	_, lastErr, bin, publicIP := false, "", "", ""
	if theLiveKit != nil {
		_, lastErr, bin, publicIP = theLiveKit.Status()
	}
	line := strings.Repeat("=", 60)
	fmt.Println()
	fmt.Println(line)
	fmt.Println("  WINTER CHAT SERVER", Version, "— работает")
	fmt.Println(line)
	fmt.Printf("  Панель управления:  http://localhost:%d\n", HTTPPort)
	fmt.Println()
	fmt.Println("  Адрес сервера для приложения:")
	for _, ip := range lanIPs() {
		fmt.Printf("    %-15s %s:%d\n", ip["kind"]+":", ip["ip"], HTTPPort)
	}
	if publicIP != "" {
		fmt.Printf("    %-15s %s:%d  (нужно открыть порты на роутере)\n", "интернет:", publicIP, HTTPPort)
	}
	fmt.Println()
	fmt.Println("  Код приглашения для регистрации:", cfg.InviteCode)
	if bin == "" || lastErr != "" {
		fmt.Println()
		fmt.Println("  ВНИМАНИЕ (звонки):", firstNonEmpty(lastErr, "livekit-server не найден"))
	}
	fmt.Println()
	fmt.Println("  Не закрывай это окно — иначе сервер выключится.")
	fmt.Println(line)
	fmt.Println()
	if !noBrowser {
		openBrowser(fmt.Sprintf("http://localhost:%d", HTTPPort))
	}
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

func openBrowser(u string) {
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", u).Start()
	case "darwin":
		_ = exec.Command("open", u).Start()
	default:
		if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
			return
		}
		_ = exec.Command("xdg-open", u).Start()
	}
}
