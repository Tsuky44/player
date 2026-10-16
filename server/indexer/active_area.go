package indexer

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"project-player/server/database"
	"project-player/server/safego"
	"project-player/server/streaming"
)

// La mesure des bandes noires incrustées, une fois par fichier. Voir ADR-0067.
//
// Elle décode des images, contrairement au sondage : elle passe donc après
// lui, un fichier à la fois et en priorité basse, et jamais sur le chemin d'un
// démarrage de lecture.

var activeAreaBackfill atomic.Bool

// activeAreaInFlight évite qu'un même fichier soit mesuré deux fois à la fois,
// par le rattrapage et par une demande du lecteur.
var activeAreaInFlight sync.Map

// LoadActiveArea rend la zone utile notée pour un média, et si le fichier a
// déjà été regardé. Une zone nil d'un fichier regardé veut dire « pas de
// bandes ».
func LoadActiveArea(mediaID int) (*streaming.ActiveArea, bool) {
	var raw sql.NullString
	var checked sql.NullString
	err := database.DB.QueryRow(
		`SELECT active_area, active_area_checked_at FROM medias WHERE id = ?`, mediaID,
	).Scan(&raw, &checked)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("Indexer: active area read failed for media %d: %v", mediaID, err)
		}
		return nil, false
	}
	if !checked.Valid {
		return nil, false
	}
	if !raw.Valid || raw.String == "" {
		return nil, true
	}
	var area streaming.ActiveArea
	if err := json.Unmarshal([]byte(raw.String), &area); err != nil {
		log.Printf("Indexer: active area unreadable for media %d: %v", mediaID, err)
		return nil, true
	}
	return &area, true
}

// RequestActiveArea mesure un média pas encore regardé, en arrière-plan. Le
// lecteur qui l'a demandé ne l'attend pas : il aura la zone à la lecture
// suivante, et le rattrapage aura le plus souvent fini avant.
func RequestActiveArea(mediaID int) {
	go safego.Run("RequestActiveArea", func() {
		item, ok := pendingActiveArea(mediaID)
		if ok {
			measureActiveArea(context.Background(), item)
		}
	})
}

type activeAreaItem struct {
	id       int
	path     string
	duration float64
	width    int
	height   int
}

const pendingActiveAreaQuery = `
	SELECT id, file_path, duration, tracks_json
	FROM medias
	WHERE type IN ('movie', 'episode')
	  AND file_path IS NOT NULL AND file_path != ''
	  AND tracks_json IS NOT NULL AND tracks_json != ''
	  AND duration > 0
	  AND active_area_checked_at IS NULL`

func pendingActiveArea(mediaID int) (activeAreaItem, bool) {
	rows, err := database.DB.Query(pendingActiveAreaQuery+` AND id = ?`, mediaID)
	if err != nil {
		log.Printf("Indexer: active area query failed for media %d: %v", mediaID, err)
		return activeAreaItem{}, false
	}
	items := scanActiveAreaItems(rows)
	if len(items) == 0 {
		return activeAreaItem{}, false
	}
	return items[0], true
}

// scanActiveAreaItems lit et referme [rows] avant toute écriture : SQLite ne
// doit pas garder un curseur ouvert pendant que la mesure écrit.
func scanActiveAreaItems(rows *sql.Rows) []activeAreaItem {
	defer rows.Close()
	var items []activeAreaItem
	for rows.Next() {
		var item activeAreaItem
		var duration int
		var tracksJSON string
		if err := rows.Scan(&item.id, &item.path, &duration, &tracksJSON); err != nil {
			log.Printf("Indexer: active area scan failed: %v", err)
			continue
		}
		item.duration = float64(duration)
		// Sans piste vidéo lisible, les dimensions restent nulles : la mesure
		// n'a rien à décoder et pose seulement la marque, pour ne pas y revenir.
		if probe, err := streaming.UnmarshalProbeResult(tracksJSON); err == nil && probe.Video != nil {
			item.width, item.height = probe.Video.Width, probe.Video.Height
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		log.Printf("Indexer: active area read failed: %v", err)
	}
	return items
}

// BackfillActiveAreasAsync mesure tous les médias pas encore regardés. Faux
// quand un rattrapage tourne déjà.
func BackfillActiveAreasAsync() bool {
	if !activeAreaBackfill.CompareAndSwap(false, true) {
		return false
	}
	go func() {
		defer safego.Recover("indexer/active_area.go:BackfillActiveAreasAsync")
		defer activeAreaBackfill.Store(false)

		rows, err := database.DB.Query(pendingActiveAreaQuery)
		if err != nil {
			log.Printf("Indexer: active area backfill query failed: %v", err)
			return
		}
		items := scanActiveAreaItems(rows)
		if len(items) == 0 {
			return
		}
		started := time.Now()
		for _, item := range items {
			measureActiveArea(context.Background(), item)
		}
		log.Printf("Indexer: active area backfill completed (%d files, %s)",
			len(items), time.Since(started).Round(time.Second))
	}()
	return true
}

func measureActiveArea(ctx context.Context, item activeAreaItem) {
	if _, busy := activeAreaInFlight.LoadOrStore(item.id, struct{}{}); busy {
		return
	}
	defer activeAreaInFlight.Delete(item.id)

	area, err := streaming.DetectActiveArea(ctx, item.path, item.duration, item.width, item.height)
	if err != nil {
		log.Printf("Indexer: active area detection failed for media %d: %v", item.id, err)
		// Un partage démonté échoue de la même façon : seul un fichier
		// présent est tenu pour regardé.
		if _, statErr := os.Stat(item.path); statErr != nil {
			return
		}
	}
	if area != nil {
		log.Printf("Indexer: media %d has burned-in bars, active area %.3f,%.3f %.3fx%.3f",
			item.id, area.X, area.Y, area.Width, area.Height)
	}
	markActiveArea(item.id, area)
}

func markActiveArea(mediaID int, area *streaming.ActiveArea) {
	var raw interface{}
	if area != nil {
		encoded, err := json.Marshal(area)
		if err != nil {
			log.Printf("Indexer: active area encode failed for media %d: %v", mediaID, err)
			return
		}
		raw = string(encoded)
	}
	_, err := database.DB.Exec(
		`UPDATE medias SET active_area = ?, active_area_checked_at = CURRENT_TIMESTAMP WHERE id = ?`,
		raw, mediaID,
	)
	if err != nil {
		log.Printf("Indexer: active area persist failed for media %d: %v", mediaID, err)
	}
}
