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
	TMDBID      int       `json:"tmdb_id,omitempty"`
	IMDbID      string    `json:"imdb_id,omitempty"`
	IntroStart  int       `json:"intro_start"`
	IntroEnd    int       `json:"intro_end"`
	OutroStart  int       `json:"outro_start"`
	OutroEnd    int       `json:"outro_end"`
	CreatedAt   time.Time `json:"created_at"`
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
}

// HomeMediaItem is a media item decorated with watch progression details
type HomeMediaItem struct {
	Media
	CurrentPositionSeconds int  `json:"current_position_seconds"`
	Duration               int  `json:"duration"`
	IsFinished             bool `json:"is_finished"`
}
