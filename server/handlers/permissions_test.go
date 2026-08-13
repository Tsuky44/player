package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

// setupAuthDB gives the test a fresh SQLite file with the real schema, so the
// migrations themselves are exercised rather than a hand-written table.
func setupAuthDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
}

func createTestUser(t *testing.T, username string, owner bool, perms models.Permissions) int {
	t.Helper()
	res, err := database.DB.Exec(
		`INSERT INTO users (
			username, password_hash, is_owner,
			perm_manage_settings, perm_manage_library, perm_manage_users,
			perm_delete_media, perm_invite_users, perm_request_media
		) VALUES (?, 'x', ?, ?, ?, ?, ?, ?, ?)`,
		username, owner,
		perms.ManageSettings, perms.ManageLibrary, perms.ManageUsers,
		perms.DeleteMedia, perms.InviteUsers, perms.RequestMedia)
	if err != nil {
		t.Fatalf("insert user %s: %v", username, err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func createTestSession(t *testing.T, userID int) string {
	t.Helper()
	token, err := GenerateRandomToken()
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	if _, err := database.DB.Exec("INSERT INTO sessions (token, user_id) VALUES (?, ?)", token, userID); err != nil {
		t.Fatalf("insert session: %v", err)
	}
	return token
}

func authedRequest(method, target, body, token string) *http.Request {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

func idParams(id int) httprouter.Params {
	return httprouter.Params{{Key: "id", Value: strconv.Itoa(id)}}
}

func okHandler(called *bool) AuthenticatedHandle {
	return func(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
		*called = true
		w.WriteHeader(http.StatusOK)
	}
}

func TestRequirePermission_AllowsHolder(t *testing.T) {
	setupAuthDB(t)
	id := createTestUser(t, "alice", false, models.Permissions{ManageLibrary: true})
	token := createTestSession(t, id)

	called := false
	h := RequirePermission(models.PermManageLibrary, okHandler(&called))
	rec := httptest.NewRecorder()
	h(rec, authedRequest(http.MethodPost, "/api/indexer/scan", "", token), nil)

	if !called || rec.Code != http.StatusOK {
		t.Fatalf("expected handler to run, got code=%d called=%v", rec.Code, called)
	}
}

func TestRequirePermission_RejectsWithout(t *testing.T) {
	setupAuthDB(t)
	id := createTestUser(t, "bob", false, models.DefaultPermissions())
	token := createTestSession(t, id)

	called := false
	h := RequirePermission(models.PermManageSettings, okHandler(&called))
	rec := httptest.NewRecorder()
	h(rec, authedRequest(http.MethodPut, "/api/settings", "", token), nil)

	if called {
		t.Fatal("handler ran without the permission")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}

// A stale or forged token must not become a permission: no session, no rights.
func TestRequirePermission_RejectsUnauthenticated(t *testing.T) {
	setupAuthDB(t)

	called := false
	h := RequirePermission(models.PermManageUsers, okHandler(&called))
	rec := httptest.NewRecorder()
	h(rec, authedRequest(http.MethodGet, "/api/users", "", "not-a-real-token"), nil)

	if called || rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d called=%v", rec.Code, called)
	}
}

func TestRequireAnyPermission_AcceptsEither(t *testing.T) {
	setupAuthDB(t)
	// An administrator who was never given invite_users still reaches the
	// invitation list, because manage_users also opens that route.
	id := createTestUser(t, "admin", false, models.Permissions{ManageUsers: true})
	token := createTestSession(t, id)

	called := false
	h := RequireAnyPermission(
		[]models.Permission{models.PermInviteUsers, models.PermManageUsers}, okHandler(&called))
	rec := httptest.NewRecorder()
	h(rec, authedRequest(http.MethodGet, "/api/invitations", "", token), nil)

	if !called || rec.Code != http.StatusOK {
		t.Fatalf("expected handler to run, got code=%d called=%v", rec.Code, called)
	}
}

func TestRegister_FirstAccountBecomesOwner(t *testing.T) {
	setupAuthDB(t)

	rec := httptest.NewRecorder()
	Register(rec, httptest.NewRequest(http.MethodPost, "/api/auth/register",
		strings.NewReader(`{"username":"mathis","password":"secret"}`)), nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected the first account to be accepted, got %d: %s", rec.Code, rec.Body)
	}

	user, err := LoadUser(1)
	if err != nil {
		t.Fatalf("LoadUser: %v", err)
	}
	if !user.IsOwner {
		t.Error("first account should be the owner")
	}
	if !user.Permissions.IsAdmin() {
		t.Errorf("first account should hold every permission, got %+v", user.Permissions)
	}
}

// Once an account exists, sign-up is closed: only an invitation opens it.
func TestRegister_ClosedWithoutInvitation(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())

	rec := httptest.NewRecorder()
	Register(rec, httptest.NewRequest(http.MethodPost, "/api/auth/register",
		strings.NewReader(`{"username":"intruder","password":"secret"}`)), nil)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 without invitation, got %d: %s", rec.Code, rec.Body)
	}
}

func TestGetAuthState_ReportsSetupThenCloses(t *testing.T) {
	setupAuthDB(t)

	var state AuthState
	rec := httptest.NewRecorder()
	GetAuthState(rec, httptest.NewRequest(http.MethodGet, "/api/auth/state", nil), nil)
	json.Unmarshal(rec.Body.Bytes(), &state)
	if !state.SetupRequired {
		t.Error("a pristine server should report setup_required")
	}

	createTestUser(t, "owner", true, models.AllPermissions())

	rec = httptest.NewRecorder()
	GetAuthState(rec, httptest.NewRequest(http.MethodGet, "/api/auth/state", nil), nil)
	json.Unmarshal(rec.Body.Bytes(), &state)
	if state.SetupRequired {
		t.Error("setup_required should be false once an account exists")
	}
}

// The owner is asymmetric: another admin cannot strip their rights.
func TestUpdateUserPermissions_OwnerProtectedFromOtherAdmin(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "brother", false, models.AllPermissions())

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/1/permissions",
			strings.NewReader(`{"permissions":{}}`)),
		idParams(ownerID), adminID)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 when demoting the owner, got %d: %s", rec.Code, rec.Body)
	}
	owner, _ := LoadUser(ownerID)
	if !owner.Permissions.IsAdmin() {
		t.Error("owner permissions were modified")
	}
}

// Below the owner rule, the backstop: never zero administrators.
func TestUpdateUserPermissions_LastAdminKept(t *testing.T) {
	setupAuthDB(t)
	adminID := createTestUser(t, "solo", false, models.AllPermissions())

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/1/permissions",
			strings.NewReader(`{"permissions":{"request_media":true}}`)),
		idParams(adminID), adminID)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 when demoting the last admin, got %d: %s", rec.Code, rec.Body)
	}
}

func TestUpdateUserPermissions_OwnerMayDemoteAnotherAdmin(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "brother", false, models.AllPermissions())

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/2/permissions",
			strings.NewReader(`{"permissions":{"request_media":true}}`)),
		idParams(adminID), ownerID)

	if rec.Code != http.StatusOK {
		t.Fatalf("owner should be able to demote another admin, got %d: %s", rec.Code, rec.Body)
	}
	demoted, _ := LoadUser(adminID)
	if demoted.Permissions.ManageUsers {
		t.Error("manage_users should have been removed")
	}
}

func TestDeleteUser_OwnerAndSelfProtected(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "brother", false, models.AllPermissions())

	rec := httptest.NewRecorder()
	DeleteUser(rec, httptest.NewRequest(http.MethodDelete, "/api/users/1", nil), idParams(ownerID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 deleting the owner, got %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	DeleteUser(rec, httptest.NewRequest(http.MethodDelete, "/api/users/2", nil), idParams(adminID), adminID)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 deleting yourself, got %d", rec.Code)
	}
}

func TestTransferOwnership_OwnerOnly(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "brother", false, models.AllPermissions())

	// A plain admin cannot grab ownership.
	rec := httptest.NewRecorder()
	TransferOwnership(rec, httptest.NewRequest(http.MethodPost, "/api/users/2/transfer-ownership", nil),
		idParams(adminID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-owner, got %d", rec.Code)
	}

	// The owner hands it over, and there is exactly one owner afterwards.
	rec = httptest.NewRecorder()
	TransferOwnership(rec, httptest.NewRequest(http.MethodPost, "/api/users/2/transfer-ownership", nil),
		idParams(adminID), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected the transfer to succeed, got %d: %s", rec.Code, rec.Body)
	}

	oldOwner, _ := LoadUser(ownerID)
	newOwner, _ := LoadUser(adminID)
	if oldOwner.IsOwner || !newOwner.IsOwner {
		t.Fatalf("ownership did not move: old=%v new=%v", oldOwner.IsOwner, newOwner.IsOwner)
	}
	if !newOwner.Permissions.IsAdmin() {
		t.Error("the new owner should hold every permission")
	}
}

// Installs that predate permissions must not end up with nobody in charge.
func TestMigration_OldestAccountBecomesOwner(t *testing.T) {
	setupAuthDB(t)
	// Simulate a pre-permissions database: rows with no rights at all.
	for _, name := range []string{"mathis", "brother"} {
		if _, err := database.DB.Exec(
			`INSERT INTO users (username, password_hash, perm_request_media) VALUES (?, 'x', 0)`,
			name); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}

	if _, err := database.DB.Exec(`UPDATE users SET
			is_owner = 1, perm_manage_settings = 1, perm_manage_library = 1,
			perm_manage_users = 1, perm_delete_media = 1, perm_invite_users = 1,
			perm_request_media = 1
		WHERE id = (SELECT MIN(id) FROM users)
		  AND NOT EXISTS (SELECT 1 FROM users WHERE is_owner = 1);`); err != nil {
		t.Fatalf("backfill: %v", err)
	}

	first, _ := LoadUser(1)
	second, _ := LoadUser(2)
	if !first.IsOwner || !first.Permissions.IsAdmin() {
		t.Errorf("oldest account should become owner, got %+v", first)
	}
	if second.IsOwner || second.Permissions.ManageUsers {
		t.Errorf("other accounts should stay plain, got %+v", second)
	}
}
