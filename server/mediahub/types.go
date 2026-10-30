package mediahub

// Les messages de l'API d'intégration v1 de MediaHub, tels qu'Onyx les lit.
// Les exemples réels sont épinglés dans contract/mediahub/ (ADR-0089).

// Waiting dit, en français et prêt à afficher, pourquoi rien ne se télécharge
// encore. MediaHub donne la date de sortie attendue ; OnyxHub donnait l'heure
// de la prochaine tentative.
type Waiting struct {
	Message       string `json:"message"`
	ReleaseDate   string `json:"releaseDate,omitempty"`
	NextAttemptAt string `json:"nextAttemptAt,omitempty"`
}

// SeasonAvailability est l'état d'une saison d'une série.
type SeasonAvailability struct {
	SeasonNumber  int    `json:"seasonNumber"`
	Status        string `json:"status"`
	TotalEpisodes int    `json:"totalEpisodes,omitempty"`
}

// Availability est la disponibilité d'un titre (GET /availability/:id).
type Availability struct {
	Status          string               `json:"status"`
	AwaitingRelease bool                 `json:"awaitingRelease"`
	Waiting         *Waiting             `json:"waiting,omitempty"`
	Seasons         []SeasonAvailability `json:"seasons"`
}

// BatchItem désigne un titre dans un lot de disponibilités.
type BatchItem struct {
	TMDBID    int    `json:"tmdbId"`
	MediaType string `json:"mediaType"`
}

type batchRequest struct {
	Items []BatchItem `json:"items"`
}

type batchResponse struct {
	Results []struct {
		TMDBID    int    `json:"tmdbId"`
		MediaType string `json:"mediaType"`
		Status    string `json:"status"`
	} `json:"results"`
}

// Request est une ligne de demande MediaHub : un film, ou une saison d'une
// série (MediaHub écrit une ligne par saison).
type Request struct {
	ID              int      `json:"id"`
	MediaType       string   `json:"mediaType"`
	TMDBID          int      `json:"tmdbId"`
	Title           string   `json:"title"`
	PosterPath      *string  `json:"posterPath"`
	Seasons         []int    `json:"seasons"`
	Status          string   `json:"status"`
	RequestedAt     string   `json:"requestedAt"`
	UpdatedAt       string   `json:"updatedAt"`
	Progress        *float64 `json:"progress"`
	AwaitingRelease bool     `json:"awaitingRelease"`
	Waiting         *Waiting `json:"waiting"`
	Note            *string  `json:"note"`
	Requester       string   `json:"requester,omitempty"`
}

type requestList struct {
	Requests   []Request `json:"requests"`
	NextBefore *int      `json:"nextBefore"`
}

type requestFeed struct {
	Cursor   int       `json:"cursor"`
	Requests []Request `json:"requests"`
}

// Abilities sont les droits du compte MediaHub relié au compte Onyx.
type Abilities struct {
	Read            bool `json:"read"`
	Request         bool `json:"request"`
	ReadAllRequests bool `json:"readAllRequests"`
	Moderate        bool `json:"moderate"`
	Delete          bool `json:"delete"`
	// InteractiveSearch : choisir soi-même la release d'une saison ou d'un
	// épisode (ADR-0098). Absent chez un MediaHub d'avant la route.
	InteractiveSearch bool `json:"interactiveSearch"`
}

// PingUser est le compte MediaHub retrouvé par X-Player-Username.
type PingUser struct {
	Linked bool      `json:"linked"`
	ID     int       `json:"id"`
	Name   string    `json:"name"`
	Role   string    `json:"role"`
	Can    Abilities `json:"can"`
}

// Ping est la réponse de GET /ping, qui vérifie la clé.
type Ping struct {
	Status            string    `json:"status"`
	Service           string    `json:"service"`
	Version           string    `json:"version"`
	APIVersion        int       `json:"apiVersion"`
	Features          []string  `json:"features"`
	WebhookConfigured bool      `json:"webhookConfigured"`
	User              *PingUser `json:"user"`
}
