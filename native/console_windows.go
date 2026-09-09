//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"unsafe"
)

var (
	kernel32                       = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleScreenBufferInfo = kernel32.NewProc("GetConsoleScreenBufferInfo")
)

type coord struct{ X, Y int16 }
type smallRect struct{ Left, Top, Right, Bottom int16 }
type consoleScreenBufferInfo struct {
	Size              coord
	CursorPosition    coord
	Attributes        uint16
	Window            smallRect
	MaximumWindowSize coord
}

// terminalWidth is [Console]::WindowWidth, with the same fallback the PowerShell used
// (`try { [Console]::WindowWidth } catch { 160 }`). The width sets the verse wrap
// point, so getting it wrong reflows every verse line.
//
// It probes the STD_OUTPUT handle, NOT CONOUT$, because that is what .NET Framework's
// Console.WindowWidth does: GetConsoleScreenBufferInfo on GetStdHandle(STD_OUTPUT).
// Under the harness stdout is a pipe, so the call fails, .NET throws "The handle is
// invalid", the catch fires and the width is 160 -- which is the value the verses have
// always actually wrapped against. Reading CONOUT$ instead finds the real console (112
// here) and rewraps every verse line: measured, and the only diff in the first A/B run.
const fallbackTerminalWidth = 160

func terminalWidth() int {
	var info consoleScreenBufferInfo
	r, _, _ := procGetConsoleScreenBufferInfo.Call(
		uintptr(syscall.Stdout), uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		return fallbackTerminalWidth
	}
	w := int(info.Window.Right - info.Window.Left + 1)
	if w <= 0 {
		return fallbackTerminalWidth
	}
	return w
}

// spawnDetachedRefresh launches this same binary in -refresh-only mode, fully
// detached, and returns immediately. The render path never waits on it.
//
// DETACHED_PROCESS, not the PowerShell version's hidden window: a hidden console is
// still a console, so `Start-Process -WindowStyle Hidden` allocated a conhost.exe for
// every refresh. Detaching allocates none, which removes one process per refresh on
// top of removing the powershell.exe itself.
const detachedProcess = 0x00000008

func spawnDetachedRefresh() {
	self, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(self, "-refresh-only")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: detachedProcess,
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if cmd.Start() == nil {
		// Release the handle so this render's exit does not wait on the child.
		_ = cmd.Process.Release()
	}
}
