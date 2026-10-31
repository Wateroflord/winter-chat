//go:build windows

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

// setupConsole включает UTF-8 в окне консоли, чтобы русский текст не превращался в кракозябры.
func setupConsole() {
	k := syscall.NewLazyDLL("kernel32.dll")
	_, _, _ = k.NewProc("SetConsoleOutputCP").Call(65001)
	_, _, _ = k.NewProc("SetConsoleCP").Call(65001)
	_, _, _ = k.NewProc("SetConsoleTitleW").Call(uintptrFromString("Winter Chat Server"))
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

// pauseOnWindows не даёт окну мгновенно закрыться, чтобы было видно ошибку.
func pauseOnWindows() {
	fmt.Println()
	fmt.Println("Нажми Enter, чтобы закрыть окно.")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}
