package handlers

import (
	"encoding/json"
	"fmt"
	"github.com/julienschmidt/httprouter"
	"net/http/httptest"
	"project-player/server/database"
	"project-player/server/models"
	"testing"
)

func TestMoviesGroupVersionsWithoutDeletingFiles(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	for _, path := range []string{"Film.1080p.mkv", "Film.2160p.mkv"} {
		if _, err := database.DB.Exec(`INSERT INTO medias(type,title,tmdb_id,file_path,duration) VALUES('movie','Film',42,?,7200)`, path); err != nil {
			t.Fatal(err)
		}
	}
	w := httptest.NewRecorder()
	GetMovies(w, httptest.NewRequest("GET", "/api/movies", nil), nil, 1)
	var items []models.HomeMediaItem
	if err := json.Unmarshal(w.Body.Bytes(), &items); err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("want one card for two versions, got %d", len(items))
	}
	if items[0].FilePath != "Film.2160p.mkv" {
		t.Fatalf("default is not highest quality: %s", items[0].FilePath)
	}
	if len(items[0].Versions) != 2 || items[0].Versions[1].FilePath != "Film.1080p.mkv" {
		t.Fatalf("versions missing from card: %+v", items[0].Versions)
	}
	versions, err := movieVersions(items[0].Versions[1].ID, 1)
	if err != nil || len(versions) != 2 || versions[0].ID != items[0].ID {
		t.Fatalf("opening lower quality must expose best first: %+v, %v", versions, err)
	}
	var count int
	database.DB.QueryRow(`SELECT COUNT(*) FROM medias WHERE type='movie'`).Scan(&count)
	if count != 2 {
		t.Fatalf("versions deleted: %d", count)
	}
}

func TestVersionQualityUsesProbeBeforeFilename(t *testing.T) {
	item := models.HomeMediaItem{Media: models.Media{FilePath: "Film.2160p.mkv"}, Duration: 7200}
	quality := qualityForVersion(item, `{"video":{"width":1920,"height":1080,"codec_name":"h264"},"duration":7200}`, 9000000)
	if quality.pixels != 1920*1080 {
		t.Fatalf("filename overrode probe: %+v", quality)
	}
	if quality.bitrate != 10000 {
		t.Fatalf("unexpected bitrate: %v", quality.bitrate)
	}
	for _, name := range []string{"Film.2160p.mkv", "Film.4K.mkv", "Film.UHD.mkv"} {
		item.FilePath = name
		if qualityForVersion(item, "", 0).pixels != 3840*2160 {
			t.Fatalf("4K fallback failed for %s", name)
		}
	}
}

func TestVersionGroupingKeepsUnknownTitlesAndEpisodeNumbersSeparate(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	items := []models.HomeMediaItem{
		{Media: models.Media{ID: 50, Type: models.TypeMovie, Title: "Same"}},
		{Media: models.Media{ID: 51, Type: models.TypeMovie, Title: "Same"}},
	}
	grouped, err := groupMediaVersions(items)
	if err != nil || len(grouped) != 2 {
		t.Fatalf("unknown movies merged: %+v %v", grouped, err)
	}
	parent := 2
	a := models.Media{ID: 1, Type: models.TypeEpisode, ParentID: &parent, EpisodeNumber: 1, SeasonNumber: 1}
	b := a
	b.ID = 2
	if versionGroupKey(a) != versionGroupKey(b) {
		t.Fatal("same episode not grouped")
	}
	b.EpisodeNumber = 2
	if versionGroupKey(a) == versionGroupKey(b) {
		t.Fatal("different episodes merged")
	}
}

func TestVersionOrderingBreaksResolutionTiesByBitrate(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	for i, size := range []int{1000000, 2000000} {
		_, err := database.DB.Exec(`INSERT INTO medias(id,type,title,tmdb_id,file_path,duration,tracks_json,file_size)
  VALUES(?,'movie','Film',42,?,100,'{"video":{"width":1920,"height":1080}}',?)`, 100+i, fmt.Sprintf("film%d.mkv", i), size)
		if err != nil {
			t.Fatal(err)
		}
	}
	versions, err := movieVersions(100, 1)
	if err != nil || len(versions) != 2 || versions[0].ID != 101 {
		t.Fatalf("unexpected quality order: %+v %v", versions, err)
	}
}

func TestSeasonEpisodesGroupVersions(t *testing.T) {
	cleanup := setupContinueWatchingTestDB(t)
	defer cleanup()
	_, err := database.DB.Exec(`UPDATE medias SET file_path='episode.1080p.mkv' WHERE type='episode';
	INSERT INTO medias(type,title,parent_id,season_number,episode_number,file_path,duration)
	SELECT type,title,parent_id,season_number,episode_number,'episode.2160p.mkv',duration FROM medias WHERE type='episode'`)
	if err != nil {
		t.Fatal(err)
	}
	var seasonID int
	database.DB.QueryRow(`SELECT id FROM medias WHERE type='season'`).Scan(&seasonID)
	w := httptest.NewRecorder()
	GetSeasonEpisodes(w, httptest.NewRequest("GET", "/api/seasons/2/episodes", nil), httprouter.Params{{Key: "id", Value: fmt.Sprint(seasonID)}}, 1)
	var items []models.HomeMediaItem
	if err := json.Unmarshal(w.Body.Bytes(), &items); err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || len(items[0].Versions) != 2 || items[0].FilePath != "episode.2160p.mkv" {
		t.Fatalf("episode versions not grouped: %+v", items)
	}
}
