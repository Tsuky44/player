package indexer

import (
	"log"
	"strings"

	"project-player/server/database"
	"project-player/server/safego"
	"project-player/server/streaming"
)

// UndeterminedAudioLang tient la place d'un fichier dont aucune piste audio ne
// déclare sa langue : la ligne dit « déjà lu », pas « parle cette langue ».
const UndeterminedAudioLang = "und"

var audioLangAliases = map[string]string{
	"fra": "fr", "fre": "fr", "french": "fr",
	"eng": "en", "english": "en",
	"spa": "es", "esp": "es", "spanish": "es",
	"ger": "de", "deu": "de", "german": "de",
	"ita": "it", "italian": "it",
	"por": "pt", "portuguese": "pt",
	"jpn": "ja", "japanese": "ja",
	"rus": "ru", "russian": "ru",
	"chi": "zh", "zho": "zh", "chinese": "zh",
	"ara": "ar", "arabic": "ar",
	"nld": "nl", "dut": "nl", "dutch": "nl",
	"kor": "ko", "korean": "ko",
}

// AudioLangCode réduit l'étiquette de langue d'une piste audio au code que le
// compte retient pour une série, ou "" quand elle ne dit rien.
//
// C'est volontairement la règle de l'app (PlaybackPreferencesStorage
// .normalizeLangCode) et non celle des sous-titres : la langue d'une série est
// enregistrée par le lecteur avec ce code-là, et c'est à lui que les langues
// d'un épisode sont comparées (ADR-0057). Les deux tables changent ensemble.
func AudioLangCode(tag string) string {
	c := strings.ToLower(strings.TrimSpace(tag))
	if c == "" || c == "und" || c == "auto" || c == "no" {
		return ""
	}
	if two, ok := audioLangAliases[c]; ok {
		return two
	}
	if runes := []rune(c); len(runes) > 2 {
		return string(runes[:2])
	}
	return c
}

// audioLanguagesOf liste les langues audio d'un fichier, sans doublon : celle
// de la piste par défaut d'abord — c'est elle qu'on entendra faute de mieux —
// puis les autres dans l'ordre du fichier.
func audioLanguagesOf(probe *streaming.ProbeResult) []string {
	if probe == nil {
		return nil
	}
	seen := map[string]struct{}{}
	var langs []string
	add := func(tag string) {
		code := AudioLangCode(tag)
		if code == "" {
			return
		}
		if _, dup := seen[code]; dup {
			return
		}
		seen[code] = struct{}{}
		langs = append(langs, code)
	}
	for _, track := range probe.Audio {
		if track.Default {
			add(track.Language)
		}
	}
	for _, track := range probe.Audio {
		add(track.Language)
	}
	return langs
}

// recordAudioLanguages met media_audio_langs à jour après un sondage.
//
// Une langue déjà connue garde sa date : seul ce qui apparaît est daté. Une
// langue disparue du fichier est retirée. backfill date les lignes du jour où
// le média est entré dans la bibliothèque — ce que le serveur portait avant de
// tenir ce registre n'est pas une nouveauté.
func recordAudioLanguages(mediaID int, probe *streaming.ProbeResult, backfill bool) error {
	langs := audioLanguagesOf(probe)
	if len(langs) == 0 {
		langs = []string{UndeterminedAudioLang}
	}

	tx, err := database.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	args := make([]interface{}, 0, len(langs)+1)
	args = append(args, mediaID)
	for _, lang := range langs {
		args = append(args, lang)
	}
	if _, err := tx.Exec(
		`DELETE FROM media_audio_langs WHERE media_id = ? AND lang NOT IN (`+
			strings.TrimSuffix(strings.Repeat("?,", len(langs)), ",")+`)`,
		args...,
	); err != nil {
		return err
	}

	seenAt := `CURRENT_TIMESTAMP`
	if backfill {
		seenAt = `COALESCE((SELECT created_at FROM medias WHERE id = ?1), CURRENT_TIMESTAMP)`
	}
	for position, lang := range langs {
		if _, err := tx.Exec(`
			INSERT INTO media_audio_langs (media_id, lang, position, first_seen_at)
			VALUES (?1, ?2, ?3, `+seenAt+`)
			ON CONFLICT(media_id, lang) DO UPDATE SET position = excluded.position`,
			mediaID, lang, position,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// noteAudioLanguages est la forme qu'appellent les sondages : un registre qui
// n'a pas pu s'écrire ne doit pas faire échouer le sondage lui-même.
func noteAudioLanguages(mediaID int, probe *streaming.ProbeResult) {
	if err := recordAudioLanguages(mediaID, probe, false); err != nil {
		log.Printf("Indexer: audio languages of media %d not recorded: %v", mediaID, err)
	}
}

// Taille d'un lot du rattrapage : assez petit pour ne jamais tenir plus de
// quelques centaines de tracks_json en mémoire à la fois.
const audioLangBackfillBatch = 200

// BackfillAudioLanguagesAsync inscrit les langues des médias sondés avant que
// le registre existe. Il lit les sondages déjà stockés et ne lance aucun
// ffprobe ; une fois la bibliothèque inscrite, il ne trouve plus rien à faire.
func BackfillAudioLanguagesAsync() {
	go safego.Run("BackfillAudioLanguages", func() {
		done, err := backfillAudioLanguages()
		if err != nil {
			log.Printf("Indexer: audio language backfill stopped: %v", err)
		}
		if done > 0 {
			log.Printf("Indexer: audio languages recorded for %d media", done)
		}
	})
}

func backfillAudioLanguages() (int, error) {
	type stored struct {
		id     int
		tracks string
	}
	done, lastID := 0, 0
	for {
		rows, err := database.DB.Query(`
			SELECT m.id, m.tracks_json
			FROM medias m
			WHERE m.id > ?
			  AND m.type IN ('movie', 'episode')
			  AND m.tracks_json IS NOT NULL AND m.tracks_json != ''
			  AND NOT EXISTS (SELECT 1 FROM media_audio_langs l WHERE l.media_id = m.id)
			ORDER BY m.id
			LIMIT ?`, lastID, audioLangBackfillBatch)
		if err != nil {
			return done, err
		}
		// Le curseur est rendu avant d'écrire, comme dans le rattrapage des
		// sondages : SQLite n'écrit pas sous une lecture ouverte.
		var batch []stored
		for rows.Next() {
			var item stored
			if err := rows.Scan(&item.id, &item.tracks); err != nil {
				rows.Close()
				return done, err
			}
			batch = append(batch, item)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return done, err
		}
		if len(batch) == 0 {
			return done, nil
		}

		for _, item := range batch {
			lastID = item.id
			probe, err := streaming.UnmarshalProbeResult(item.tracks)
			if err != nil {
				// Un sondage illisible sera refait à la prochaine lecture, qui
				// inscrira alors ses langues.
				continue
			}
			if err := recordAudioLanguages(item.id, probe, true); err != nil {
				return done, err
			}
			done++
		}
	}
}
