package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

func setInviteGrants(t *testing.T, userID int, grants models.Permissions) {
	t.Helper()
	if _, err := database.DB.Exec("UPDATE users SET invite_grants = ? WHERE id = ?",
		models.EncodePermissions(grants), userID); err != nil {
		t.Fatalf("set invite_grants: %v", err)
	}
}

func createInvitation(t *testing.T, inviterID int) Invitation {
	t.Helper()
	rec := httptest.NewRecorder()
	CreateInvitation(rec, httptest.NewRequest(http.MethodPost, "/api/invitations", strings.NewReader("")),
		nil, inviterID)
	if rec.Code != http.StatusOK {
		t.Fatalf("CreateInvitation: got %d: %s", rec.Code, rec.Body)
	}
	var inv Invitation
	if err := json.Unmarshal(rec.Body.Bytes(), &inv); err != nil {
		t.Fatalf("decode invitation: %v", err)
	}
	return inv
}

func registerWithToken(t *testing.T, username, token string) *httptest.ResponseRecorder {
	t.Helper()
	body := `{"username":"` + username + `","password":"secret","invite_token":"` + token + `"}`
	rec := httptest.NewRecorder()
	Register(rec, httptest.NewRequest(http.MethodPost, "/api/auth/register", strings.NewReader(body)), nil)
	return rec
}

// The template belongs to the account, not to the inviter's whim: whatever an
// inviter sends, the link grants what the admin configured.
func TestCreateInvitation_UsesAdminConfiguredTemplate(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "brother", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, inviterID, models.Permissions{RequestMedia: true})

	rec := httptest.NewRecorder()
	// The inviter tries to mint an admin link for themselves.
	CreateInvitation(rec, httptest.NewRequest(http.MethodPost, "/api/invitations",
		strings.NewReader(`{"grants":{"manage_users":true,"manage_settings":true}}`)), nil, inviterID)
	if rec.Code != http.StatusOK {
		t.Fatalf("CreateInvitation: got %d: %s", rec.Code, rec.Body)
	}

	var inv Invitation
	json.Unmarshal(rec.Body.Bytes(), &inv)
	if inv.Grants.ManageUsers || inv.Grants.ManageSettings {
		t.Fatalf("an inviter must not choose the grants, got %+v", inv.Grants)
	}
	if !inv.Grants.RequestMedia {
		t.Errorf("expected the configured template, got %+v", inv.Grants)
	}
}

func TestRegister_InvitationAppliesFrozenGrants(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "brother", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, inviterID, models.Permissions{RequestMedia: true, ManageLibrary: true})

	inv := createInvitation(t, inviterID)

	if rec := registerWithToken(t, "cousin", inv.Token); rec.Code != http.StatusOK {
		t.Fatalf("expected registration to succeed, got %d: %s", rec.Code, rec.Body)
	}

	created, err := LoadUser(3)
	if err != nil {
		t.Fatalf("LoadUser: %v", err)
	}
	if !created.Permissions.RequestMedia || !created.Permissions.ManageLibrary {
		t.Errorf("invitation grants were not applied, got %+v", created.Permissions)
	}
	if created.Permissions.ManageUsers || created.IsOwner {
		t.Error("an invited account must not be an owner or admin")
	}
}

func TestInvitation_IsSingleUse(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	setInviteGrants(t, ownerID, models.DefaultPermissions())

	inv := createInvitation(t, ownerID)

	if rec := registerWithToken(t, "first", inv.Token); rec.Code != http.StatusOK {
		t.Fatalf("first redemption should succeed, got %d: %s", rec.Code, rec.Body)
	}
	rec := registerWithToken(t, "second", inv.Token)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("second redemption should be refused, got %d: %s", rec.Code, rec.Body)
	}
}

func TestInvitation_ExpiredIsRefused(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	setInviteGrants(t, ownerID, models.DefaultPermissions())

	inv := createInvitation(t, ownerID)
	// Push the link past its TTL rather than waiting a week.
	if _, err := database.DB.Exec("UPDATE invitations SET expires_at = ? WHERE token = ?",
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339), inv.Token); err != nil {
		t.Fatalf("expire invitation: %v", err)
	}

	if rec := registerWithToken(t, "latecomer", inv.Token); rec.Code != http.StatusForbidden {
		t.Fatalf("expired invitation should be refused, got %d: %s", rec.Code, rec.Body)
	}
}

func TestInvitation_RevokedIsRefused(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	setInviteGrants(t, ownerID, models.DefaultPermissions())

	inv := createInvitation(t, ownerID)

	rec := httptest.NewRecorder()
	RevokeInvitation(rec, httptest.NewRequest(http.MethodDelete, "/api/invitations/"+inv.Token, nil),
		httprouter.Params{{Key: "token", Value: inv.Token}}, ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke failed: %d %s", rec.Code, rec.Body)
	}

	if rec := registerWithToken(t, "wrongperson", inv.Token); rec.Code != http.StatusForbidden {
		t.Fatalf("revoked invitation should be refused, got %d", rec.Code)
	}
}

// Taking away invite_users has to take away what it already produced —
// otherwise the right is only revoked on paper while links are in the wild.
func TestUpdateUserPermissions_RevokingInviteRightKillsPendingLinks(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "brother", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, inviterID, models.DefaultPermissions())

	inv := createInvitation(t, inviterID)

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/2/permissions",
			strings.NewReader(`{"permissions":{"request_media":true}}`)),
		idParams(inviterID), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("permission update failed: %d %s", rec.Code, rec.Body)
	}

	if rec := registerWithToken(t, "friend", inv.Token); rec.Code != http.StatusForbidden {
		t.Fatalf("pending link should die with the right, got %d", rec.Code)
	}
}

// Editing the template is not a revocation: an invitation someone is waiting on
// keeps working, and keeps the grants it was created with.
func TestUpdateUserPermissions_EditingTemplateKeepsPendingLinks(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "brother", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, inviterID, models.Permissions{RequestMedia: true, ManageLibrary: true})

	inv := createInvitation(t, inviterID)

	rec := httptest.NewRecorder()
	UpdateUserPermissions(rec,
		httptest.NewRequest(http.MethodPut, "/api/users/2/permissions",
			strings.NewReader(`{"permissions":{"invite_users":true,"request_media":true},
				"invite_grants":{"request_media":true}}`)),
		idParams(inviterID), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("permission update failed: %d %s", rec.Code, rec.Body)
	}

	if rec := registerWithToken(t, "cousin", inv.Token); rec.Code != http.StatusOK {
		t.Fatalf("pending link should survive a template edit, got %d: %s", rec.Code, rec.Body)
	}
	created, _ := LoadUser(3)
	if !created.Permissions.ManageLibrary {
		t.Error("the link should still grant what it was created with")
	}
}

// An inviter sees their own links; an administrator sees everything.
func TestListInvitations_ScopedToInviter(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "brother", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, ownerID, models.DefaultPermissions())
	setInviteGrants(t, inviterID, models.DefaultPermissions())

	createInvitation(t, ownerID)
	createInvitation(t, inviterID)

	var own []Invitation
	rec := httptest.NewRecorder()
	ListInvitations(rec, httptest.NewRequest(http.MethodGet, "/api/invitations", nil), nil, inviterID)
	json.Unmarshal(rec.Body.Bytes(), &own)
	if len(own) != 1 || own[0].InviterID != inviterID {
		t.Fatalf("an inviter should only see their own links, got %+v", own)
	}

	var all []Invitation
	rec = httptest.NewRecorder()
	ListInvitations(rec, httptest.NewRequest(http.MethodGet, "/api/invitations", nil), nil, ownerID)
	json.Unmarshal(rec.Body.Bytes(), &all)
	if len(all) != 2 {
		t.Fatalf("an administrator should see every link, got %d", len(all))
	}
}
