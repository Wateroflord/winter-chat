//go:build !windows

package main

import "os/exec"

func setupConsole()                  {}
func hideWindow(cmd *exec.Cmd)       {}
func pauseOnWindows()                {}
func noConsole() bool                { return false }
func detachConsole()                 {}
func showErrorBox(title, msg string) {}
