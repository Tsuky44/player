package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"project-player/server/models"
)

func decodeAnnouncement(t *testing.T, rec *httptest.ResponseRecorder) *models.Announcement {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("announcement: status %d: %s", rec.Code, rec.Body.String())
	}
	var resp announcementResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode announcement: %v", err)
	}
	return resp.Announcement
}

func publish(t *testing.T, authorID int, body string) *models.Announcement {
	t.Helper()
	rec := httptest.NewRecorder()
	PublishAnnouncement(rec, httptest.NewRequest(http.MethodPut, "/api/announcement",
		strings.NewReader(body)), nil, authorID)
	return decodeAnnouncement(t, rec)
}

func pendingFor(t *testing.T, userID int) *models.Announcement {
	t.Helper()
	rec := httptest.NewRecorder()
	GetPendingAnnouncement(rec, httptest.NewRequest(http.MethodGet, "/api/me/announcement", nil), nil, userID)
	return decodeAnnouncement(t, rec)
}

func markSeen(t *testing.T, userID, id int) {
	t.Helper()
	rec := httptest.NewRecorder()
	body, _ := json.Marshal(announcementSeenRequest{ID: id})
	MarkAnnouncementSeen(rec, httptest.NewRequest(http.MethodPost, "/api/me/announcement/seen",
		strings.NewReader(string(body))), nil, userID)
	if rec.Code != http.StatusOK {
		t.Fatalf("mark seen: status %d", rec.Code)
	}
}

// Le message s'affiche une fois par compte : fermé, il ne revient pas ; son
// auteur ne le reçoit pas, il vient de l'écrire.
func TestAnnouncementShowsOncePerAccountAndNotToItsAuthor(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.Permissions{})
	alice := createTestUser(t, "alice", false, models.Permissions{})

	if got := pendingFor(t, alice); got != nil {
		t.Fatalf("no announcement yet: got %+v", got)
	}

	published := publish(t, admin, `{"title":"  Maintenance ","message":" Le serveur redémarre ce soir. "}`)
	if published == nil || published.Title != "Maintenance" || published.Message != "Le serveur redémarre ce soir." {
		t.Fatalf("published: got %+v", published)
	}
	if got := pendingFor(t, admin); got != nil {
		t.Fatalf("author should not see their own announcement: got %+v", got)
	}

	got := pendingFor(t, alice)
	if got == nil || got.ID != published.ID {
		t.Fatalf("alice pending: got %+v, want id %d", got, published.ID)
	}
	markSeen(t, alice, got.ID)
	if got := pendingFor(t, alice); got != nil {
		t.Fatalf("closed announcement came back: %+v", got)
	}
}

// Republier, même le même texte, le remontre à tous : c'est un nouveau
// message. Une marque plus ancienne envoyée par un appareil en retard ne fait
// pas reculer celle du compte.
func TestAnnouncementRepublishShowsAgainAndSeenNeverMovesBack(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.Permissions{})
	alice := createTestUser(t, "alice", false, models.Permissions{})

	first := publish(t, admin, `{"message":"Bonjour"}`)
	markSeen(t, alice, first.ID)

	second := publish(t, admin, `{"message":"Bonjour"}`)
	if second.ID <= first.ID {
		t.Fatalf("republished id %d should exceed %d", second.ID, first.ID)
	}
	if got := pendingFor(t, alice); got == nil || got.ID != second.ID {
		t.Fatalf("republished announcement: got %+v", got)
	}

	markSeen(t, alice, second.ID)
	markSeen(t, alice, first.ID)
	if got := pendingFor(t, alice); got != nil {
		t.Fatalf("stale seen mark resurrected the announcement: %+v", got)
	}
}

// Retiré, le message ne s'affiche plus ; publié ensuite, le suivant passe
// devant la marque de ceux qui avaient fermé l'ancien.
func TestAnnouncementClearHidesItAndNextOneStillShows(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.Permissions{})
	alice := createTestUser(t, "alice", false, models.Permissions{})

	first := publish(t, admin, `{"message":"Un"}`)
	markSeen(t, alice, first.ID)

	rec := httptest.NewRecorder()
	ClearAnnouncement(rec, httptest.NewRequest(http.MethodDelete, "/api/announcement", nil), nil, admin)
	if got := decodeAnnouncement(t, rec); got != nil {
		t.Fatalf("clear: got %+v", got)
	}
	rec = httptest.NewRecorder()
	GetAnnouncement(rec, httptest.NewRequest(http.MethodGet, "/api/announcement", nil), nil, admin)
	if got := decodeAnnouncement(t, rec); got != nil {
		t.Fatalf("after clear: got %+v", got)
	}

	next := publish(t, admin, `{"message":"Deux"}`)
	if got := pendingFor(t, alice); got == nil || got.ID != next.ID {
		t.Fatalf("announcement after clear: got %+v, want id %d", got, next.ID)
	}
}

func TestAnnouncementRejectsEmptyOrOversizedMessage(t *testing.T) {
	setupAuthDB(t)
	admin := createTestUser(t, "admin", true, models.Permissions{})

	for name, body := range map[string]string{
		"empty":      `{"title":"Titre","message":"   "}`,
		"long title": `{"title":"` + strings.Repeat("é", maxAnnouncementTitle+1) + `","message":"ok"}`,
		"long body":  `{"message":"` + strings.Repeat("é", maxAnnouncementMessage+1) + `"}`,
	} {
		rec := httptest.NewRecorder()
		PublishAnnouncement(rec, httptest.NewRequest(http.MethodPut, "/api/announcement",
			strings.NewReader(body)), nil, admin)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, rec.Code)
		}
	}
	// Juste à la limite, en caractères accentués : accepté.
	publish(t, admin, `{"message":"`+strings.Repeat("é", maxAnnouncementMessage)+`"}`)
}
