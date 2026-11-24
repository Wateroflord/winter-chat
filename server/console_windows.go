//go:build windows

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
)

// setupConsole включает UTF-8 в окне консоли, чтобы русский текст не превращался в кракозябры.
func setupConsole() {
	_, _, _ = kernel32.NewProc("SetConsoleOutputCP").Call(65001)
	_, _, _ = kernel32.NewProc("SetConsoleCP").Call(65001)
	_, _, _ = kernel32.NewProc("SetConsoleTitleW").Call(uintptrFromString("Winter Chat Server"))
}

func uintptrFromString(s string) uintptr {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		return 0
	}
	return uintptrOf(p)
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

// noConsole — программу запустили без окна консоли (например, Winter Hub кнопкой «Открыть»).
func noConsole() bool {
	h, _, _ := kernel32.NewProc("GetConsoleWindow").Call()
	return h == 0
}

// detachConsole убирает чёрное окно: если окно только наше — прячем его,
// если сервер запустили из уже открытой командной строки — просто отцепляемся от неё.
func detachConsole() {
	h, _, _ := kernel32.NewProc("GetConsoleWindow").Call()
	if h == 0 {
		return
	}
	var ids [4]uint32
	n, _, _ := kernel32.NewProc("GetConsoleProcessList").Call(uintptr(unsafe.Pointer(&ids[0])), uintptr(len(ids)))
	if n == 1 {
		_, _, _ = user32.NewProc("ShowWindow").Call(h, 0) // SW_HIDE
		return
	}
	_, _, _ = kernel32.NewProc("FreeConsole").Call()
}

// showErrorBox — окошко Windows с ошибкой (когда консоли не видно).
func showErrorBox(title, msg string) {
	const mbIconError, mbSetForeground = 0x10, 0x10000
	_, _, _ = user32.NewProc("MessageBoxW").Call(0, uintptrFromString(msg), uintptrFromString(title), mbIconError|mbSetForeground)
}

// pauseOnWindows не даёт окну мгновенно закрыться, чтобы было видно ошибку.
func pauseOnWindows() {
	fmt.Println()
	fmt.Println("Нажми Enter, чтобы закрыть окно.")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}
