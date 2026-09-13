//go:build linux || darwin

package streaming

import "syscall"

// lowerProcessPriority niceness-shifts a background extraction, so it only
// ever runs on CPU the rest of the server is not using.
func lowerProcessPriority(pid int) {
	_ = syscall.Setpriority(syscall.PRIO_PROCESS, pid, 15)
}
