package handlers

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"project-player/server/database"

	"github.com/julienschmidt/httprouter"
)

// Appareils connectés.
//
// Une session est un appareil : chaque téléphone, téléviseur ou navigateur
// ouvre la sienne, et la fermer déconnecte cet appareil-là sans toucher aux
// autres. Ce fichier donne un visage à ces sessions — le nom que l'appareil
// annonce, son application, sa dernière activité — et permet de les révoquer.
//
// Le nom et l'application arrivent par en-têtes sur chaque requête
// authentifiée. Ils ne sont écrits en base que lorsqu'ils changent, ce qui
// n'arrive presque jamais : le chemin chaud ne paie qu'une lecture de map.
// La dernière activité et l'adresse, elles, restent en mémoire : les écrire à
// chaque requête mettrait une écriture SQLite derrière chaque affiche chargée.

const (
	headerDevice = "X-Onyx-Device"
	headerClient = "X-Onyx-Client"
	// Assez pour « Chambre de Léa · Android TV 1.4.2 », pas pour stocker un roman.
	maxClientLabel = 80
)

type sessionClient struct {
	device   string
	client   string
	lastSeen time.Time
	address  string
}

var sessionClients = struct {
	sync.Mutex
	byToken map[[32]byte]*sessionClient
}{byToken: make(map[[32]byte]*sessionClient)}

func sessionKey(token string) [32]byte { return sha256.Sum256([]byte(token)) }

// sessionKeyFromDigest is sessionKey for a session read back from the table,
// which only holds the token's digest (database.SessionTokenDigest) — the same
// SHA-256, in hexadecimal.
func sessionKeyFromDigest(digest string) [32]byte {
	var key [32]byte
	_, _ = hex.Decode(key[:], []byte(digest))
	return key
}

// headerLabel reads a label header. Clients percent-encode it, because a device
// called « Téléviseur du salon » is not valid in a raw HTTP header.
func headerLabel(r *http.Request, name string) string {
	raw := r.Header.Get(name)
	if decoded, err := url.PathUnescape(raw); err == nil {
		raw = decoded
	}
	return cleanClientLabel(raw)
}

func cleanClientLabel(raw string) string {
	label := strings.TrimSpace(raw)
	label = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, label)
	if len([]rune(label)) > maxClientLabel {
		label = string([]rune(label)[:maxClientLabel])
	}
	return label
}

// clientAddress is the caller's IP, honouring a reverse proxy in front.
func clientAddress(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		return strings.TrimSpace(strings.Split(forwarded, ",")[0])
	}
	if real := r.Header.Get("X-Real-IP"); real != "" {
		return strings.TrimSpace(real)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// isLocalAddress tells a device in the house from one reaching in over the
// internet — the first thing an administrator wants to know about a stranger.
func isLocalAddress(address string) bool {
	ip := net.ParseIP(address)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// noteSessionClient records who is behind a valid token. Called by RequireAuth
// after the session has been accepted.
func noteSessionClient(token string, r *http.Request) {
	device := headerLabel(r, headerDevice)
	client := headerLabel(r, headerClient)
	key := sessionKey(token)
	now := time.Now()

	sessionClients.Lock()
	entry, known := sessionClients.byToken[key]
	if !known {
		entry = &sessionClient{}
		sessionClients.byToken[key] = entry
	}
	entry.lastSeen = now
	entry.address = clientAddress(r)
	changed := (device != "" && device != entry.device) || (client != "" && client != entry.client) || !known
	if device != "" {
		entry.device = device
	}
	if client != "" {
		entry.client = client
	}
	sessionClients.Unlock()

	// After a restart the map is empty, so the first request of each session
	// writes once — even when nothing changed. That is one UPDATE per device
	// per restart, and it keeps the write path free of a read.
	if changed && (device != "" || client != "") {
		if _, err := database.DB.Exec(
			`UPDATE sessions SET
				device_name = CASE WHEN ? != '' THEN ? ELSE device_name END,
				client = CASE WHEN ? != '' THEN ? ELSE client END
			WHERE token = ?`,
			device, device, client, client, database.SessionTokenDigest(token),
		); err != nil {
			log.Printf("Devices: failed to record client of a session: %v", err)
		}
	}
}

func forgetSessionClient(key [32]byte) {
	sessionClients.Lock()
	delete(sessionClients.byToken, key)
	sessionClients.Unlock()
}

func sessionClientSnapshot(key [32]byte) (sessionClient, bool) {
	sessionClients.Lock()
	defer sessionClients.Unlock()
	entry, ok := sessionClients.byToken[key]
	if !ok {
		return sessionClient{}, false
	}
	return *entry, true
}

// bearerToken extracts the session token of an already-authenticated request.
func bearerToken(r *http.Request) string {
	parts := strings.Split(r.Header.Get("Authorization"), " ")
	if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
		return ""
	}
	return parts[1]
}

// Device is one signed-in session, as shown in the settings.
type Device struct {
	ID         int64     `json:"id"`
	UserID     int       `json:"user_id"`
	Username   string    `json:"username"`
	DeviceName string    `json:"device_name"`
	Client     string    `json:"client"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
	Address    string    `json:"address,omitempty"`
	IsLocal    bool      `json:"is_local"`
	IsCurrent  bool      `json:"is_current"`
	// NowPlaying is the title this device is playing right now, if any.
	NowPlaying string `json:"now_playing,omitempty"`
}

func parseSQLiteTime(raw string) time.Time {
	return scanSQLiteTime(sql.NullString{String: raw, Valid: raw != ""}).UTC()
}

// listDevices reads sessions, newest activity first. userID 0 means every user.
func listDevices(userID int, currentToken string) ([]Device, error) {
	query := `
		SELECT s.rowid, s.token, s.user_id, u.username, s.device_name, s.client,
		       COALESCE(CAST(s.created_at AS TEXT), ''), COALESCE(CAST(s.last_seen_at AS TEXT), '')
		FROM sessions s JOIN users u ON u.id = s.user_id
		WHERE COALESCE(s.last_seen_at, s.created_at) > datetime('now', ?)`
	args := []any{sqliteAge(sessionIdleTTL)}
	if userID > 0 {
		query += ` AND s.user_id = ?`
		args = append(args, userID)
	}
	rows, err := database.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	type row struct {
		device Device
		key    [32]byte
	}
	var collected []row
	for rows.Next() {
		var d Device
		var digest, created, seen string
		if err := rows.Scan(&d.ID, &digest, &d.UserID, &d.Username, &d.DeviceName, &d.Client, &created, &seen); err != nil {
			rows.Close()
			return nil, err
		}
		d.CreatedAt = parseSQLiteTime(created)
		d.LastSeenAt = parseSQLiteTime(seen)
		if d.LastSeenAt.IsZero() {
			d.LastSeenAt = d.CreatedAt
		}
		collected = append(collected, row{device: d, key: sessionKeyFromDigest(digest)})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	playing := playbackActivity.titlesBySession()
	currentKey := sessionKey(currentToken)
	devices := make([]Device, 0, len(collected))
	for _, item := range collected {
		d := item.device
		if live, ok := sessionClientSnapshot(item.key); ok {
			if live.lastSeen.After(d.LastSeenAt) {
				d.LastSeenAt = live.lastSeen.UTC()
			}
			d.Address = live.address
			d.IsLocal = isLocalAddress(live.address)
			if d.DeviceName == "" {
				d.DeviceName = live.device
			}
			if d.Client == "" {
				d.Client = live.client
			}
		}
		d.IsCurrent = currentToken != "" && item.key == currentKey
		d.NowPlaying = playing[item.key]
		devices = append(devices, d)
	}
	sort.SliceStable(devices, func(i, j int) bool {
		return devices[i].LastSeenAt.After(devices[j].LastSeenAt)
	})
	return devices, nil
}

// ListMyDevices returns the caller's own signed-in devices (GET /api/me/devices).
func ListMyDevices(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	devices, err := listDevices(userID, bearerToken(r))
	if err != nil {
		log.Printf("ListMyDevices: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(devices)
}

// ListAllDevices returns every signed-in device on the server
// (GET /api/admin/devices, manage_users).
func ListAllDevices(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	devices, err := listDevices(0, bearerToken(r))
	if err != nil {
		log.Printf("ListAllDevices: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(devices)
}

// revokeDevice deletes one session. Returns false when it does not exist or is
// not the caller's to revoke.
func revokeDevice(id int64, allowed func(ownerID int) bool) (bool, error) {
	var digest string
	var ownerID int
	err := database.DB.QueryRow(`SELECT token, user_id FROM sessions WHERE rowid = ?`, id).Scan(&digest, &ownerID)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !allowed(ownerID) {
		return false, nil
	}
	if _, err := database.DB.Exec(`DELETE FROM sessions WHERE rowid = ?`, id); err != nil {
		return false, err
	}
	forgetCachedSession(digest)
	key := sessionKeyFromDigest(digest)
	forgetSessionClient(key)
	playbackActivity.dropSession(key)
	return true, nil
}

// RevokeMyDevice signs one of the caller's devices out (DELETE /api/me/devices/:id).
func RevokeMyDevice(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, userID int) {
	id, err := strconv.ParseInt(ps.ByName("id"), 10, 64)
	if err != nil || id <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid device id")
		return
	}
	ok, err := revokeDevice(id, func(ownerID int) bool { return ownerID == userID })
	if err != nil {
		log.Printf("RevokeMyDevice: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if !ok {
		writeJSONError(w, http.StatusNotFound, "Device not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// RevokeAnyDevice signs any device out (DELETE /api/admin/devices/:id,
// manage_users). Like a password reset, it cannot reach the owner's devices
// unless the caller is the owner.
func RevokeAnyDevice(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, userID int) {
	id, err := strconv.ParseInt(ps.ByName("id"), 10, 64)
	if err != nil || id <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid device id")
		return
	}
	caller, err := LoadUser(userID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	forbidden := false
	ok, err := revokeDevice(id, func(ownerID int) bool {
		if ownerID == userID || caller.IsOwner {
			return true
		}
		owner, loadErr := LoadUser(ownerID)
		if loadErr != nil || owner.IsOwner {
			forbidden = loadErr == nil
			return false
		}
		return true
	})
	if err != nil {
		log.Printf("RevokeAnyDevice: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if forbidden {
		writeJSONError(w, http.StatusForbidden, "Seul le propriétaire peut déconnecter ses appareils")
		return
	}
	if !ok {
		writeJSONError(w, http.StatusNotFound, "Device not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
