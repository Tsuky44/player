package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// Direct device linking — how a television signs in without ever knowing this
// server's address first.
//
// The pairing flow in device_pairing.go has a hole a living room falls into:
// the television has to reach the server before it can open a pairing at all,
// and a freshly installed television has no address and no keyboard to be
// given one. Network discovery covers the easy topologies and nothing else.
//
// So the direction is reversed. The television opens a listener of its own on
// the local network and shows a QR pointing at itself; the phone — which does
// know the server, and is already signed in — scans it from inside the app and
// hands over the address together with a session. This endpoint is where that
// session comes from.

// DeviceSession is a credential for another screen, minted for the caller.
type DeviceSession struct {
	Token string       `json:"token"`
	User  *models.User `json:"user"`
}

// CreateDeviceSession issues a session for another device owned by the same
// user (POST /api/auth/device/session).
//
// It runs under the caller's identity, and that is the whole guarantee: the
// television inherits exactly the account that scanned its code, and nothing
// unauthenticated can reach this. There is no code to verify here — the
// one-time code in the QR is the television's business, and the television is
// what checks it when this session is delivered.
//
// A session of its own rather than a copy of the phone's: signing the
// television out later must not sign the phone out with it.
func CreateDeviceSession(w http.ResponseWriter, _ *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	token, err := GenerateRandomToken()
	if err != nil {
		log.Printf("CreateDeviceSession: token generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if _, err := database.DB.Exec(
		`INSERT INTO sessions (token, user_id) VALUES (?, ?)`, token, userID,
	); err != nil {
		log.Printf("CreateDeviceSession: session insert failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("CreateDeviceSession: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(DeviceSession{Token: token, User: &user})
}
