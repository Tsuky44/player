package streaming

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// Chapter est un chapitre du conteneur, en secondes.
type Chapter struct {
	ID        int     `json:"id"`
	StartTime float64 `json:"start_time"`
	EndTime   float64 `json:"end_time"`
	// Title est le titre du chapitre, vide quand le fichier n'en donne pas.
	Title string `json:"title"`
}

// probeTimeout borne un ffprobe. Il lit l'en-tête et l'index, pas le film :
// quelques secondes même sur un disque réseau. Au-delà, le partage ne répond
// plus, et attendre davantage ne ferait qu'empiler des processus bloqués.
const probeTimeout = 2 * time.Minute

// chapterCache garde les chapitres d'un fichier tant qu'il ne change pas.
//
// La route des chapitres relançait ffprobe à chaque ouverture d'un épisode, et
// la détection d'intro le relançait pour chaque épisode d'une saison. Les
// chapitres ne changent qu'avec le fichier : la taille et la date de
// modification le disent sans le relire.
var chapterCache = struct {
	sync.Mutex
	entries map[string]chapterEntry
}{entries: map[string]chapterEntry{}}

type chapterEntry struct {
	size     int64
	modTime  time.Time
	chapters []Chapter
}

// maxCachedChapterFiles borne le cache ; au-delà, il repart de zéro. Une
// médiathèque se parcourt épisode par épisode, et un cache vidé de temps en
// temps ne coûte qu'un ffprobe par fichier.
const maxCachedChapterFiles = 2048

// ProbeChapters lit les chapitres de path.
func ProbeChapters(path string) ([]Chapter, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	chapterCache.Lock()
	if e, ok := chapterCache.entries[path]; ok && e.size == info.Size() && e.modTime.Equal(info.ModTime()) {
		chapterCache.Unlock()
		// Une copie : l'appelant peut compléter les titres sans toucher au cache.
		return append([]Chapter(nil), e.chapters...), nil
	}
	chapterCache.Unlock()

	chapters, err := probeChapters(path)
	if err != nil {
		return nil, err
	}

	chapterCache.Lock()
	if len(chapterCache.entries) >= maxCachedChapterFiles {
		chapterCache.entries = map[string]chapterEntry{}
	}
	chapterCache.entries[path] = chapterEntry{size: info.Size(), modTime: info.ModTime(), chapters: chapters}
	chapterCache.Unlock()
	return append([]Chapter(nil), chapters...), nil
}

func probeChapters(path string) ([]Chapter, error) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ffprobe",
		"-v", "quiet", "-print_format", "json", "-show_chapters", path).Output()
	if err != nil {
		return nil, fmt.Errorf("ffprobe chapters: %w", err)
	}

	var parsed struct {
		Chapters []struct {
			ID        int            `json:"id"`
			StartTime string         `json:"start_time"`
			EndTime   string         `json:"end_time"`
			Tags      map[string]any `json:"tags"`
		} `json:"chapters"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("ffprobe chapters: %w", err)
	}

	chapters := make([]Chapter, 0, len(parsed.Chapters))
	for _, c := range parsed.Chapters {
		start, _ := strconv.ParseFloat(c.StartTime, 64)
		end, _ := strconv.ParseFloat(c.EndTime, 64)
		title := ""
		for _, key := range []string{"title", "TITLE"} {
			if t, ok := c.Tags[key]; ok {
				title = fmt.Sprintf("%v", t)
				break
			}
		}
		chapters = append(chapters, Chapter{ID: c.ID, StartTime: start, EndTime: end, Title: title})
	}
	return chapters, nil
}
