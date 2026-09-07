package handlers

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"project-player/server/database"
	"project-player/server/models"
	"testing"
)

func TestResolveMediaRequiresExactIdentityAndReadableFile(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	path := filepath.Join(t.TempDir(), "episode.mkv")
	if err := os.WriteFile(path, []byte("test video placeholder"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := database.DB.Exec(`UPDATE medias SET tmdb_id = 42 WHERE type = 'show'; UPDATE medias SET file_path = ? WHERE type = 'episode'`, path); err != nil {
		t.Fatal(err)
	}
	identity := ContentIdentity{Type: "episode", TMDBID: 42, Season: 1, Episode: 5}
	resolve := func() *httptest.ResponseRecorder {
		body, _ := json.Marshal(identity)
		w := httptest.NewRecorder()
		ResolveMedia(w, httptest.NewRequest("POST", "/api/media-resolve", bytes.NewReader(body)), nil, 1)
		return w
	}
	response := resolve()
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	var media models.Media
	if err := json.Unmarshal(response.Body.Bytes(), &media); err != nil {
		t.Fatal(err)
	}
	if media.Type != models.TypeEpisode || media.FilePath != path {
		t.Fatalf("wrong media: %#v", media)
	}
	w := httptest.NewRecorder()
	GetMediaIdentities(w, httptest.NewRequest("GET", "/api/media-identities", nil), nil, 1)
	var identities map[int]ContentIdentity
	if err := json.Unmarshal(w.Body.Bytes(), &identities); err != nil {
		t.Fatal(err)
	}
	if identities[media.ID] != identity {
		t.Fatalf("wrong identity: %#v", identities)
	}
	identity.Episode = 6
	if resolve().Code != 404 {
		t.Fatal("different episode matched")
	}
	identity.Episode = 5
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if resolve().Code != 404 {
		t.Fatal("missing file matched")
	}
	identity.TMDBID = 0
	if resolve().Code != 400 {
		t.Fatal("invalid identity accepted")
	}
}
