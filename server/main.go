package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"project-player/server/database"
	"project-player/server/handlers"
	"project-player/server/indexer"
	"project-player/server/streaming"

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

	// Initialize router
	router := httprouter.New()

	// Global CORS middleware helper
	corsRouter := setupCORS(router)

	// Base API route
	router.GET("/api/ping", func(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status": "ok", "message": "Project Player Server is running"}`))
	})

	// Debug endpoint to check intro/outro data (no auth for easier debugging)
	router.GET("/api/debug/intro-outro", handlers.DebugIntroOutro)
	router.POST("/api/debug/detect-show/:id", handlers.DetectShowIntroOutro)

	// 1. Authentication Routes
	router.POST("/api/auth/register", handlers.Register)
	router.POST("/api/auth/login", handlers.Login)
	router.POST("/api/auth/logout", handlers.Logout)
	router.GET("/api/auth/me", handlers.RequireAuth(handlers.Me))

	// 2. Dashboard & Progress Routes
	router.GET("/api/home", handlers.RequireAuth(handlers.Home))
	router.GET("/api/progress", handlers.RequireAuth(handlers.GetProgress))
	router.POST("/api/progress", handlers.RequireAuth(handlers.UpdateProgress))

	// 3. Media Browsing Routes
	router.GET("/api/movies", handlers.RequireAuth(handlers.GetMovies))
	router.GET("/api/shows", handlers.RequireAuth(handlers.GetShows))
	router.GET("/api/shows/:id/seasons", handlers.RequireAuth(handlers.GetShowSeasons))
	router.GET("/api/seasons/:id/episodes", handlers.RequireAuth(handlers.GetSeasonEpisodes))
	router.GET("/api/episodes/:id/next", handlers.RequireAuth(handlers.GetNextEpisode))
	router.GET("/api/episodes/:id/timestamps", handlers.RequireAuth(handlers.GetEpisodeTimestamps))
	router.GET("/api/episodes/:id/chapters", handlers.RequireAuth(handlers.GetEpisodeChapters))

	// 4. Indexer Scan Routes
	router.POST("/api/indexer/scan", handlers.RequireAuth(handlers.TriggerScan))
	router.GET("/api/indexer/status", handlers.RequireAuth(handlers.GetScanStatus))

	// 5. Streaming Endpoint (Unauthenticated for video player compatibility)
	router.GET("/stream", handlers.StreamMedia)

	// 6. HLS Transcoding Endpoints (Unauthenticated for media_kit compatibility)
	// Single catch-all route — Dispatch parses the path manually to avoid httprouter conflicts.
	hlsHandler := streaming.NewHandler(db)
	router.GET("/api/v1/stream/*path", hlsHandler.Dispatch)
	router.DELETE("/api/v1/stream/*path", hlsHandler.Dispatch)

	// Trigger startup scan if configured
	if *scanOnStartup {
		moviesDir := getEnv("MOVIES_DIR", "/media/Films")
		seriesDir := getEnv("SERIES_DIR", "/media/Series")
		log.Printf("Triggering startup scan on: Movies=%s, Series=%s", moviesDir, seriesDir)
		indexer.ScanMedia(moviesDir, seriesDir)
	}

	// Create data directory if it doesn't exist
	if err := os.MkdirAll("./data", 0755); err != nil {
		log.Printf("Warning: failed to create data directory: %v", err)
	}

	// Start server
	addr := ":" + *port
	log.Printf("Server listening on http://localhost%s", addr)
	if err := http.ListenAndServe(addr, corsRouter); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}

// setupCORS wraps the httprouter to inject general CORS headers for all requests
func setupCORS(router *httprouter.Router) http.Handler {
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

// Helper to get environment variables with default values
func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}
