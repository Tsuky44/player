package models

import "time"

type MediaType string

const (
	TypeMovie   MediaType = "movie"
	TypeShow    MediaType = "show"
	TypeSeason  MediaType = "season"
	TypeEpisode MediaType = "episode"
)

// User represents a user profile
type User struct {
	ID           int    `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"` // Never expose the password hash
}

// Media represents any media entity (movie, show, season, episode)
type Media struct {
	ID          int       `json:"id"`
	Type        MediaType `json:"type"` // "movie", "show", "season", "episode"
	Title       string    `json:"title"`
	FilePath    string    `json:"file_path,omitempty"`
	Duration    int       `json:"duration,omitempty"` // in seconds
	ParentID    *int      `json:"parent_id,omitempty"` // ID of the parent (e.g., season ID for episodes, show ID for seasons)
	PosterURL   string    `json:"poster_url,omitempty"`
	Overview    string    `json:"overview,omitempty"`
	ReleaseDate string    `json:"release_date,omitempty"`
	TMDBID        int       `json:"tmdb_id,omitempty"`
	SeasonNumber  int       `json:"season_number,omitempty"`
	EpisodeNumber int       `json:"episode_number,omitempty"`
	IMDbID        string    `json:"imdb_id,omitempty"`
	IntroStart  int       `json:"intro_start"`
	IntroEnd    int       `json:"intro_end"`
	OutroStart  int       `json:"outro_start"`
	OutroEnd    int       `json:"outro_end"`
	CreatedAt   time.Time `json:"created_at"`
}

// CatalogCastMember is an actor entry fetched live from TMDB for a detail page.
type CatalogCastMember struct {
	TMDBID     int    `json:"tmdb_id,omitempty"` // TMDB person id (links to the person page)
	Name       string `json:"name"`
	Character  string `json:"character,omitempty"`
	ProfileURL string `json:"profile_url,omitempty"`
}

// CatalogItem is a lightweight movie/show reference used in filmographies and
// collections. LocalID is set (>0) when the title exists in the library.
type CatalogItem struct {
	TMDBID      int    `json:"tmdb_id"`
	LocalID     int    `json:"local_id,omitempty"`
	Title       string `json:"title"`
	PosterURL   string `json:"poster_url,omitempty"`
	BackdropURL string `json:"backdrop_url,omitempty"`
	Year        string `json:"year,omitempty"`
	MediaType   string `json:"media_type"` // "movie" | "show"
	Character   string `json:"character,omitempty"`
}

// TMDBSearchCandidate is a single result offered when manually re-matching a
// title against TMDB (poster picker).
type TMDBSearchCandidate struct {
	TMDBID    int    `json:"tmdb_id"`
	Title     string `json:"title"`
	Year      string `json:"year,omitempty"`
	Overview  string `json:"overview,omitempty"`
	PosterURL string `json:"poster_url,omitempty"`
	MediaType string `json:"media_type"` // "movie" | "show"
}

// CollectionInfo is the compact saga reference embedded in a movie's details.
type CollectionInfo struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	BackdropURL string `json:"backdrop_url,omitempty"`
	PosterURL   string `json:"poster_url,omitempty"`
}

// CollectionDetails is the full saga payload (GET /api/collection/:id).
type CollectionDetails struct {
	ID          int           `json:"id"`
	Name        string        `json:"name"`
	Overview    string        `json:"overview,omitempty"`
	BackdropURL string        `json:"backdrop_url,omitempty"`
	Parts       []CatalogItem `json:"parts"`
}

// PersonDetails is the actor/crew profile payload (GET /api/person/:id).
type PersonDetails struct {
	ID                 int           `json:"id"` // TMDB person id
	Name               string        `json:"name"`
	ProfileURL         string        `json:"profile_url,omitempty"`
	Biography          string        `json:"biography,omitempty"`
	Birthday           string        `json:"birthday,omitempty"`
	Deathday           string        `json:"deathday,omitempty"`
	PlaceOfBirth       string        `json:"place_of_birth,omitempty"`
	KnownForDepartment string        `json:"known_for_department,omitempty"`
	BackdropURL        string        `json:"backdrop_url,omitempty"`
	Filmography        []CatalogItem `json:"filmography"`
}

// CatalogCrewMember is a crew entry (director, writer…) fetched live from TMDB.
type CatalogCrewMember struct {
	Name string `json:"name"`
	Job  string `json:"job,omitempty"`
}

// MediaDetails is the rich, Emby-style detail payload returned by
// GET /api/media/:id/details. It merges the local library record (ID, poster)
// with live TMDB catalog metadata (cast, genres, rating, backdrop…).
type MediaDetails struct {
	ID            int       `json:"id"`
	TMDBID        int       `json:"tmdb_id,omitempty"`
	Type          MediaType `json:"type"`
	Title         string    `json:"title"`
	OriginalTitle string    `json:"original_title,omitempty"`
	Tagline       string    `json:"tagline,omitempty"`
	Overview      string    `json:"overview,omitempty"`
	PosterURL     string    `json:"poster_url,omitempty"`
	BackdropURL   string    `json:"backdrop_url,omitempty"`
	LogoURL       string    `json:"logo_url,omitempty"`
	FileName      string    `json:"file_name,omitempty"` // basename of the local file (movies)
	ReleaseDate   string    `json:"release_date,omitempty"`
	Runtime       int       `json:"runtime,omitempty"`  // minutes (from TMDB)
	Duration      int       `json:"duration,omitempty"` // seconds (from local file)
	Status        string    `json:"status,omitempty"`
	VoteAverage   float64   `json:"vote_average,omitempty"`
	Genres        []string  `json:"genres,omitempty"`
	Studios       []string  `json:"studios,omitempty"`
	Countries     []string  `json:"countries,omitempty"`
	OriginalLang  string    `json:"original_language,omitempty"`

	Director string   `json:"director,omitempty"`
	Writers  []string `json:"writers,omitempty"`
	Editors  []string `json:"editors,omitempty"`

	Cast      []CatalogCastMember `json:"cast,omitempty"`
	Keywords  []string            `json:"keywords,omitempty"`
	TrailerKey string             `json:"trailer_key,omitempty"` // YouTube video id
	Budget    int64               `json:"budget,omitempty"`
	Revenue   int64               `json:"revenue,omitempty"`

	Recommendations []RelatedMedia `json:"recommendations,omitempty"`
	Similar         []RelatedMedia `json:"similar,omitempty"`

	// Movies-only: the saga/collection this title belongs to (nil when none).
	Collection *CollectionInfo `json:"collection,omitempty"`

	// TV-only
	NumberOfSeasons  int `json:"number_of_seasons,omitempty"`
	NumberOfEpisodes int `json:"number_of_episodes,omitempty"`
}

// RelatedMedia is a compact TMDB title used for recommendations / similar.
type RelatedMedia struct {
	ID           int       `json:"id"`
	Type         MediaType `json:"type"`
	Title        string    `json:"title"`
	PosterURL    string    `json:"poster_url,omitempty"`
	BackdropURL  string    `json:"backdrop_url,omitempty"`
	ReleaseDate  string    `json:"release_date,omitempty"`
	VoteAverage  float64   `json:"vote_average,omitempty"`
	Overview     string    `json:"overview,omitempty"`
}

// Progression represents the user's watch progress on a media (movie/episode)
type Progression struct {
	UserID                 int       `json:"user_id"`
	MediaID                int       `json:"media_id"`
	CurrentPositionSeconds int       `json:"current_position_seconds"`
	IsFinished             bool      `json:"is_finished"`
	UpdatedAt              time.Time `json:"updated_at"`
}

// HomeResponse represents the payload returned by the GET /api/home endpoint
type HomeResponse struct {
	ContinueWatching []HomeMediaItem `json:"continue_watching"`
	RecentMovies     []Media         `json:"recent_movies"`
	RecentShows      []Media         `json:"recent_shows"`
	DiscoveryMovies  []Media         `json:"discovery_movies"`
	DiscoveryShows   []Media         `json:"discovery_shows"`
}

// HomeMediaItem is a media item decorated with watch progression details
type HomeMediaItem struct {
	Media
	CurrentPositionSeconds int       `json:"current_position_seconds"`
	Duration               int       `json:"duration"`
	IsFinished             bool      `json:"is_finished"`
	ShowTitle              string    `json:"show_title,omitempty"`
	ShowPosterURL          string    `json:"show_poster_url,omitempty"`
	ShowID                 int       `json:"show_id,omitempty"`
	EpisodeTitle           string    `json:"episode_title,omitempty"`
	UpdatedAt              time.Time `json:"updated_at"`
}
