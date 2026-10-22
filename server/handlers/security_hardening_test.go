package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/models"
)

// Un serveur exposé à Internet avant que son propriétaire ne s'inscrive ne
// doit pas revenir au premier venu.
func TestRegister_FirstAccountFromInternetNeedsSetupCode(t *testing.T) {
	setupAuthDB(t)
	register := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/auth/register", strings.NewReader(body))
		req.RemoteAddr = "203.0.113.7:4242"
		rec := httptest.NewRecorder()
		Register(rec, req, nil)
		return rec
	}

	if rec := register(`{"username":"intrus","password":"secret-pass"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("without the code: status %d, want 403: %s", rec.Code, rec.Body)
	}
	if rec := register(`{"username":"intrus","password":"secret-pass","invite_token":"AAAA-AAAA"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("with a wrong code: status %d, want 403", rec.Code)
	}

	code, err := currentSetupCode()
	if err != nil {
		t.Fatal(err)
	}
	typed := strings.ToLower(strings.ReplaceAll(code, "-", " "))
	if rec := register(`{"username":"mathis","password":"secret-pass","invite_token":"` + typed + `"}`); rec.Code != http.StatusOK {
		t.Fatalf("with the code: status %d, want 200: %s", rec.Code, rec.Body)
	}
	if owner, _ := LoadUser(1); !owner.IsOwner {
		t.Error("the account created with the code should be the owner")
	}
}

func TestGetAuthState_AsksForTheCodeOnlyFromOutside(t *testing.T) {
	setupAuthDB(t)
	state := func(remote string) AuthState {
		req := httptest.NewRequest(http.MethodGet, "/api/auth/state", nil)
		req.RemoteAddr = remote
		rec := httptest.NewRecorder()
		GetAuthState(rec, req, nil)
		var s AuthState
		if err := json.Unmarshal(rec.Body.Bytes(), &s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	if s := state("192.168.1.20:1"); !s.SetupRequired || s.SetupCodeRequired {
		t.Errorf("from the house: %+v", s)
	}
	if s := state("203.0.113.7:1"); !s.SetupRequired || !s.SetupCodeRequired {
		t.Errorf("from the internet: %+v", s)
	}
}

func TestNewPasswordsNeedEightCharacters(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	targetID := createTestUser(t, "alice", false, models.DefaultPermissions())
	ownerID := 1

	rec := httptest.NewRecorder()
	ResetUserPassword(rec, httptest.NewRequest(http.MethodPost, "/",
		strings.NewReader(`{"new_password":"court"}`)), idParams(targetID), ownerID)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("reset to 5 characters: status %d, want 400", rec.Code)
	}
	rec = httptest.NewRecorder()
	ResetUserPassword(rec, httptest.NewRequest(http.MethodPost, "/",
		strings.NewReader(`{"new_password":"assez-long"}`)), idParams(targetID), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("reset to 10 characters: status %d, want 200: %s", rec.Code, rec.Body)
	}
}

// manage_users ne vaut plus tous les droits : on n'accorde que ce qu'on a.
func TestUpdateUserPermissions_GrantsOnlyTheCallersOwnRights(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "gestion", false, models.Permissions{ManageUsers: true, RequestMedia: true})
	targetID := createTestUser(t, "alice", false, models.DefaultPermissions())

	update := func(userID, targetID int, body string) int {
		rec := httptest.NewRecorder()
		UpdateUserPermissions(rec, httptest.NewRequest(http.MethodPut, "/", strings.NewReader(body)),
			idParams(targetID), userID)
		return rec.Code
	}

	if code := update(adminID, adminID, `{"permissions":{"manage_users":true,"request_media":true,"manage_settings":true}}`); code != http.StatusForbidden {
		t.Errorf("granting itself manage_settings: status %d, want 403", code)
	}
	if code := update(adminID, targetID, `{"permissions":{"request_media":true,"delete_media":true}}`); code != http.StatusForbidden {
		t.Errorf("granting delete_media it lacks: status %d, want 403", code)
	}
	if code := update(adminID, targetID, `{"permissions":{"request_media":true},"invite_grants":{"manage_settings":true}}`); code != http.StatusForbidden {
		t.Errorf("slipping manage_settings into an invitation template: status %d, want 403", code)
	}
	if code := update(adminID, targetID, `{"permissions":{"request_media":true,"manage_users":true}}`); code != http.StatusOK {
		t.Errorf("granting a right it holds: status %d, want 200", code)
	}
	if after, _ := LoadUser(adminID); after.Permissions.ManageSettings {
		t.Error("the caller gave itself manage_settings")
	}
}

// Un administrateur des comptes ne prend pas la main sur un administrateur
// mieux doté : ni son mot de passe, ni son second facteur, ni son compte.
func TestAccountAdminCannotTakeOverABetterEquippedAdmin(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	adminID := createTestUser(t, "gestion", false, models.Permissions{ManageUsers: true})
	superID := createTestUser(t, "reglages", false, models.Permissions{ManageUsers: true, ManageSettings: true})

	rec := httptest.NewRecorder()
	ResetUserPassword(rec, httptest.NewRequest(http.MethodPost, "/",
		strings.NewReader(`{"new_password":"pris-en-main"}`)), idParams(superID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Errorf("password reset: status %d, want 403", rec.Code)
	}
	rec = httptest.NewRecorder()
	ResetUserOTP(rec, httptest.NewRequest(http.MethodDelete, "/", nil), idParams(superID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Errorf("OTP reset: status %d, want 403", rec.Code)
	}
	rec = httptest.NewRecorder()
	DeleteUser(rec, httptest.NewRequest(http.MethodDelete, "/", nil), idParams(superID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Errorf("deletion: status %d, want 403", rec.Code)
	}
	rec = httptest.NewRecorder()
	UpdateUserPermissions(rec, httptest.NewRequest(http.MethodPut, "/",
		strings.NewReader(`{"permissions":{"manage_settings":true}}`)), idParams(superID), adminID)
	if rec.Code != http.StatusForbidden {
		t.Errorf("demotion: status %d, want 403", rec.Code)
	}
}
