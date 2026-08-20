package handlers

import (
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"log"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Device pairing — how a television signs in.
//
// A TV is driven by a D-pad and has no usable keyboard: typing a password on it
// is the worst screen in the whole app. So it never does. It opens a pairing,
// renders the short code as a QR, and polls; a phone that is already signed in
// scans the code and approves. The approval is what mints the session, so the
// TV's account is exactly the phone's account and no credential ever crosses
// the living room.
//
// The shape is deliberately the OAuth device flow (RFC 8628) minus the parts
// that need an authorization server: start → poll → approve.

// devicePairingTTL is how long an unclaimed code stays live. Short on purpose:
// the code is displayed on a screen anyone in the room can read, and the whole
// interaction takes well under a minute.
const devicePairingTTL = 5 * time.Minute

// devicePairingPollInterval is what the TV is told to wait between polls. The
// server does not enforce it — it costs one indexed primary-key read.
const devicePairingPollInterval = 2

// devicePairingReaperInterval is how often expired pairings are swept. Expiry
// is enforced on read either way, so this only reclaims rows.
const devicePairingReaperInterval = 30 * time.Minute

// userCodeAlphabet omits I, O, 0 and 1: the code is read off a television from
// across a room and typed on a phone, so glyph pairs that look alike are worth
// more than the four extra symbols. 32 symbols over 8 characters is 2^40, which
// is far past guessing inside a five-minute window.
const userCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

const userCodeLength = 8

// DevicePairingStart is the answer to POST /api/auth/device/start.
type DevicePairingStart struct {
	// DeviceCode is the TV's private handle on the pairing. It is never
	// displayed, and it is the only thing that can collect the session.
	DeviceCode string `json:"device_code"`
	// UserCode is the short, human-readable half, shown on screen and encoded
	// in the QR.
	UserCode  string `json:"user_code"`
	ExpiresIn int    `json:"expires_in"`
	Interval  int    `json:"interval"`
}

// DevicePairingPoll is the answer to POST /api/auth/device/poll.
//
// Status is one of "pending", "approved" or "expired". Token and User are set
// only on "approved", and only once: collecting the session consumes the row.
type DevicePairingPoll struct {
	Status string       `json:"status"`
	Token  string       `json:"token,omitempty"`
	User   *models.User `json:"user,omitempty"`
}

// DevicePairingInfo is what the approving phone is shown before it commits: who
// is asking, and how long the request has left.
type DevicePairingInfo struct {
	UserCode   string `json:"user_code"`
	DeviceName string `json:"device_name"`
	ExpiresIn  int    `json:"expires_in"`
}

type devicePairingStartRequest struct {
	DeviceName string `json:"device_name"`
}

type devicePairingPollRequest struct {
	DeviceCode string `json:"device_code"`
}

type devicePairingApproveRequest struct {
	UserCode string `json:"user_code"`
}

// generateUserCode draws a short code from the unambiguous alphabet.
func generateUserCode() (string, error) {
	max := big.NewInt(int64(len(userCodeAlphabet)))
	out := make([]byte, userCodeLength)
	for i := range out {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		out[i] = userCodeAlphabet[n.Int64()]
	}
	return string(out), nil
}

// normalizeUserCode makes what the user typed comparable to what was stored.
// People retype the code with the separator, in lower case, or with spaces.
func normalizeUserCode(raw string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(strings.TrimSpace(raw)) {
		if r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// StartDevicePairing opens a pairing (POST /api/auth/device/start).
//
// Unauthenticated by necessity: the caller is a television with no account yet.
// It hands out nothing but two random strings, and the pairing is worthless
// until a signed-in user approves it.
func StartDevicePairing(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req devicePairingStartRequest
	// A missing or malformed body is fine: the device name is cosmetic.
	_ = json.NewDecoder(r.Body).Decode(&req)

	deviceName := strings.TrimSpace(req.DeviceName)
	if deviceName == "" {
		deviceName = "Téléviseur"
	}
	if len(deviceName) > 64 {
		deviceName = deviceName[:64]
	}

	deviceCode, err := GenerateRandomToken()
	if err != nil {
		log.Printf("StartDevicePairing: token generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// A collision on the short code is a duplicate-key error, not a wrong
	// answer, so retrying a handful of times is enough.
	var userCode string
	for attempt := 0; attempt < 5; attempt++ {
		userCode, err = generateUserCode()
		if err != nil {
			log.Printf("StartDevicePairing: user code generation failed: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		_, err = database.DB.Exec(
			`INSERT INTO device_pairings (device_code, user_code, device_name, expires_at)
			 VALUES (?, ?, ?, datetime('now', ?))`,
			deviceCode, userCode, deviceName, sqliteFuture(devicePairingTTL),
		)
		if err == nil {
			break
		}
		if !strings.Contains(err.Error(), "UNIQUE") {
			log.Printf("StartDevicePairing: insert failed: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
	}
	if err != nil {
		log.Printf("StartDevicePairing: could not allocate a free user code: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(DevicePairingStart{
		DeviceCode: deviceCode,
		UserCode:   userCode,
		ExpiresIn:  int(devicePairingTTL.Seconds()),
		Interval:   devicePairingPollInterval,
	})
}

// PollDevicePairing reports whether a pairing has been approved yet
// (POST /api/auth/device/poll), and hands the session over when it has.
//
// Unauthenticated for the same reason as the start call, and safe for the same
// reason: the device code is a 256-bit secret only the television holds.
func PollDevicePairing(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req devicePairingPollRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	deviceCode := strings.TrimSpace(req.DeviceCode)
	if deviceCode == "" {
		writeJSONError(w, http.StatusBadRequest, "device_code is required")
		return
	}

	var (
		approvedUser sql.NullInt64
		sessionToken sql.NullString
		expired      bool
	)
	err := database.DB.QueryRow(`
		SELECT approved_user_id, session_token, expires_at <= datetime('now')
		FROM device_pairings
		WHERE device_code = ?`, deviceCode,
	).Scan(&approvedUser, &sessionToken, &expired)
	if err == sql.ErrNoRows {
		// Unknown and already-collected look the same on purpose.
		json.NewEncoder(w).Encode(DevicePairingPoll{Status: "expired"})
		return
	}
	if err != nil {
		log.Printf("PollDevicePairing: query failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// An approved pairing is honoured even a moment past its deadline: the
	// window protects the unclaimed code, not the session it produced.
	if !approvedUser.Valid || !sessionToken.Valid {
		if expired {
			deleteDevicePairing(deviceCode)
			json.NewEncoder(w).Encode(DevicePairingPoll{Status: "expired"})
			return
		}
		json.NewEncoder(w).Encode(DevicePairingPoll{Status: "pending"})
		return
	}

	user, err := LoadUser(int(approvedUser.Int64))
	if err != nil {
		log.Printf("PollDevicePairing: failed to load user %d: %v", approvedUser.Int64, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// Single use: the token lives in the sessions table from here on, and the
	// pairing row has no reason to keep a copy of it.
	deleteDevicePairing(deviceCode)

	json.NewEncoder(w).Encode(DevicePairingPoll{
		Status: "approved",
		Token:  sessionToken.String,
		User:   &user,
	})
}

// LookupDevicePairing describes a pending pairing to the phone about to approve
// it (GET /api/auth/device/pending?code=…), so the confirmation screen can name
// the device instead of asking for a blind yes.
func LookupDevicePairing(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	code := normalizeUserCode(r.URL.Query().Get("code"))
	if code == "" {
		writeJSONError(w, http.StatusBadRequest, "code is required")
		return
	}

	var (
		deviceName string
		remaining  float64
	)
	err := database.DB.QueryRow(`
		SELECT device_name,
		       (julianday(expires_at) - julianday('now')) * 86400
		FROM device_pairings
		WHERE user_code = ?
		  AND approved_user_id IS NULL
		  AND expires_at > datetime('now')`, code,
	).Scan(&deviceName, &remaining)
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusNotFound, "Code inconnu ou expiré")
		return
	}
	if err != nil {
		log.Printf("LookupDevicePairing: query failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(DevicePairingInfo{
		UserCode:   code,
		DeviceName: deviceName,
		ExpiresIn:  int(remaining),
	})
}

// ApproveDevicePairing binds a pending pairing to the calling account
// (POST /api/auth/device/approve).
//
// This is the step that mints the session, and it runs as the signed-in user:
// the television inherits that account and its permissions, nothing more.
func ApproveDevicePairing(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req devicePairingApproveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	code := normalizeUserCode(req.UserCode)
	if code == "" {
		writeJSONError(w, http.StatusBadRequest, "user_code is required")
		return
	}

	token, err := GenerateRandomToken()
	if err != nil {
		log.Printf("ApproveDevicePairing: token generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// The session and the approval have to land together: a session nobody can
	// collect is a leaked credential, and an approval pointing at no session
	// hangs the television forever.
	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("ApproveDevicePairing: begin failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer tx.Rollback() //nolint:errcheck // no-op once committed

	// The WHERE clause is the guard: only a live, still-unclaimed code matches,
	// so two phones racing on the same code cannot both approve it.
	res, err := tx.Exec(`
		UPDATE device_pairings
		SET approved_user_id = ?, session_token = ?
		WHERE user_code = ?
		  AND approved_user_id IS NULL
		  AND expires_at > datetime('now')`, userID, token, code)
	if err != nil {
		log.Printf("ApproveDevicePairing: update failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONError(w, http.StatusNotFound, "Code inconnu, expiré ou déjà utilisé")
		return
	}

	if _, err := tx.Exec(
		`INSERT INTO sessions (token, user_id) VALUES (?, ?)`, token, userID,
	); err != nil {
		log.Printf("ApproveDevicePairing: session insert failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("ApproveDevicePairing: commit failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}

// DenyDevicePairing drops a pending pairing (POST /api/auth/device/deny), so a
// user who did not recognise the device can kill the code instead of waiting
// out its five minutes.
func DenyDevicePairing(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	var req devicePairingApproveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	code := normalizeUserCode(req.UserCode)
	if code == "" {
		writeJSONError(w, http.StatusBadRequest, "user_code is required")
		return
	}

	if _, err := database.DB.Exec(
		`DELETE FROM device_pairings WHERE user_code = ? AND approved_user_id IS NULL`, code,
	); err != nil {
		log.Printf("DenyDevicePairing: delete failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}

func deleteDevicePairing(deviceCode string) {
	if _, err := database.DB.Exec(
		`DELETE FROM device_pairings WHERE device_code = ?`, deviceCode,
	); err != nil {
		log.Printf("Device pairing: failed to delete %s: %v", deviceCode, err)
	}
}

// sqliteFuture renders a duration as a forward SQLite modifier, e.g.
// "+300 seconds". Seconds rather than hours because the pairing TTL is minutes.
func sqliteFuture(d time.Duration) string {
	return "+" + strconv.Itoa(int(d.Seconds())) + " seconds"
}

// StartDevicePairingReaper sweeps codes nobody claimed. Expiry is enforced on
// read, so this only keeps the table from accumulating dead rows.
func StartDevicePairingReaper() {
	go func() {
		for {
			purgeExpiredDevicePairings()
			time.Sleep(devicePairingReaperInterval)
		}
	}()
}

func purgeExpiredDevicePairings() {
	grace := "-" + strconv.Itoa(int(devicePairingTTL.Seconds())) + " seconds"

	// A pairing approved but never collected leaves a session nobody holds the
	// token for. It would idle out on its own in ninety days; killing it with
	// its pairing is the same cleanup, ninety days earlier.
	if _, err := database.DB.Exec(`
		DELETE FROM sessions
		WHERE token IN (
			SELECT session_token FROM device_pairings
			WHERE session_token IS NOT NULL AND expires_at <= datetime('now', ?)
		)`, grace); err != nil {
		log.Printf("Device pairing reaper: orphan session sweep: %v", err)
	}

	res, err := database.DB.Exec(
		`DELETE FROM device_pairings WHERE expires_at <= datetime('now', ?)`, grace,
	)
	if err != nil {
		log.Printf("Device pairing reaper: %v", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		log.Printf("Device pairing reaper: removed %d stale pairing(s)", n)
	}
}
