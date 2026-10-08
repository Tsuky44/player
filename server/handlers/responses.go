package handlers

import (
	"time"

	"project-player/server/indexer"
	"project-player/server/models"
	"project-player/server/streaming"
	"project-player/server/subtitles"
)

// Les corps de réponse qui n'appartiennent à aucun domaine en particulier.
//
// Ils étaient écrits en `map[string]interface{}` à l'endroit de la réponse :
// rien ne disait quelles clés une route renvoie, une faute de frappe dans une
// clé ne se voyait qu'à l'écran, et le modèle Dart en face n'avait aucun type
// à suivre. Une struct par forme, et le garde `TestNoUntypedJSONResponses`
// pour que la suivante en soit une aussi.
//
// Aucun champ ne porte `omitempty` sans raison : une map écrivait toutes ses
// clés, valeurs nulles comprises, et les clients les lisent telles quelles.

type statusResponse struct {
	Status string `json:"status"`
}

type registeredUser struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

type registerResponse struct {
	Status  string         `json:"status"`
	Message string         `json:"message"`
	User    registeredUser `json:"user"`
}

type artifactsResponse struct {
	Artifacts []DownloadArtifact `json:"artifacts"`
}

type linkCodeResponse struct {
	Code      string `json:"code"`
	ExpiresIn int    `json:"expires_in"`
	ServerID  string `json:"server_id"`
}

type forbiddenResponse struct {
	Error              string   `json:"error"`
	MissingPermissions []string `json:"missing_permissions"`
}

type scanStatusResponse struct {
	IsScanning            bool                        `json:"is_scanning"`
	IsBackfillingMetadata bool                        `json:"is_backfilling_metadata"`
	IsRedetectingAll      bool                        `json:"is_redetecting_all"`
	RedetectAll           indexer.RedetectAllProgress `json:"redetect_all"`
	IsExtractingSubtitles bool                        `json:"is_extracting_subtitles"`
	SubtitleExtraction    subtitles.ExtractStats      `json:"subtitle_extraction"`
	LastScan              indexer.ScanReport          `json:"last_scan"`
	LibraryMonitor        indexer.MonitorStatus       `json:"library_monitor"`
}

type showDetectionResponse struct {
	ShowID  int                             `json:"show_id"`
	Seasons []indexer.SeasonDetectionResult `json:"seasons"`
	Message string                          `json:"message"`
}

type mediaReviewResponse struct {
	Count int            `json:"count"`
	Items []models.Media `json:"items"`
}

type tmdbSearchResponse struct {
	Results []models.TMDBSearchCandidate `json:"results"`
}

type showDeletedResponse struct {
	Status               string `json:"status"`
	ShowID               int    `json:"show_id"`
	ShowTitle            string `json:"show_title"`
	EpisodesRemoved      int    `json:"episodes_removed"`
	SubtitleFilesDeleted int    `json:"subtitle_files_deleted"`
	Message              string `json:"message"`
}

type episodeTimestampsResponse struct {
	MediaID    int `json:"media_id"`
	IntroStart int `json:"intro_start"`
	IntroEnd   int `json:"intro_end"`
	OutroStart int `json:"outro_start"`
	OutroEnd   int `json:"outro_end"`
}

type chaptersResponse struct {
	Chapters []streaming.Chapter `json:"chapters"`
}

type mediaTracksResponse struct {
	Video     *streaming.VideoStreamInfo  `json:"video"`
	Audio     []streaming.AudioStreamInfo `json:"audio"`
	Subtitles []interface{}               `json:"subtitles"`
	Qualities []streaming.QualityTier     `json:"qualities"`
}

type playbackTicketResponse struct {
	Ticket            string    `json:"ticket"`
	ExpiresAt         time.Time `json:"expires_at"`
	RenewAfterSeconds int       `json:"renew_after_seconds"`
}

type playbackTicketRenewal struct {
	ExpiresAt time.Time `json:"expires_at"`
}

type progressSavedResponse struct {
	Status     string `json:"status"`
	IsFinished bool   `json:"is_finished"`
}

type watchedResponse struct {
	Status                 string `json:"status"`
	IsFinished             bool   `json:"is_finished"`
	CurrentPositionSeconds int    `json:"current_position_seconds"`
}

type watchedBatchResponse struct {
	Status  string              `json:"status"`
	Watched bool                `json:"watched"`
	Updated []watchedBatchEntry `json:"updated"`
}

type progressResponse struct {
	CurrentPositionSeconds int  `json:"current_position_seconds"`
	IsFinished             bool `json:"is_finished"`
}

// resumeEpisodeResponse : sans épisode à reprendre, seule `has_episode` part.
type resumeEpisodeResponse struct {
	HasEpisode bool                  `json:"has_episode"`
	SeasonID   *int                  `json:"season_id,omitempty"`
	Episode    *models.HomeMediaItem `json:"episode,omitempty"`
}

// nextEpisodeResponse : `episode` n'existe que si `has_next`, et les deux
// cartes de fin (saison à demander, épisode à venir) seulement quand elles ont
// quelque chose à proposer. L'app distingue une clé absente d'une carte vide.
type nextEpisodeResponse struct {
	HasNext         bool                    `json:"has_next"`
	Episode         *models.HomeMediaItem   `json:"episode,omitempty"`
	NextSeason      *nextSeasonPayload      `json:"next_season,omitempty"`
	UpcomingEpisode *upcomingEpisodePayload `json:"upcoming_episode,omitempty"`
}

type subtitleExtractionResponse struct {
	Status    string            `json:"status"`
	MediaID   int               `json:"media_id"`
	Tracks    int               `json:"tracks"`
	Subtitles []subtitles.Track `json:"subtitles"`
}

// requestRelatedItem est un titre voisin dans le catalogue des demandes.
type requestRelatedItem struct {
	ID           int     `json:"id"`
	MediaType    string  `json:"mediaType"`
	Title        string  `json:"title"`
	Overview     string  `json:"overview"`
	PosterPath   string  `json:"posterPath"`
	BackdropPath string  `json:"backdropPath"`
	ReleaseDate  string  `json:"releaseDate"`
	Rating       float64 `json:"rating"`
	Status       string  `json:"status"`
}

type requestCatalogResponse struct {
	Page       int           `json:"page"`
	TotalPages int           `json:"totalPages"`
	Results    []catalogItem `json:"results"`
}
