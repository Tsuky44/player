package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"project-player/server/database"
	"project-player/server/models"
)

func TestGetMediaReviewQueue_ReturnsEveryIncompleteMovieAndShow(t *testing.T) {
	setupAuthDB(t)
	for _, args := range [][]interface{}{
		{"movie", "Sans correspondance", "/films/unmatched.mkv", 0, "", "", ""},
		{"movie", "Sans affiche", "/films/no-poster.mkv", 42, "", "Synopsis", "2020-01-01"},
		{"show", "Sans synopsis", "", 84, "https://image/poster.jpg", "", "2021-01-01"},
		{"movie", "Fiche complète", "/films/complete.mkv", 126, "https://image/complete.jpg", "Synopsis", "2022-01-01"},
	} {
		if _, err := database.DB.Exec(`
			INSERT INTO medias (type, title, file_path, tmdb_id, poster_url, overview, release_date)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, args...); err != nil {
			t.Fatalf("insert media: %v", err)
		}
	}

	rec := httptest.NewRecorder()
	GetMediaReviewQueue(rec, httptest.NewRequest("GET", "/api/indexer/review", nil), nil, 1)

	if rec.Code != 200 {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var payload struct {
		Items []models.Media `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(payload.Items) != 3 {
		t.Fatalf("items = %d, want 3: %#v", len(payload.Items), payload.Items)
	}
	for _, item := range payload.Items {
		if item.Title == "Fiche complète" {
			t.Fatal("complete metadata must not appear in the review queue")
		}
	}
}
