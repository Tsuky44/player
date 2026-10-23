package indexer

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"project-player/server/database"
	"project-player/server/safego"
	"project-player/server/streaming"
)

// ChapterItem represents a simplified chapter structure
type ChapterItem struct {
	ID        int     `json:"id"`
	StartTime float64 `json:"start_time"`
	EndTime   float64 `json:"end_time"`
	Title     string  `json:"title"`
}

// Keywords for matching intro and outro chapters (multi-word only; short tokens
// like "op"/"ed" use exact-token matching to avoid false positives).
//
// Un récap n'est pas une intro : rangé comme tel, un chapitre « Recap » qui
// ouvre l'épisode prenait la place de la vraie intro, et le client sautait le
// récap puis laissait passer l'intro. Le client propose le récap à part, d'après
// les chapitres.
var introKeywords = []string{
	"intro", "opening",
	"generique de debut", "generique debut",
}
var outroKeywords = []string{
	"outro", "ending", "crédits",
	"generique de fin", "generique fin", "generique de fin",
}

// isOpeningCreditsChapter matches the usual opening-credits chapter titles.
func isOpeningCreditsChapter(normTitle string) bool {
	if normTitle == "" {
		return false
	}
	if strings.Contains(normTitle, "opencreditstart") || strings.Contains(normTitle, "open_credit_start") {
		return true
	}
	if strings.Contains(normTitle, "open") && strings.Contains(normTitle, "credit") && strings.Contains(normTitle, "start") {
		return true
	}
	if strings.Contains(normTitle, "opening") && strings.Contains(normTitle, "credit") {
		return true
	}
	return false
}

// isClosingCreditsChapter matches end-credit chapters without false positives on
// openCreditStart / openCreditEnd style names.
func isClosingCreditsChapter(normTitle string) bool {
	if normTitle == "" {
		return false
	}
	if isOpeningCreditsChapter(normTitle) {
		return false
	}
	if strings.Contains(normTitle, "open") && strings.Contains(normTitle, "credit") {
		return false
	}
	if normTitle == "credits" || normTitle == "credit" {
		return true
	}
	if strings.Contains(normTitle, "credits") {
		return true
	}
	return false
}

// IsPlausibleIntroRange rejects chapter/DB values that span most of an episode.
func IsPlausibleIntroRange(start, end, mediaDuration int) bool {
	if end <= start || end <= 0 {
		return false
	}
	if end-start > 600 {
		return false
	}
	if mediaDuration > 0 && end > int(float64(mediaDuration)*0.85) {
		return false
	}
	return true
}

func titleMatchesKeyword(normTitle, keyword string) bool {
	if keyword == "op" || keyword == "ed" {
		if normTitle == keyword {
			return true
		}
		return strings.HasPrefix(normTitle, keyword+" ") || strings.HasSuffix(normTitle, " "+keyword)
	}
	return strings.Contains(normTitle, keyword)
}

// ChapterTitleMatchesIntro detects intro chapter titles from MKV metadata.
func ChapterTitleMatchesIntro(title string) bool {
	normTitle := normalizeString(title)
	if normTitle == "" {
		return false
	}
	if isOpeningCreditsChapter(normTitle) {
		return true
	}
	for _, kw := range introKeywords {
		if titleMatchesKeyword(normTitle, kw) {
			return true
		}
	}
	return titleMatchesKeyword(normTitle, "op")
}

// ChapterTitleMatchesOutro detects outro/credits chapter titles from MKV metadata.
func ChapterTitleMatchesOutro(title string) bool {
	normTitle := normalizeString(title)
	if normTitle == "" {
		return false
	}
	if isClosingCreditsChapter(normTitle) {
		return true
	}
	for _, kw := range outroKeywords {
		if titleMatchesKeyword(normTitle, kw) {
			return true
		}
	}
	return titleMatchesKeyword(normTitle, "ed")
}

// Normalize string for keyword matching
func normalizeString(s string) string {
	s = strings.ToLower(s)
	// Simple accent stripping
	replacer := strings.NewReplacer(
		"é", "e", "è", "e", "ê", "e", "ë", "e",
		"à", "a", "â", "a", "ä", "a",
		"î", "i", "ï", "i",
		"ô", "o", "ö", "o",
		"û", "u", "ü", "u", "ù", "u",
		"ç", "c",
	)
	s = replacer.Replace(s)
	return strings.TrimSpace(s)
}

// DetectFromChapters attempts to discover intro/outro points using video chapters
func DetectFromChapters(episodeID int, filePath string) (bool, error) {
	if filePath == "" {
		return false, fmt.Errorf("empty file path")
	}

	chapters, err := streaming.ProbeChapters(filePath)
	if err != nil {
		return false, err
	}
	if len(chapters) == 0 {
		return false, nil // No chapters found
	}

	var introStart, introEnd, outroStart, outroEnd int
	foundIntro := false
	foundOutro := false

	for _, c := range chapters {
		start, end, title := c.StartTime, c.EndTime, c.Title
		if title == "" {
			continue
		}

		iStart := int(start)
		iEnd := int(end)

		if ChapterTitleMatchesIntro(title) {
			if !foundIntro || iStart < introStart {
				if IsPlausibleIntroRange(iStart, iEnd, 0) {
					introStart = iStart
					introEnd = iEnd
					foundIntro = true
				}
			}
		}

		if ChapterTitleMatchesOutro(title) {
			if !foundOutro || iStart > outroStart {
				outroStart = iStart
				outroEnd = iEnd
				foundOutro = true
			}
		}
	}

	if foundIntro || foundOutro {
		var current EpisodeMarkers
		_ = database.DB.QueryRow(
			"SELECT intro_start, intro_end, outro_start, outro_end FROM medias WHERE id = ?", episodeID,
		).Scan(&current.IntroStart, &current.IntroEnd, &current.OutroStart, &current.OutroEnd)

		// Les chapitres l'emportent sur ce qui est déjà en base ; ce qu'ils ne
		// nomment pas reste tel quel.
		merged := FillMissingMarkers(EpisodeMarkers{
			IntroStart: introStart, IntroEnd: introEnd,
			OutroStart: outroStart, OutroEnd: outroEnd,
		}, current)
		_, err := database.DB.Exec(
			"UPDATE medias SET intro_start = ?, intro_end = ?, outro_start = ?, outro_end = ? WHERE id = ?",
			merged.IntroStart, merged.IntroEnd, merged.OutroStart, merged.OutroEnd, episodeID,
		)
		if err != nil {
			return false, fmt.Errorf("failed to save chapters timestamps: %v", err)
		}
		log.Printf("Detection: Found chapter-based markers for episode %d -> Intro: [%d-%d], Outro: [%d-%d]",
			episodeID, merged.IntroStart, merged.IntroEnd, merged.OutroStart, merged.OutroEnd)
		return true, nil
	}

	return false, nil
}

// FillMissingMarkers complète [current] avec [extra] sans jamais écraser un
// repère déjà connu. Les chapitres du fichier sont prioritaires : TheIntroDB ne
// comble que ce qu'ils ne nomment pas, et un fichier dont les chapitres ne
// donnent que le générique garde l'intro de TheIntroDB.
func FillMissingMarkers(current, extra EpisodeMarkers) EpisodeMarkers {
	if !current.hasIntro() && extra.hasIntro() {
		current.IntroStart, current.IntroEnd = extra.IntroStart, extra.IntroEnd
	}
	if !current.hasOutro() && extra.hasOutro() {
		current.OutroStart, current.OutroEnd = extra.OutroStart, extra.OutroEnd
	}
	return current
}

// DetectIntrosOutros coordinates the global detection process
func DetectIntrosOutros() {
	log.Println("Detection: Analyzing episodes for intros and outros...")

	// 1. Get all seasons that have unanalyzed episodes
	rows, err := database.DB.Query(`
		SELECT DISTINCT parent_id
		FROM medias
		WHERE type = 'episode'
		  AND ` + introPendingCondition + `
	`)
	if err != nil {
		log.Printf("Detection error: failed to query seasons: %v", err)
		return
	}
	defer rows.Close()

	var seasonIDs []int
	for rows.Next() {
		var sID int
		if err := rows.Scan(&sID); err == nil {
			seasonIDs = append(seasonIDs, sID)
		}
	}
	rows.Close()

	for _, seasonID := range seasonIDs {
		log.Printf("Detection: Starting analysis for Season ID %d...", seasonID)
		if err := AnalyzeSeasonPending(seasonID); err != nil {
			log.Printf("Detection error on Season ID %d: %v", seasonID, err)
		}
	}
	log.Println("Detection: Process completed.")
}

// EpisodeDetectionResult est ce que la détection a retenu pour un épisode.
type EpisodeDetectionResult struct {
	ID         int    `json:"id"`
	Title      string `json:"title"`
	IntroStart int    `json:"intro_start"`
	IntroEnd   int    `json:"intro_end"`
	OutroStart int    `json:"outro_start"`
	OutroEnd   int    `json:"outro_end"`
	HasIntro   bool   `json:"has_intro"`
	HasOutro   bool   `json:"has_outro"`
}

// SeasonDetectionResult est le résultat d'une saison : ses épisodes, ou
// l'erreur qui a empêché de les analyser — jamais les deux. Episodes est un
// pointeur pour qu'une saison analysée sans épisode écrive `[]` et non rien.
type SeasonDetectionResult struct {
	SeasonID    int                       `json:"season_id"`
	SeasonTitle string                    `json:"season_title"`
	Error       string                    `json:"error,omitempty"`
	Episodes    *[]EpisodeDetectionResult `json:"episodes,omitempty"`
}

// DetectIntrosOutrosForShow triggers detection for a specific show (all its seasons)
// Returns detailed results for each episode
func DetectIntrosOutrosForShow(showID int) ([]SeasonDetectionResult, error) {
	log.Printf("Detection: Starting intro/outro detection for show ID %d...", showID)

	// Get all seasons for this show
	query := `
		SELECT id, title
		FROM medias
		WHERE type = 'season' AND parent_id = ?
		ORDER BY id
	`
	rows, err := database.DB.Query(query, showID)
	if err != nil {
		return nil, fmt.Errorf("failed to query seasons for show: %v", err)
	}
	defer rows.Close()

	type SeasonInfo struct {
		ID    int
		Title string
	}
	seasons := []SeasonInfo{}
	for rows.Next() {
		var s SeasonInfo
		if err := rows.Scan(&s.ID, &s.Title); err != nil {
			log.Printf("Detection: Failed to scan season: %v", err)
			continue
		}
		seasons = append(seasons, s)
	}

	results := []SeasonDetectionResult{}
	for _, season := range seasons {
		// Reset intro/outro for this season's episodes before re-detecting
		_, _ = database.DB.Exec(`
			UPDATE medias
			SET intro_start = 0, intro_end = 0, outro_start = 0, outro_end = 0
			WHERE type = 'episode' AND parent_id = ?
		`, season.ID)

		// Run detection
		if err := AnalyzeSeason(season.ID); err != nil {
			log.Printf("Detection error on Season ID %d: %v", season.ID, err)
			results = append(results, SeasonDetectionResult{
				SeasonID:    season.ID,
				SeasonTitle: season.Title,
				Error:       err.Error(),
			})
			continue
		}

		// Get results for this season
		episodesQuery := `
			SELECT id, title, intro_start, intro_end, outro_start, outro_end
			FROM medias
			WHERE type = 'episode' AND parent_id = ?
			ORDER BY id
		`
		epRows, err := database.DB.Query(episodesQuery, season.ID)
		if err != nil {
			log.Printf("Detection: Failed to query episode results: %v", err)
			continue
		}

		episodeResults := []EpisodeDetectionResult{}
		for epRows.Next() {
			var id, introStart, introEnd, outroStart, outroEnd int
			var title string
			if err := epRows.Scan(&id, &title, &introStart, &introEnd, &outroStart, &outroEnd); err != nil {
				continue
			}
			episodeResults = append(episodeResults, EpisodeDetectionResult{
				ID:         id,
				Title:      title,
				IntroStart: introStart,
				IntroEnd:   introEnd,
				OutroStart: outroStart,
				OutroEnd:   outroEnd,
				HasIntro:   introStart > 0 && introEnd > 0,
				HasOutro:   outroStart > 0 && outroEnd > 0,
			})
		}
		epRows.Close()

		results = append(results, SeasonDetectionResult{
			SeasonID:    season.ID,
			SeasonTitle: season.Title,
			Episodes:    &episodeResults,
		})
	}

	log.Printf("Detection: Show %d scan complete. Processed %d seasons.", showID, len(seasons))
	return results, nil
}

type EpisodeInfo struct {
	ID       int
	Title    string
	FilePath string
	Duration int
	Season   int
	Episode  int
}

// introPendingCondition selects the episodes intro detection still owes a
// look: no markers, and no attempt recorded in the last 30 days. The retry
// window is what lets IntroDB, which fills in over time, eventually answer for
// an episode it knew nothing about.
const introPendingCondition = `(intro_end = 0 AND outro_start = 0
		AND (intro_checked_at IS NULL OR intro_checked_at < datetime('now', '-30 days')))`

// AnalyzeSeason detects intro/outro markers for every episode of a season,
// whatever was found before. It is the explicit re-detection.
func AnalyzeSeason(seasonID int) error {
	return analyzeSeason(seasonID, false, nil)
}

// AnalyzeSeasonPending detects markers only for the episodes of a season that
// still need them — see introPendingCondition. A season whose episodes were
// all looked at costs one query.
func AnalyzeSeasonPending(seasonID int) error {
	return analyzeSeason(seasonID, true, nil)
}

// seasonAnalysisCooldown est le temps pendant lequel une saison déjà analysée
// à la demande ne l'est pas de nouveau.
//
// La route des marqueurs lançait une analyse à chaque épisode ouvert sans
// intro connue, sans regarder si une autre tournait déjà pour la même saison :
// parcourir la liste d'une saison en lançait une par épisode, chacune avec ses
// appels à TheIntroDB et un ffprobe par épisode. Et pour une série qui n'a pas
// de générique repérable, la même analyse inutile revenait à chaque lecture.
const seasonAnalysisCooldown = 30 * time.Minute

var seasonAnalyses = struct {
	sync.Mutex
	running map[int]bool
	lastRun map[int]time.Time
}{running: map[int]bool{}, lastRun: map[int]time.Time{}}

// RequestSeasonAnalysis lance en fond l'analyse des épisodes en attente d'une
// saison, sauf si elle tourne déjà ou a tourné il y a moins de
// seasonAnalysisCooldown. Elle dit si elle en a lancé une.
func RequestSeasonAnalysis(seasonID int) bool {
	seasonAnalyses.Lock()
	if seasonAnalyses.running[seasonID] ||
		time.Since(seasonAnalyses.lastRun[seasonID]) < seasonAnalysisCooldown {
		seasonAnalyses.Unlock()
		return false
	}
	seasonAnalyses.running[seasonID] = true
	seasonAnalyses.Unlock()

	go func() {
		defer safego.Recover("indexer/detection.go:503")
		defer func() {
			seasonAnalyses.Lock()
			delete(seasonAnalyses.running, seasonID)
			seasonAnalyses.lastRun[seasonID] = time.Now()
			seasonAnalyses.Unlock()
		}()
		log.Printf("Detection: analysing pending episodes of season %d", seasonID)
		if err := AnalyzeSeasonPending(seasonID); err != nil {
			log.Printf("Detection: analysis of season %d failed: %v", seasonID, err)
		}
	}()
	return true
}

// AnalyzeEpisodesPending is AnalyzeSeasonPending restricted to some episodes:
// the ones a scan just added.
func AnalyzeEpisodesPending(seasonID int, episodeIDs []int) error {
	only := make(map[int]bool, len(episodeIDs))
	for _, id := range episodeIDs {
		only[id] = true
	}
	return analyzeSeason(seasonID, true, only)
}

func analyzeSeason(seasonID int, pendingOnly bool, only map[int]bool) error {
	var seasonNumber int
	var showID int
	err := database.DB.QueryRow(`
		SELECT COALESCE(NULLIF(season_number, 0), 0), parent_id
		FROM medias
		WHERE id = ? AND type = 'season'
	`, seasonID).Scan(&seasonNumber, &showID)
	if err != nil {
		return fmt.Errorf("failed to get season number or show ID: %v", err)
	}
	if seasonNumber <= 0 {
		var seasonTitle string
		if err := database.DB.QueryRow("SELECT title FROM medias WHERE id = ?", seasonID).Scan(&seasonTitle); err == nil {
			seasonNumber = parseSeasonNumberFromTitle(seasonTitle)
		}
	}

	// Fetch all episodes in this season with their episode numbers
	rows, err := database.DB.Query(`
		SELECT id, title, file_path, duration, COALESCE(episode_number, 0),
		       `+introPendingCondition+`
		FROM medias
		WHERE type = 'episode' AND parent_id = ?
		ORDER BY COALESCE(NULLIF(episode_number, 0), 9999), id ASC
	`, seasonID)
	if err != nil {
		return err
	}
	defer rows.Close()

	var episodes []EpisodeInfo
	for rows.Next() {
		var ep EpisodeInfo
		var filePath sql.NullString
		var epNum int
		var pending bool
		if err := rows.Scan(&ep.ID, &ep.Title, &filePath, &ep.Duration, &epNum, &pending); err == nil {
			if (pendingOnly && !pending) || (only != nil && !only[ep.ID]) {
				continue
			}
			if filePath.Valid && filePath.String != "" {
				ep.FilePath = filePath.String
				ep.Episode = epNum
				if ep.Episode <= 0 {
					if s, e, ok := ParseEpisodeNumbers(filepath.Base(ep.FilePath)); ok && s == seasonNumber {
						ep.Episode = e
					} else if s, e, ok := ParseEpisodeNumbers(ep.Title); ok && s == seasonNumber {
						ep.Episode = e
					}
				}
				ep.Season = seasonNumber
				episodes = append(episodes, ep)
			}
		}
	}
	rows.Close()

	if len(episodes) == 0 {
		return nil
	}

	// An episode is marked as checked once every source answered for it, even
	// with "nothing". A source that failed — ffprobe unable to read the file,
	// TheIntroDB unreachable — leaves it unmarked, so the next pass tries again.
	unanswered := map[int]bool{}

	// Les chapitres du fichier d'abord : ils décrivent ce fichier précis, ce que
	// TheIntroDB (des horodatages de la communauté, pour une version qui peut
	// différer) ne peut pas garantir. TheIntroDB ne vient qu'ensuite, pour ce que
	// les chapitres ne donnent pas.
	for _, ep := range episodes {
		found, err := DetectFromChapters(ep.ID, ep.FilePath)
		if err != nil {
			unanswered[ep.ID] = true
		} else if found {
			log.Printf("Detection: Episode %d mapped using FFprobe chapters.", ep.ID)
		}
	}

	// TheIntroDB se lit par l'identifiant TMDB de la série — la numérotation
	// saison/épisode de la médiathèque est celle de TMDB — ou, à défaut, par
	// l'IMDb déjà connu. tmdb_id et imdb_id sont portés par la série, pas la saison.
	var showTMDBID sql.NullInt64
	var showIMDbID sql.NullString
	_ = database.DB.QueryRow("SELECT tmdb_id, imdb_id FROM medias WHERE id = ? AND type = 'show'", showID).Scan(&showTMDBID, &showIMDbID)
	media := introDBMedia{TMDBID: int(showTMDBID.Int64), IMDbID: showIMDbID.String}

	if media.valid() {
		log.Printf("Detection: Completing with TheIntroDB for show %d (TMDB %d, IMDb %q)", showID, media.TMDBID, media.IMDbID)

		for i, ep := range episodes {
			if ep.Episode == 0 {
				log.Printf("Detection: Skipping episode %d (no episode number)", ep.ID)
				continue
			}

			var current EpisodeMarkers
			_ = database.DB.QueryRow(
				"SELECT intro_start, intro_end, outro_start, outro_end FROM medias WHERE id = ?", ep.ID,
			).Scan(&current.IntroStart, &current.IntroEnd, &current.OutroStart, &current.OutroEnd)
			if current.hasIntro() && current.hasOutro() {
				continue // les chapitres ont tout donné : pas d'appel
			}

			segments, err := FetchSegmentsFromIntroDB(media, ep.Season, ep.Episode, ep.Duration)
			if errors.Is(err, ErrIntroDBThrottled) {
				// Le reste de la saison échouerait pareil : on le laisse pour la
				// prochaine passe, sans marquer ces épisodes comme vérifiés.
				log.Printf("Detection: TheIntroDB is throttling us, leaving S%dE%d onwards for later", ep.Season, ep.Episode)
				for _, rest := range episodes[i:] {
					unanswered[rest.ID] = true
				}
				break
			}
			if err != nil {
				log.Printf("Detection: Failed to fetch segments for S%dE%d: %v", ep.Season, ep.Episode, err)
				unanswered[ep.ID] = true
				continue
			}
			if segments == nil {
				log.Printf("Detection: No data found in TheIntroDB for S%dE%d", ep.Season, ep.Episode)
				continue
			}

			merged := FillMissingMarkers(current, PickMarkers(segments, ep.Duration))
			if merged == current {
				continue
			}
			log.Printf("Detection: TheIntroDB completes S%dE%d: intro [%d-%ds], outro [%d-%ds]",
				ep.Season, ep.Episode, merged.IntroStart, merged.IntroEnd, merged.OutroStart, merged.OutroEnd)

			if _, err = database.DB.Exec(
				"UPDATE medias SET intro_start = ?, intro_end = ?, outro_start = ?, outro_end = ? WHERE id = ?",
				merged.IntroStart, merged.IntroEnd, merged.OutroStart, merged.OutroEnd, ep.ID,
			); err != nil {
				log.Printf("Detection: Failed to save timestamps for episode %d: %v", ep.ID, err)
			}
		}
	} else {
		log.Printf("Detection: Season %d has no TMDB or IMDb ID, chapters only", seasonID)
	}

	for _, ep := range episodes {
		if unanswered[ep.ID] {
			continue
		}
		_, _ = database.DB.Exec(`UPDATE medias SET intro_checked_at = CURRENT_TIMESTAMP WHERE id = ?`, ep.ID)
	}

	return nil
}

// min helper
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
