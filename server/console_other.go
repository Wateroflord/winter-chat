//go:build !windows

package main

import "os/exec"

func setupConsole()            {}
func hideWindow(cmd *exec.Cmd) {}
func pauseOnWindows()          {}
