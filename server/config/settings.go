package config

import (
	"database/sql"
	"log"
	"os"
	"strings"
	"sync"

	"project-player/server/database"
)

const (
	KeyMediaHubURL    = "mediahub_url"
	KeyMediaHubAPIKey = "mediahub_api_key"
	KeyTMDBAPIKey     = "tmdb_api_key"
	KeyTMDBLanguage   = "tmdb_language"
	KeyMoviesDir      = "movies_dir"
	KeySeriesDir      = "series_dir"
)

var (
	mu    sync.RWMutex
	cache map[string]string
)

func init() {
	cache = make(map[string]string)
}

// LoadCache reads all settings from SQLite into memory. Call after InitDB.
func LoadCache() {
	if database.DB == nil {
		return
	}
	rows, err := database.DB.Query(`SELECT key, value FROM app_settings`)
	if err != nil {
		log.Printf("config: failed to load settings: %v", err)
		return
	}
	defer rows.Close()

	next := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			continue
		}
		next[k] = v
	}
	mu.Lock()
	cache = next
	mu.Unlock()
	log.Printf("config: loaded %d setting(s) from database", len(next))
}

func getStored(key string) (string, bool) {
	mu.RLock()
	defer mu.RUnlock()
	v, ok := cache[key]
	if !ok {
		return "", false
	}
	v = strings.TrimSpace(v)
	if v == "" {
		return "", false
	}
	return v, true
}

func setStored(key, value string) error {
	value = strings.TrimSpace(value)
	if database.DB == nil {
		return sql.ErrConnDone
	}
	if value == "" {
		_, err := database.DB.Exec(`DELETE FROM app_settings WHERE key = ?`, key)
		if err != nil {
			return err
		}
		mu.Lock()
		delete(cache, key)
		mu.Unlock()
		return nil
	}
	_, err := database.DB.Exec(`
		INSERT INTO app_settings (key, value, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP
	`, key, value)
	if err != nil {
		return err
	}
	mu.Lock()
	cache[key] = value
	mu.Unlock()
	return nil
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		v = strings.TrimSpace(v)
		if v != "" {
			return v
		}
	}
	return fallback
}

// MediaHubURL returns persisted URL, then MEDIAHUB_URL env.
func MediaHubURL() string {
	if v, ok := getStored(KeyMediaHubURL); ok {
		return strings.TrimRight(v, "/")
	}
	return strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIAHUB_URL")), "/")
}

// MediaHubAPIKey returns persisted key, then MEDIAHUB_API_KEY env.
func MediaHubAPIKey() string {
	if v, ok := getStored(KeyMediaHubAPIKey); ok {
		return v
	}
	return strings.TrimSpace(os.Getenv("MEDIAHUB_API_KEY"))
}

func isPlaceholderTMDBKey(key string) bool {
	return key == "" ||
		key == "your_tmdb_api_key_here" ||
		key == "votre_cle_api_tmdb_ici"
}

// TMDBAPIKey returns a usable TMDB key (db → env), or empty if unset/placeholder.
func TMDBAPIKey() string {
	if v, ok := getStored(KeyTMDBAPIKey); ok && !isPlaceholderTMDBKey(v) {
		return v
	}
	key := strings.TrimSpace(os.Getenv("TMDB_API_KEY"))
	if isPlaceholderTMDBKey(key) {
		return ""
	}
	return key
}

// TMDBLanguage returns persisted language, then TMDB_LANGUAGE, then fr-FR.
func TMDBLanguage() string {
	if v, ok := getStored(KeyTMDBLanguage); ok {
		return v
	}
	lang := strings.TrimSpace(os.Getenv("TMDB_LANGUAGE"))
	if lang == "" {
		return "fr-FR"
	}
	return lang
}

// MoviesDir returns library movies path (db → env → default).
func MoviesDir() string {
	if v, ok := getStored(KeyMoviesDir); ok {
		return v
	}
	return envOr("MOVIES_DIR", "/media/Films")
}

// SeriesDir returns library series path (db → env → default).
func SeriesDir() string {
	if v, ok := getStored(KeySeriesDir); ok {
		return v
	}
	return envOr("SERIES_DIR", "/media/Series")
}

// PublicSettings is the safe API payload (secrets never returned in clear).
type PublicSettings struct {
	MediaHubURL       string `json:"mediahub_url"`
	MediaHubAPIKeySet bool   `json:"mediahub_api_key_set"`
	MediaHubAPIKeyHint string `json:"mediahub_api_key_hint,omitempty"`
	TMDBAPIKeySet     bool   `json:"tmdb_api_key_set"`
	TMDBAPIKeyHint    string `json:"tmdb_api_key_hint,omitempty"`
	TMDBLanguage      string `json:"tmdb_language"`
	MoviesDir         string `json:"movies_dir"`
	SeriesDir         string `json:"series_dir"`
}

func maskSecret(secret string) string {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return ""
	}
	if len(secret) <= 4 {
		return "••••"
	}
	return "••••" + secret[len(secret)-4:]
}

// Snapshot returns public settings for GET /api/settings.
func Snapshot() PublicSettings {
	mhKey := MediaHubAPIKey()
	tmdbKey := TMDBAPIKey()
	return PublicSettings{
		MediaHubURL:        MediaHubURL(),
		MediaHubAPIKeySet:  mhKey != "",
		MediaHubAPIKeyHint: maskSecret(mhKey),
		TMDBAPIKeySet:      tmdbKey != "",
		TMDBAPIKeyHint:     maskSecret(tmdbKey),
		TMDBLanguage:       TMDBLanguage(),
		MoviesDir:          MoviesDir(),
		SeriesDir:          SeriesDir(),
	}
}

// UpdateRequest is the PUT /api/settings body. Omitted/blank secrets keep current values.
type UpdateRequest struct {
	MediaHubURL         *string `json:"mediahub_url"`
	MediaHubAPIKey      *string `json:"mediahub_api_key"`
	ClearMediaHubAPIKey bool    `json:"clear_mediahub_api_key"`
	TMDBAPIKey          *string `json:"tmdb_api_key"`
	ClearTMDBAPIKey     bool    `json:"clear_tmdb_api_key"`
	TMDBLanguage        *string `json:"tmdb_language"`
	MoviesDir           *string `json:"movies_dir"`
	SeriesDir           *string `json:"series_dir"`
}

// ApplyUpdate persists partial updates and returns the new public snapshot.
func ApplyUpdate(req UpdateRequest) (PublicSettings, error) {
	if req.MediaHubURL != nil {
		if err := setStored(KeyMediaHubURL, strings.TrimRight(strings.TrimSpace(*req.MediaHubURL), "/")); err != nil {
			return PublicSettings{}, err
		}
	}
	if req.ClearMediaHubAPIKey {
		if err := setStored(KeyMediaHubAPIKey, ""); err != nil {
			return PublicSettings{}, err
		}
	} else if req.MediaHubAPIKey != nil && strings.TrimSpace(*req.MediaHubAPIKey) != "" {
		if err := setStored(KeyMediaHubAPIKey, *req.MediaHubAPIKey); err != nil {
			return PublicSettings{}, err
		}
	}

	if req.ClearTMDBAPIKey {
		if err := setStored(KeyTMDBAPIKey, ""); err != nil {
			return PublicSettings{}, err
		}
	} else if req.TMDBAPIKey != nil && strings.TrimSpace(*req.TMDBAPIKey) != "" {
		if err := setStored(KeyTMDBAPIKey, *req.TMDBAPIKey); err != nil {
			return PublicSettings{}, err
		}
	}

	if req.TMDBLanguage != nil {
		lang := strings.TrimSpace(*req.TMDBLanguage)
		if lang == "" {
			lang = "fr-FR"
		}
		if err := setStored(KeyTMDBLanguage, lang); err != nil {
			return PublicSettings{}, err
		}
	}
	if req.MoviesDir != nil {
		if err := setStored(KeyMoviesDir, *req.MoviesDir); err != nil {
			return PublicSettings{}, err
		}
	}
	if req.SeriesDir != nil {
		if err := setStored(KeySeriesDir, *req.SeriesDir); err != nil {
			return PublicSettings{}, err
		}
	}

	return Snapshot(), nil
}
