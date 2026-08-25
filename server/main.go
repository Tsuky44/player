package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/handlers"
	"project-player/server/indexer"
	"project-player/server/middleware"
	"project-player/server/models"
	"project-player/server/streaming"
	"project-player/server/webui"

	"github.com/julienschmidt/httprouter"
)

func main() {
	port := flag.String("port", "8080", "Port to run the server on")
	dbPath := flag.String("db", "./data/player.db", "Path to SQLite database file")
	scanOnStartup := flag.Bool("scan-startup", true, "Trigger a media scan on startup")
	flag.Parse()

	log.Println("Starting Project Player Media Server...")

	// Resolve database path
	absDbPath, err := filepath.Abs(*dbPath)
	if err != nil {
		log.Fatalf("Failed to resolve database path: %v", err)
	}

	// Initialize database
	db, err := database.InitDB(absDbPath)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()
	config.LoadCache()

	if err := handlers.InitStream(); err != nil {
		log.Fatalf("Failed to initialize stream handler: %v", err)
	}

	// Expired login tokens used to live forever. Sweep them in the background;
	// RequireAuth rejects them on read either way.
	handlers.StartSessionReaper()

	// Unclaimed TV pairing codes are short-lived; sweep the dead rows.
	handlers.StartDevicePairingReaper()

	// Initialize router
	router := httprouter.New()

	// Global middleware: CORS on the outside, then gzip for the JSON API.
	handler := middleware.Gzip(router)
	corsRouter := setupCORS(handler)

	// Base API route
	router.GET("/api/ping", func(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status": "ok", "message": "Project Player Server is running"}`))
	})

	// Intro/outro inspection and forced re-detection. These were open to anyone
	// "for easier debugging", which made detect-show a free way for an
	// unauthenticated caller to pin the CPU: it runs ffprobe over every episode
	// of a season. They read and rewrite library metadata, so manage_library is
	// the permission that matches what they do.
	router.GET("/api/debug/intro-outro", handlers.RequirePermission(models.PermManageLibrary, handlers.DebugIntroOutro))
	router.POST("/api/debug/detect-show/:id", handlers.RequirePermission(models.PermManageLibrary, handlers.DetectShowIntroOutro))

	// 1. Authentication Routes
	// Register is not open sign-up: it only succeeds on a pristine server (that
	// account becomes the owner) or with a valid invitation token.
	router.POST("/api/auth/register", handlers.Register)
	router.GET("/api/auth/state", handlers.GetAuthState)
	router.POST("/api/auth/login", handlers.Login)
	router.POST("/api/auth/logout", handlers.Logout)
	router.GET("/api/auth/me", handlers.RequireAuth(handlers.Me))
	router.POST("/api/auth/password", handlers.RequireAuth(handlers.ChangePassword))

	// TV pairing (RFC 8628-shaped device flow). start/poll are unauthenticated
	// because the caller is a television that has no account yet; both only ever
	// speak in random codes, and nothing is minted until a signed-in phone
	// approves. approve/deny run as the user whose account the TV inherits.
	router.POST("/api/auth/device/start", handlers.StartDevicePairing)
	router.POST("/api/auth/device/poll", handlers.PollDevicePairing)
	router.GET("/api/auth/device/pending", handlers.RequireAuth(handlers.LookupDevicePairing))
	router.POST("/api/auth/device/approve", handlers.RequireAuth(handlers.ApproveDevicePairing))
	router.POST("/api/auth/device/deny", handlers.RequireAuth(handlers.DenyDevicePairing))
	// Direct linking: the phone mints a session for a television that never
	// reached this server, and delivers it over the local network itself.
	router.POST("/api/auth/device/session", handlers.RequireAuth(handlers.CreateDeviceSession))

	// User administration & invitations (lot A).
	router.GET("/api/users", handlers.RequirePermission(models.PermManageUsers, handlers.ListUsers))
	router.PUT("/api/users/:id/permissions", handlers.RequirePermission(models.PermManageUsers, handlers.UpdateUserPermissions))
	router.POST("/api/users/:id/password", handlers.RequirePermission(models.PermManageUsers, handlers.ResetUserPassword))
	router.DELETE("/api/users/:id", handlers.RequirePermission(models.PermManageUsers, handlers.DeleteUser))
	// Ownership transfer is owner-only; the handler checks that itself.
	router.POST("/api/users/:id/transfer-ownership", handlers.RequirePermission(models.PermManageUsers, handlers.TransferOwnership))

	// Invitations: invite_users is enough. Holding manage_users widens the list
	// from "my links" to "every link", inside the handlers.
	invitePerms := []models.Permission{models.PermInviteUsers, models.PermManageUsers}
	router.GET("/api/invitations", handlers.RequireAnyPermission(invitePerms, handlers.ListInvitations))
	router.POST("/api/invitations", handlers.RequireAnyPermission(invitePerms, handlers.CreateInvitation))
	router.DELETE("/api/invitations/:token", handlers.RequireAnyPermission(invitePerms, handlers.RevokeInvitation))

	// Settings (MediaHub, TMDB, library paths). Reading is fine for any account;
	// writing rewrites API keys and library paths, so it needs manage_settings.
	// GET is gated too: the snapshot exposes MoviesDir/SeriesDir, i.e. the
	// server's disk layout, and no other screen consumes it.
	router.GET("/api/settings", handlers.RequirePermission(models.PermManageSettings, handlers.GetSettings))
	router.PUT("/api/settings", handlers.RequirePermission(models.PermManageSettings, handlers.UpdateSettings))

	// Player Studio layouts (per-user, synced across devices)
	router.GET("/api/me/player-layouts", handlers.RequireAuth(handlers.ListPlayerLayouts))
	router.POST("/api/me/player-layouts", handlers.RequireAuth(handlers.CreatePlayerLayout))
	router.PUT("/api/me/player-layouts/:id", handlers.RequireAuth(handlers.UpdatePlayerLayout))
	router.DELETE("/api/me/player-layouts/:id", handlers.RequireAuth(handlers.DeletePlayerLayout))

	// 2. Dashboard & Progress Routes
	router.GET("/api/home", handlers.RequireAuth(handlers.Home))
	router.GET("/api/progress", handlers.RequireAuth(handlers.GetProgress))
	router.POST("/api/progress", handlers.RequireAuth(handlers.UpdateProgress))
	router.POST("/api/continue-watching/hide", handlers.RequireAuth(handlers.HideFromContinueWatching))
	router.POST("/api/media/:id/watched", handlers.RequireAuth(handlers.SetMediaWatched))

	// 3. Media Browsing Routes
	router.GET("/api/movies", handlers.RequireAuth(handlers.GetMovies))
	router.GET("/api/shows", handlers.RequireAuth(handlers.GetShows))
	router.GET("/api/shows/:id/seasons", handlers.RequireAuth(handlers.GetShowSeasons))
	router.GET("/api/shows/:id/seasons/:num/episodes", handlers.RequireAuth(handlers.GetShowSeasonEpisodes))
	router.GET("/api/shows/:id/resume", handlers.RequireAuth(handlers.GetShowResumeEpisode))
	router.GET("/api/seasons/:id/episodes", handlers.RequireAuth(handlers.GetSeasonEpisodes))
	router.GET("/api/episodes/:id/next", handlers.RequireAuth(handlers.GetNextEpisode))
	router.GET("/api/episodes/:id/timestamps", handlers.RequireAuth(handlers.GetEpisodeTimestamps))
	router.GET("/api/episodes/:id/chapters", handlers.RequireAuth(handlers.GetEpisodeChapters))
	router.GET("/api/media/:id/tracks", handlers.RequireAuth(handlers.GetMediaTracks))
	router.GET("/api/media/:id/details", handlers.RequireAuth(handlers.GetMediaDetails))
	router.GET("/api/person/:id", handlers.RequireAuth(handlers.GetPersonDetails))
	router.GET("/api/collection/:id", handlers.RequireAuth(handlers.GetCollectionDetails))
	// Browsing the request catalog is part of request_media: an account that may
	// not ask for a title has no use for the catalog either.
	router.GET("/api/requests/catalog", handlers.RequirePermission(models.PermRequestMedia, handlers.TmdbRequestCatalog))
	router.GET("/api/requests/filter-options", handlers.RequirePermission(models.PermRequestMedia, handlers.TmdbRequestFilterOptions))
	router.GET("/api/requests/watch-providers", handlers.RequirePermission(models.PermRequestMedia, handlers.TmdbRequestWatchProviders))
	router.GET("/api/requests/media/:id/seasons/:num/episodes", handlers.RequirePermission(models.PermRequestMedia, handlers.TmdbRequestSeasonEpisodes))
	router.GET("/api/requests/media/:id", handlers.RequirePermission(models.PermRequestMedia, handlers.TmdbRequestDetails))
	router.POST("/api/requests", handlers.RequirePermission(models.PermRequestMedia, handlers.MediaHubRequest))

	// External subtitles (sidecar files or OpenSubtitles downloads), served as
	// WebVTT. Unauthenticated so media_kit/mpv can fetch the track directly.
	router.GET("/api/v1/media/:id/subtitles", handlers.GetMediaSubtitle)
	router.OPTIONS("/api/v1/media/:id/subtitles", handlers.GetMediaSubtitle)
	// Preferred form: URL ends in ".vtt" so libmpv detects the subtitle parser.
	router.GET("/api/v1/media/:id/subtitles/:file", handlers.GetMediaSubtitle)
	router.OPTIONS("/api/v1/media/:id/subtitles/:file", handlers.GetMediaSubtitle)

	// 4. Indexer Scan Routes — all behind manage_library.
	router.POST("/api/indexer/scan", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerScan))
	router.POST("/api/indexer/dedupe", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerShowDedupe))
	router.POST("/api/indexer/metadata/backfill", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerMetadataBackfill))
	router.POST("/api/indexer/metadata/redetect-all", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerRedetectAll))
	router.POST("/api/indexer/probe/backfill", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerProbeBackfill))
	router.POST("/api/media/:id/metadata/enrich", handlers.RequirePermission(models.PermManageLibrary, handlers.EnrichMediaMetadata))
	router.POST("/api/media/:id/metadata/redetect", handlers.RequirePermission(models.PermManageLibrary, handlers.RedetectMediaMetadata))
	router.POST("/api/media/:id/metadata/rematch", handlers.RequirePermission(models.PermManageLibrary, handlers.RematchMediaMetadata))
	router.GET("/api/tmdb/search", handlers.RequirePermission(models.PermManageLibrary, handlers.SearchTMDBMetadata))
	router.POST("/api/indexer/subtitles/extract", handlers.RequirePermission(models.PermManageLibrary, handlers.TriggerSubtitleExtract))
	// Scan status is read-only progress, shown wherever a scan can be watched.
	router.GET("/api/indexer/status", handlers.RequireAuth(handlers.GetScanStatus))
	// Detailed scan accounting (skipped files, unmatched items) for library admins.
	router.GET("/api/indexer/report", handlers.RequirePermission(models.PermManageLibrary, handlers.GetScanReport))
	router.POST("/api/media/:id/subtitles/extract", handlers.RequirePermission(models.PermManageLibrary, handlers.ForceMediaSubtitleExtract))

	// Delete a show and all its data (episodes, subtitles). Formerly unauthenticated
	// as a re-index debug helper: it is the most destructive route on the server,
	// so it now sits behind delete_media like any other deletion.
	router.POST("/api/indexer/debug/delete-show", handlers.RequirePermission(models.PermDeleteMedia, handlers.DebugDeleteShow))
	router.POST("/api/indexer/debug/delete-show/:id", handlers.RequirePermission(models.PermDeleteMedia, handlers.DebugDeleteShow))

	// Client apps (APK / DMG / EXE) baked into the image by publish-image.sh.
	// Unauthenticated: this is how a new user gets the app before they have an
	// account, and a browser download cannot carry an Authorization header.
	router.GET("/api/downloads", handlers.ListDownloads)
	router.GET("/api/downloads/:file", handlers.ServeDownload)
	// Download managers probe with HEAD before starting a 100 MB transfer.
	router.HEAD("/api/downloads/:file", handlers.ServeDownload)
	// Publishing the installers this server hands out is server administration.
	router.POST("/api/downloads", handlers.RequirePermission(models.PermManageSettings, handlers.UploadDownload))
	router.DELETE("/api/downloads/:file", handlers.RequirePermission(models.PermManageSettings, handlers.DeleteDownload))

	// 5. Streaming Endpoint (Unauthenticated for video player compatibility)
	router.GET("/stream", handlers.StreamMedia)

	// 6. HLS Transcoding + Subtitle Endpoints (Unauthenticated for media_kit / mpv
	// compatibility — the player fetches playlists, segments and WebVTT directly).
	// Dispatch parses the path manually to avoid httprouter wildcard conflicts.
	hlsHandler := streaming.NewHandler(db)
	router.POST("/api/v1/stream/*path", hlsHandler.Dispatch)
	router.GET("/api/v1/stream/*path", hlsHandler.Dispatch)
	router.DELETE("/api/v1/stream/*path", hlsHandler.Dispatch)
	router.OPTIONS("/api/v1/stream/*path", hlsHandler.Dispatch)

	// 7. Web UI — the Flutter bundle embedded in the binary. Registered as the
	// router's NotFound handler so it picks up every path the API did not claim,
	// which is what lets client-side routes survive a reload or a shared link.
	if webui.Available() {
		webHandler, err := webui.New()
		if err != nil {
			log.Fatalf("Failed to initialize web UI: %v", err)
		}
		router.NotFound = webHandler
	} else {
		log.Println("WebUI: no bundle embedded — run scripts/build-web.sh before building to serve the web client.")
	}

	// Trigger startup scan if configured
	if *scanOnStartup {
		moviesDir := config.MoviesDir()
		seriesDir := config.SeriesDir()
		log.Printf("Triggering startup scan on: Movies=%s, Series=%s", moviesDir, seriesDir)
		indexer.ScanMedia(moviesDir, seriesDir)
	} else if config.TMDBAPIKey() != "" {
		indexer.BackfillMissingMetadataAsync()
		indexer.BackfillMissingProbesAsync()
	}

	if config.TMDBAPIKey() == "" {
		log.Println("WARNING: TMDB API key is not set — movie/show posters will not be fetched.")
		log.Println("         Configure it in Paramètres, or set TMDB_API_KEY in the environment.")
	}

	// Create data directory if it doesn't exist
	if err := os.MkdirAll("./data", 0755); err != nil {
		log.Printf("Warning: failed to create data directory: %v", err)
	}

	// Start server with generous timeouts for large Range responses.
	addr := ":" + *port
	log.Printf("Server listening on http://localhost%s", addr)
	server := &http.Server{
		Addr:         addr,
		Handler:      corsRouter,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0, // no write deadline — long video ranges
		IdleTimeout:  120 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}

// setupCORS wraps the handler chain to inject general CORS headers for all requests
func setupCORS(router http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, PUT, DELETE")
		w.Header().Set("Access-Control-Allow-Headers", "Accept, Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization")

		// Handle preflight OPTIONS request
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		router.ServeHTTP(w, r)
	})
}
