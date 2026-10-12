package handlers

import (
	"database/sql"
	"fmt"
	"log"
	"time"

	"project-player/server/database"
	"project-player/server/indexer"
)

// Attendre sa langue (ADR-0057).
//
// Un anime sort en VOSTFR, puis en VF trois semaines plus tard. Qui le suit en
// VF et refuse de continuer en japonais est « à jour dans sa langue » tant que
// l'épisode suivant n'a pas de piste française : la série quitte alors la
// rangée « Reprendre la lecture », et y revient comme une nouveauté le jour où
// la piste arrive — même si le fichier, lui, est là depuis longtemps.

// languageWait est l'attente d'un compte pour une série : la langue, et le
// moment où il a dit l'attendre.
type languageWait struct {
	lang  string
	since time.Time
}

// languageWaits sont les attentes d'un compte, par série canonique. Une valeur
// nil est un compte qui n'attend rien.
type languageWaits struct {
	byShow  map[int]languageWait
	matched map[int]bool
}

// resumeCandidate est une série que la rangée s'apprête à montrer, avec
// l'épisode sur lequel elle reprendrait.
type resumeCandidate struct {
	act      showProgressActivity
	episodes []episodeProgressRow
	row      *episodeProgressRow
	// started : la série a franchi le seuil de la rangée par elle-même. Faux
	// pour celle qui n'y figure que parce que le compte attend sa langue.
	started bool
	wait    *languageWait
}

// languageWaitVerdict dit ce que l'attente d'une langue change pour une série.
// La valeur zéro ne change rien : la série se comporte comme toutes les autres.
type languageWaitVerdict struct {
	// L'épisode à reprendre n'existe pas encore dans la langue attendue.
	stillWaiting bool
	// Il vient d'y arriver : c'est la nouveauté que le compte attendait.
	arrived bool
}

// audioArrivals : pour un média, le jour où chaque langue audio y a été vue.
type audioArrivals map[string]time.Time

// declaresALanguage écarte le fichier jamais sondé et celui dont aucune piste
// ne dit sa langue : on ne peut pas affirmer qu'il lui en manque une.
func (a audioArrivals) declaresALanguage() bool {
	for lang := range a {
		if lang != indexer.UndeterminedAudioLang {
			return true
		}
	}
	return false
}

// judgeLanguageWait décide pour une série dont le compte attend [lang], à
// partir des langues de l'épisode qui reprendrait.
//
//   - Il ne l'a pas : la série attend, hors de la rangée.
//   - Il l'a, depuis peu et depuis la dernière fois que le compte s'est occupé
//     de la série (l'avoir regardée, ou avoir dit attendre) : c'est une
//     nouveauté. La date est celle de la langue, pas du fichier.
func judgeLanguageWait(next audioArrivals, lang string, lastActivity, now time.Time) languageWaitVerdict {
	if !next.declaresALanguage() {
		return languageWaitVerdict{}
	}
	arrivedAt, spoken := next[lang]
	if !spoken {
		return languageWaitVerdict{stillWaiting: true}
	}
	fresh := now.Sub(arrivedAt) <= newEpisodeFreshness
	return languageWaitVerdict{arrived: fresh && arrivedAt.After(lastActivity)}
}

// judgeLanguageWaits rend un verdict par candidat, dans le même ordre. Seuls
// ceux dont le compte attend une langue peuvent en recevoir un autre que zéro.
//
// Une erreur laisse la rangée telle qu'elle serait sans cette règle : mieux
// vaut montrer un épisode en japonais que vider l'accueil.
func judgeLanguageWaits(candidates []resumeCandidate, now time.Time) []languageWaitVerdict {
	verdicts := make([]languageWaitVerdict, len(candidates))
	var mediaIDs []int
	for _, c := range candidates {
		if c.waitApplies() {
			mediaIDs = append(mediaIDs, c.row.item.ID)
		}
	}
	if len(mediaIDs) == 0 {
		return verdicts
	}

	arrivals, err := loadAudioArrivals(mediaIDs)
	if err != nil {
		log.Printf("ContinueWatching: audio languages query failed: %v", err)
		return verdicts
	}
	for i, c := range candidates {
		if !c.waitApplies() {
			continue
		}
		lastActivity := c.act.updatedAt
		if c.wait.since.After(lastActivity) {
			lastActivity = c.wait.since
		}
		verdicts[i] = judgeLanguageWait(arrivals[c.row.item.ID], c.wait.lang, lastActivity, now)
	}
	return verdicts
}

// waitApplies : le compte attend une langue pour cette série, et l'épisode à
// reprendre n'est pas déjà entamé. Un épisode entamé se reprend quelle que
// soit sa langue — c'est le compte qui l'a lancé. Les quelques secondes
// passées devant la question « continuer ou attendre ? » ne l'entament pas :
// c'est le seuil de la rangée qui en juge.
func (c resumeCandidate) waitApplies() bool {
	if c.wait == nil {
		return false
	}
	return !meetsContinueWatchingThreshold(c.row.currentPosition, c.row.item.Duration)
}

// of retrouve l'attente du compte pour une série de la rangée, et note
// qu'elle y figure.
//
// Les préférences sont rangées sous la série canonique (voir
// showIDForTrackPreferences), la rangée sous la ligne dont les épisodes
// dépendent : pour un doublon d'indexation ce ne sont pas les mêmes. La
// résolution n'est tentée que si le compte attend quelque chose.
func (w *languageWaits) of(showID int) *languageWait {
	if w == nil {
		return nil
	}
	id := showID
	if _, ok := w.byShow[id]; !ok {
		id = indexer.ResolveCanonicalShowID(showID)
	}
	wait, ok := w.byShow[id]
	if !ok {
		return nil
	}
	w.matched[id] = true
	return &wait
}

// unstartedCandidates rend les séries dont le compte attend la langue sans
// qu'elles figurent dans la rangée : lancées, refusées dans la langue offerte,
// et jamais regardées. Elles n'y entreront que le jour où leur épisode existe
// dans la langue attendue.
func (w *languageWaits) unstartedCandidates(userID int, hidden map[string]struct{}) []resumeCandidate {
	if w == nil {
		return nil
	}
	var showIDs []int
	for showID := range w.byShow {
		if w.matched[showID] || isContinueWatchingHidden(hidden, 0, showID) {
			continue
		}
		showIDs = append(showIDs, showID)
	}
	if len(showIDs) == 0 {
		return nil
	}

	episodesByShow, err := loadEpisodesWithProgressForShows(userID, showIDs)
	if err != nil {
		log.Printf("ContinueWatching: awaited shows query failed for user %d: %v", userID, err)
		return nil
	}
	var out []resumeCandidate
	for _, showID := range showIDs {
		episodes := episodesByShow[showID]
		row, ok := findResumeEpisodeRow(episodes)
		if !ok || row == nil {
			continue
		}
		wait := w.byShow[showID]
		var act showProgressActivity
		err := database.DB.QueryRow(`
			SELECT id, title, COALESCE(poster_url, '') FROM medias
			WHERE id = ? AND type = 'show'`, showID,
		).Scan(&act.showID, &act.title, &act.poster)
		if err != nil {
			continue // la série a quitté la bibliothèque
		}
		act.updatedAt = wait.since
		out = append(out, resumeCandidate{act: act, episodes: episodes, row: row, wait: &wait})
	}
	return out
}

// loadLanguageWaits renvoie les attentes du compte, ou nil s'il n'en a pas.
// Un compte qui n'attend rien coûte cette requête, et aucune de plus.
func loadLanguageWaits(userID int) *languageWaits {
	rows, err := database.DB.Query(`
		SELECT show_id, await_audio_lang, updated_at
		FROM user_show_track_preferences
		WHERE user_id = ? AND await_audio_lang != ''`, userID)
	if err != nil {
		log.Printf("ContinueWatching: awaited languages query failed for user %d: %v", userID, err)
		return nil
	}
	defer rows.Close()

	waits := &languageWaits{byShow: map[int]languageWait{}, matched: map[int]bool{}}
	for rows.Next() {
		var showID int
		var lang string
		var since sql.NullString
		if err := rows.Scan(&showID, &lang, &since); err != nil {
			log.Printf("ContinueWatching: awaited language scan failed for user %d: %v", userID, err)
			return nil
		}
		waits.byShow[showID] = languageWait{lang: lang, since: scanSQLiteTime(since)}
	}
	if err := rows.Err(); err != nil {
		log.Printf("ContinueWatching: awaited languages read failed for user %d: %v", userID, err)
		return nil
	}
	if len(waits.byShow) == 0 {
		return nil
	}
	return waits
}

// loadAudioArrivals charge en une requête les langues audio de plusieurs
// médias, avec le jour où chacune a été vue.
func loadAudioArrivals(mediaIDs []int) (map[int]audioArrivals, error) {
	out := make(map[int]audioArrivals, len(mediaIDs))
	if len(mediaIDs) == 0 {
		return out, nil
	}
	args := make([]interface{}, 0, len(mediaIDs))
	for _, id := range mediaIDs {
		args = append(args, id)
	}
	rows, err := database.DB.Query(fmt.Sprintf(`
		SELECT media_id, lang, first_seen_at
		FROM media_audio_langs
		WHERE media_id IN (%s)`, sqlPlaceholders(len(mediaIDs))), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var mediaID int
		var lang string
		var seenAt sql.NullString
		if err := rows.Scan(&mediaID, &lang, &seenAt); err != nil {
			return nil, err
		}
		if out[mediaID] == nil {
			out[mediaID] = audioArrivals{}
		}
		out[mediaID][lang] = scanSQLiteTime(seenAt)
	}
	return out, rows.Err()
}

// episodeAudioLanguages liste les langues audio déclarées d'un épisode, celle
// de sa piste par défaut en tête. Vide tant qu'il n'a pas été sondé.
func episodeAudioLanguages(mediaID int) []string {
	rows, err := database.DB.Query(`
		SELECT lang FROM media_audio_langs
		WHERE media_id = ? AND lang != ?
		ORDER BY position, lang`, mediaID, indexer.UndeterminedAudioLang)
	if err != nil {
		log.Printf("NextEpisode: audio languages of media %d: %v", mediaID, err)
		return nil
	}
	defer rows.Close()

	var langs []string
	for rows.Next() {
		var lang string
		if err := rows.Scan(&lang); err != nil {
			log.Printf("NextEpisode: audio languages of media %d: %v", mediaID, err)
			return nil
		}
		langs = append(langs, lang)
	}
	if err := rows.Err(); err != nil {
		log.Printf("NextEpisode: audio languages of media %d: %v", mediaID, err)
		return nil
	}
	return langs
}
