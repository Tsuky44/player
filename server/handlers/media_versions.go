package handlers

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/streaming"
)

// Identity grouping is presentation only. Each file retains its id, progress,
// subtitles and playback endpoints. Unidentified titles are never merged by name.
func versionGroupKey(m models.Media) string {
	if m.Type == models.TypeMovie && m.TMDBID > 0 {
		return fmt.Sprintf("movie:%d", m.TMDBID)
	}
	if m.Type == models.TypeEpisode && m.ParentID != nil && m.EpisodeNumber > 0 {
		return fmt.Sprintf("episode:%d:%d:%d", *m.ParentID, m.SeasonNumber, m.EpisodeNumber)
	}
	return fmt.Sprintf("id:%d", m.ID)
}

var resolutionInFilename = regexp.MustCompile(`(?i)(?:^|[ ._\-\[(])(4320|2160|1440|1080|720|576|480)[pi]?(?:$|[ ._\-\])])`)
var fourKInFilename = regexp.MustCompile(`(?i)(?:^|[ ._\-\[(])(?:4k|uhd)(?:$|[ ._\-\])])`)

type versionQuality struct {
	pixels  int64
	bitrate float64
	label   string
}

func qualityForVersion(item models.HomeMediaItem, raw string, size int64) versionQuality {
	var probe streaming.ProbeResult
	_ = json.Unmarshal([]byte(raw), &probe)
	q := versionQuality{}
	name := filepath.Base(strings.ReplaceAll(item.FilePath, `\`, "/"))
	if v := probe.Video; v != nil && v.Width > 0 && v.Height > 0 {
		q.pixels = int64(v.Width) * int64(v.Height)
		q.label = fmt.Sprintf("%d × %d", v.Width, v.Height)
		if v.Codec != "" {
			q.label += " · " + strings.ToUpper(v.Codec)
		}
	} else {
		height := 0
		if match := resolutionInFilename.FindStringSubmatch(name); len(match) > 1 {
			height, _ = strconv.Atoi(match[1])
		}
		if height == 0 && fourKInFilename.MatchString(name) {
			height = 2160
		}
		if height > 0 {
			q.pixels = int64(height) * int64(height) * 16 / 9
			q.label = fmt.Sprintf("%dp", height)
		}
	}
	duration := probe.Duration
	if duration <= 0 {
		duration = float64(item.Duration)
	}
	if duration > 0 && size > 0 {
		q.bitrate = float64(size) * 8 / duration
	}
	if q.label == "" {
		q.label = "Qualité inconnue"
	}
	q.label += " · " + name
	return q
}

func groupMediaVersions(items []models.HomeMediaItem) ([]models.HomeMediaItem, error) {
	groups := map[string][]models.HomeMediaItem{}
	var keys []string
	for _, item := range items {
		key := versionGroupKey(item.Media)
		if _, ok := groups[key]; !ok {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], item)
	}
	result := make([]models.HomeMediaItem, 0, len(keys))
	for _, key := range keys {
		group := groups[key]
		if len(group) == 1 {
			result = append(result, group[0])
			continue
		}
		qualities := map[int]versionQuality{}
		args := make([]interface{}, len(group))
		byID := map[int]models.HomeMediaItem{}
		for i, item := range group {
			args[i] = item.ID
			byID[item.ID] = item
		}
		rows, err := database.DB.Query(`SELECT id,COALESCE(tracks_json,''),COALESCE(file_size,0) FROM medias WHERE id IN (`+sqlPlaceholders(len(args))+`)`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id int
			var raw string
			var size int64
			if err = rows.Scan(&id, &raw, &size); err != nil {
				rows.Close()
				return nil, err
			}
			qualities[id] = qualityForVersion(byID[id], raw, size)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		sort.SliceStable(group, func(i, j int) bool {
			a, b := group[i], group[j]
			if (a.FilePath != "") != (b.FilePath != "") {
				return a.FilePath != ""
			}
			qa, qb := qualities[a.ID], qualities[b.ID]
			if qa.pixels != qb.pixels {
				return qa.pixels > qb.pixels
			}
			if qa.bitrate != qb.bitrate {
				return qa.bitrate > qb.bitrate
			}
			return a.ID < b.ID
		})
		best := group[0]
		for _, item := range group {
			if item.FilePath == "" {
				continue
			}
			item.Versions = nil
			best.Versions = append(best.Versions, models.MediaVersion{HomeMediaItem: item, Label: qualities[item.ID].label})
		}
		result = append(result, best)
	}
	return result, nil
}

func movieVersions(mediaID, userID int) ([]models.MediaVersion, error) {
	rows, err := database.DB.Query(`SELECT `+libraryItemColumns+` FROM medias m
 LEFT JOIN progressions p ON p.media_id=m.id AND p.user_id=?
 WHERE m.type='movie' AND (m.id=? OR (m.tmdb_id>0 AND m.tmdb_id=(SELECT tmdb_id FROM medias WHERE id=?)))`, userID, mediaID, mediaID)
	if err != nil {
		return nil, err
	}
	items := []models.HomeMediaItem{}
	for rows.Next() {
		item, e := scanLibraryItem(rows)
		if e != nil {
			rows.Close()
			return nil, e
		}
		items = append(items, item)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	grouped, err := groupMediaVersions(items)
	if err != nil {
		return nil, err
	}
	if len(grouped) == 0 {
		return nil, nil
	}
	return grouped[0].Versions, nil
}

func groupMovieCards(items []models.Media) ([]models.Media, error) {
	decorated := make([]models.HomeMediaItem, len(items))
	for i, m := range items {
		decorated[i] = models.HomeMediaItem{Media: m, Duration: m.Duration}
	}
	grouped, err := groupMediaVersions(decorated)
	if err != nil {
		return nil, err
	}
	result := make([]models.Media, 0, len(grouped))
	for _, item := range grouped {
		item.Media.Duration = item.Duration
		result = append(result, item.Media)
	}
	return result, nil
}
