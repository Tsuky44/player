package config

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strings"

	"project-player/server/database"
)

const (
	KeyServerID   = "server_id"
	KeyServerName = "server_name"
)

// ServerID is this server's stable identity, generated on first use.
//
// Linked servers (ADR-0017) recognise each other by it rather than by address:
// the same server is reachable through a local IP one day and a domain name the
// next, and must not become a second peer because of it.
func ServerID() string {
	if database.DB == nil {
		return ""
	}
	var stored string
	err := database.DB.QueryRow(`SELECT value FROM app_settings WHERE key = ?`, KeyServerID).Scan(&stored)
	if err == nil && strings.TrimSpace(stored) != "" {
		return stored
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return ""
	}
	if _, err := database.DB.Exec(`
		INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(key) DO NOTHING`, KeyServerID, hex.EncodeToString(buf)); err != nil {
		return ""
	}
	// A concurrent caller may have won the insert; the stored row is the truth.
	if err := database.DB.QueryRow(`SELECT value FROM app_settings WHERE key = ?`, KeyServerID).Scan(&stored); err != nil {
		return ""
	}
	return stored
}

// ServerName is what linked servers and their administrators see.
func ServerName() string {
	if v, ok := getStored(KeyServerName); ok {
		return v
	}
	if host, err := os.Hostname(); err == nil && host != "" {
		return host
	}
	return "Onyx"
}
