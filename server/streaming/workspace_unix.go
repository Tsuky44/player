//go:build !windows

package streaming

import "syscall"

// freeBytes est l'espace disponible, pour un utilisateur ordinaire, sur le
// système de fichiers qui porte path.
func freeBytes(path string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}
