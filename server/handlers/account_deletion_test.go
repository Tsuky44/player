package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"

	"golang.org/x/crypto/bcrypt"
)

func setPasswordForTest(t *testing.T, userID int, password string) {
	t.Helper()
	hash, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if _, err := database.DB.Exec(`UPDATE users SET password_hash = ? WHERE id = ?`, string(hash), userID); err != nil {
		t.Fatalf("set password: %v", err)
	}
}

func deleteOwnAccountStatus(userID int, password string) int {
	rec := httptest.NewRecorder()
	DeleteOwnAccount(rec, httptest.NewRequest(http.MethodPost, "/api/auth/account/delete",
		strings.NewReader(`{"password":"`+password+`"}`)), nil, userID)
	return rec.Code
}

func countUsers(t *testing.T, userID int) int {
	t.Helper()
	var n int
	if err := database.DB.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&n); err != nil {
		t.Fatalf("count users: %v", err)
	}
	return n
}

func TestAMemberDeletesTheirOwnAccountAndItsSessions(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	lea := createTestUser(t, "lea", false, models.Permissions{})
	setPasswordForTest(t, lea, "secret")
	createTestSession(t, lea)

	if code := deleteOwnAccountStatus(lea, "secret"); code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if countUsers(t, lea) != 0 {
		t.Fatal("the account must be gone")
	}
	var sessions int
	database.DB.QueryRow(`SELECT COUNT(*) FROM sessions WHERE user_id = ?`, lea).Scan(&sessions)
	if sessions != 0 {
		t.Errorf("%d session(s) survived the account", sessions)
	}
}

func TestDeletingOnesAccountAsksForThePasswordAgain(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})
	setPasswordForTest(t, lea, "secret")

	if code := deleteOwnAccountStatus(lea, "wrong"); code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", code)
	}
	if countUsers(t, lea) != 1 {
		t.Fatal("a wrong password must not delete anything")
	}
}

// Un serveur sans propriétaire redeviendrait vierge : le premier inscrit en
// prendrait la tête.
func TestTheOwnerCannotDeleteTheirOwnAccount(t *testing.T) {
	setupAuthDB(t)
	owner := createTestUser(t, "owner", true, models.AllPermissions())
	setPasswordForTest(t, owner, "secret")

	if code := deleteOwnAccountStatus(owner, "secret"); code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", code)
	}
	if countUsers(t, owner) != 1 {
		t.Fatal("the owner must still be there")
	}
}
