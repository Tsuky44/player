package models

import (
	"strings"
	"time"
)

type MediaType string

const (
	TypeMovie   MediaType = "movie"
	TypeShow    MediaType = "show"
	TypeSeason  MediaType = "season"
	TypeEpisode MediaType = "episode"
)

// Permissions is the fixed set of administration rights carried by a user
// (lot A). Content access — which libraries a user may see, downloads, parental
// controls — is deliberately out of scope here and lands in lot B.
type Permissions struct {
	ManageSettings bool `json:"manage_settings"`
	ManageLibrary  bool `json:"manage_library"`
	ManageUsers    bool `json:"manage_users"`
	DeleteMedia    bool `json:"delete_media"`
	InviteUsers    bool `json:"invite_users"`
	RequestMedia   bool `json:"request_media"`
}

// DefaultPermissions is what a freshly created account gets: it may ask for
// media, nothing else.
func DefaultPermissions() Permissions {
	return Permissions{RequestMedia: true}
}

// AllPermissions is the "admin" shortcut — the UI checkbox that ticks
// everything. Ownership itself is not a permission.
func AllPermissions() Permissions {
	return Permissions{
		ManageSettings: true,
		ManageLibrary:  true,
		ManageUsers:    true,
		DeleteMedia:    true,
		InviteUsers:    true,
		RequestMedia:   true,
	}
}

// IsAdmin reports whether the user holds every administration right. It is a
// display convenience only — every guard checks a specific permission.
func (p Permissions) IsAdmin() bool {
	return p == AllPermissions()
}

// Permission names a single right, used by the RequirePermission middleware and
// as the wire format for invitation templates.
type Permission string

const (
	PermManageSettings Permission = "manage_settings"
	PermManageLibrary  Permission = "manage_library"
	PermManageUsers    Permission = "manage_users"
	PermDeleteMedia    Permission = "delete_media"
	PermInviteUsers    Permission = "invite_users"
	PermRequestMedia   Permission = "request_media"
)

// Has reports whether the set grants perm. An unknown name is never granted.
func (p Permissions) Has(perm Permission) bool {
	switch perm {
	case PermManageSettings:
		return p.ManageSettings
	case PermManageLibrary:
		return p.ManageLibrary
	case PermManageUsers:
		return p.ManageUsers
	case PermDeleteMedia:
		return p.DeleteMedia
	case PermInviteUsers:
		return p.InviteUsers
	case PermRequestMedia:
		return p.RequestMedia
	default:
		return false
	}
}

// EncodePermissions serialises a set as a comma-separated list, the storage
// format for a frozen invitation template.
func EncodePermissions(p Permissions) string {
	var granted []string
	for _, perm := range []Permission{
		PermManageSettings, PermManageLibrary, PermManageUsers,
		PermDeleteMedia, PermInviteUsers, PermRequestMedia,
	} {
		if p.Has(perm) {
			granted = append(granted, string(perm))
		}
	}
	return strings.Join(granted, ",")
}

// DecodePermissions reads back EncodePermissions. Unknown names are ignored, so
// removing a permission in a later version degrades rather than fails.
func DecodePermissions(raw string) Permissions {
	var p Permissions
	for _, name := range strings.Split(raw, ",") {
		switch Permission(strings.TrimSpace(name)) {
		case PermManageSettings:
			p.ManageSettings = true
		case PermManageLibrary:
			p.ManageLibrary = true
		case PermManageUsers:
			p.ManageUsers = true
		case PermDeleteMedia:
			p.DeleteMedia = true
		case PermInviteUsers:
			p.InviteUsers = true
		case PermRequestMedia:
			p.RequestMedia = true
		}
	}
	return p
}

// User represents a user profile
type User struct {
	ID           int    `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"` // Never expose the password hash
	IsOwner      bool   `json:"is_owner"`
	// Permissions is what this account may do.
	Permissions Permissions `json:"permissions"`
	// InviteGrants is the template applied to accounts created through this
	// user's invitation links. Meaningless unless Permissions.InviteUsers.
	InviteGrants Permissions `json:"invite_grants"`
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
	// TMDB vote average (0 when unknown), shown as ★ on catalog poster cards.
	Rating float64 `json:"rating,omitempty"`
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
	FileName         string    `json:"file_name,omitempty"`          // movies: local file basename
	LocalFolder      string    `json:"local_folder,omitempty"`       // shows: series folder on disk
	LocalEpisodeFile string    `json:"local_episode_file,omitempty"` // shows: sample episode filename
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
	// HasNewEpisode marks a series whose resume episode is a freshly released
	// one — the weekly drop the user has not watched yet. Continue watching
	// only.
	HasNewEpisode bool `json:"has_new_episode,omitempty"`
}
