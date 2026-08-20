package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func startPairing(t *testing.T, deviceName string) DevicePairingStart {
	t.Helper()
	rec := httptest.NewRecorder()
	StartDevicePairing(rec, httptest.NewRequest(http.MethodPost, "/api/auth/device/start",
		strings.NewReader(`{"device_name":"`+deviceName+`"}`)), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("StartDevicePairing: got %d: %s", rec.Code, rec.Body)
	}
	var out DevicePairingStart
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode pairing: %v", err)
	}
	return out
}

func pollPairing(t *testing.T, deviceCode string) DevicePairingPoll {
	t.Helper()
	rec := httptest.NewRecorder()
	PollDevicePairing(rec, httptest.NewRequest(http.MethodPost, "/api/auth/device/poll",
		strings.NewReader(`{"device_code":"`+deviceCode+`"}`)), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("PollDevicePairing: got %d: %s", rec.Code, rec.Body)
	}
	var out DevicePairingPoll
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode poll: %v", err)
	}
	return out
}

func approvePairing(t *testing.T, userCode string, userID int) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	ApproveDevicePairing(rec, httptest.NewRequest(http.MethodPost, "/api/auth/device/approve",
		strings.NewReader(`{"user_code":"`+userCode+`"}`)), nil, userID)
	return rec
}

// The whole point of the flow: the television ends up holding a working session
// for the account that approved it, and never anything else.
func TestDevicePairing_ApprovalHandsTheTvTheApproversSession(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	viewerID := createTestUser(t, "viewer", false, models.DefaultPermissions())

	pairing := startPairing(t, "Salon")

	if got := pollPairing(t, pairing.DeviceCode); got.Status != "pending" {
		t.Fatalf("before approval: got %q, want pending", got.Status)
	}

	if rec := approvePairing(t, pairing.UserCode, viewerID); rec.Code != http.StatusOK {
		t.Fatalf("ApproveDevicePairing: got %d: %s", rec.Code, rec.Body)
	}

	got := pollPairing(t, pairing.DeviceCode)
	if got.Status != "approved" {
		t.Fatalf("after approval: got %q, want approved", got.Status)
	}
	if got.User == nil || got.User.ID != viewerID {
		t.Fatalf("the TV must inherit the approver's account, got %+v", got.User)
	}

	// The token has to be a real session, not just a string echoed back.
	userID, ok, err := lookupSession(got.Token)
	if err != nil || !ok {
		t.Fatalf("lookupSession(%q): ok=%v err=%v", got.Token, ok, err)
	}
	if userID != viewerID {
		t.Fatalf("session belongs to user %d, want %d", userID, viewerID)
	}
}

// Collecting the session consumes the pairing. A device code that stayed
// redeemable would be a credential sitting in a table waiting to be replayed.
func TestDevicePairing_SessionIsCollectedOnlyOnce(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "owner", true, models.AllPermissions())

	pairing := startPairing(t, "Salon")
	approvePairing(t, pairing.UserCode, userID)

	first := pollPairing(t, pairing.DeviceCode)
	if first.Status != "approved" {
		t.Fatalf("first poll: got %q, want approved", first.Status)
	}

	second := pollPairing(t, pairing.DeviceCode)
	if second.Status != "expired" {
		t.Fatalf("second poll: got %q, want expired", second.Status)
	}
	if second.Token != "" {
		t.Fatalf("a consumed pairing must not hand out a token again, got %q", second.Token)
	}
}

// Two people racing on the same code — the one shown on screen, read by two
// phones — must not produce two sessions on one television.
func TestDevicePairing_SecondApprovalIsRejected(t *testing.T) {
	setupAuthDB(t)
	firstID := createTestUser(t, "owner", true, models.AllPermissions())
	secondID := createTestUser(t, "viewer", false, models.DefaultPermissions())

	pairing := startPairing(t, "Salon")

	if rec := approvePairing(t, pairing.UserCode, firstID); rec.Code != http.StatusOK {
		t.Fatalf("first approval: got %d: %s", rec.Code, rec.Body)
	}
	if rec := approvePairing(t, pairing.UserCode, secondID); rec.Code != http.StatusNotFound {
		t.Fatalf("second approval: got %d, want 404", rec.Code)
	}

	got := pollPairing(t, pairing.DeviceCode)
	if got.User == nil || got.User.ID != firstID {
		t.Fatalf("the first approver must win, got %+v", got.User)
	}
}

// An expired code is dead even though nobody polled it in the meantime, and it
// reads the same as one that never existed.
func TestDevicePairing_ExpiredCodeCannotBeApproved(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "owner", true, models.AllPermissions())

	pairing := startPairing(t, "Salon")
	if _, err := database.DB.Exec(
		`UPDATE device_pairings SET expires_at = datetime('now', '-1 minute') WHERE device_code = ?`,
		pairing.DeviceCode,
	); err != nil {
		t.Fatalf("age the pairing: %v", err)
	}

	if rec := approvePairing(t, pairing.UserCode, userID); rec.Code != http.StatusNotFound {
		t.Fatalf("approving an expired code: got %d, want 404", rec.Code)
	}
	if got := pollPairing(t, pairing.DeviceCode); got.Status != "expired" {
		t.Fatalf("polling an expired code: got %q, want expired", got.Status)
	}
}

// The user types what they read off the television, which is the grouped form,
// often in lower case. All of it has to resolve to the stored code.
func TestDevicePairing_UserCodeIsNormalised(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "owner", true, models.AllPermissions())

	pairing := startPairing(t, "Salon")
	typed := strings.ToLower(pairing.UserCode[:4]) + "-" + strings.ToLower(pairing.UserCode[4:])

	if rec := approvePairing(t, typed, userID); rec.Code != http.StatusOK {
		t.Fatalf("approving %q: got %d: %s", typed, rec.Code, rec.Body)
	}
}

// An unknown code tells the caller nothing it did not already know, so probing
// for live pairings gains an attacker no signal.
func TestDevicePairing_UnknownDeviceCodeReadsAsExpired(t *testing.T) {
	setupAuthDB(t)

	if got := pollPairing(t, "0123456789abcdef"); got.Status != "expired" {
		t.Fatalf("unknown device code: got %q, want expired", got.Status)
	}
}

// The phone is shown what it is about to authorise before it authorises it.
func TestDevicePairing_LookupDescribesThePendingDevice(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "owner", true, models.AllPermissions())

	pairing := startPairing(t, "Salon")

	rec := httptest.NewRecorder()
	LookupDevicePairing(rec, httptest.NewRequest(http.MethodGet,
		"/api/auth/device/pending?code="+pairing.UserCode, nil), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("LookupDevicePairing: got %d: %s", rec.Code, rec.Body)
	}

	var info DevicePairingInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatalf("decode info: %v", err)
	}
	if info.DeviceName != "Salon" {
		t.Errorf("device name: got %q, want Salon", info.DeviceName)
	}
	if info.ExpiresIn <= 0 {
		t.Errorf("expires_in: got %d, want a positive countdown", info.ExpiresIn)
	}

	// Once approved it is no longer pending, and no longer offered for approval.
	approvePairing(t, pairing.UserCode, userID)
	rec = httptest.NewRecorder()
	LookupDevicePairing(rec, httptest.NewRequest(http.MethodGet,
		"/api/auth/device/pending?code="+pairing.UserCode, nil), nil, userID)
	if rec.Code != http.StatusNotFound {
		t.Errorf("lookup after approval: got %d, want 404", rec.Code)
	}
}

// Refusing kills the code outright rather than leaving it live for five
// minutes on a screen the user did not recognise.
func TestDevicePairing_DenyDropsTheCode(t *testing.T) {
	setupAuthDB(t)
	userID := createTestUser(t, "owner", true, models.AllPermissions())

	pairing := startPairing(t, "Salon")

	rec := httptest.NewRecorder()
	DenyDevicePairing(rec, httptest.NewRequest(http.MethodPost, "/api/auth/device/deny",
		strings.NewReader(`{"user_code":"`+pairing.UserCode+`"}`)), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("DenyDevicePairing: got %d: %s", rec.Code, rec.Body)
	}

	if rec := approvePairing(t, pairing.UserCode, userID); rec.Code != http.StatusNotFound {
		t.Fatalf("approving a denied code: got %d, want 404", rec.Code)
	}
	if got := pollPairing(t, pairing.DeviceCode); got.Status != "expired" {
		t.Fatalf("polling a denied code: got %q, want expired", got.Status)
	}
}
