//go:build !linux && !darwin

package streaming

func lowerProcessPriority(int) {}
