package sharelinks

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Où en est chaque spectateur d'un lien, sous le prénom qu'il a donné
// (ADR-0066). Le prénom n'est pas une identité : quiconque ouvre le lien peut
// en donner un, et retrouve alors l'avancement qui va avec. Il ne protège
// rien — le code du lien et son mot de passe s'en chargent — il range.
//
// Ces lignes ne vivent pas plus longtemps que leur lien : la base les
// supprime avec lui, et PurgeEndedProgress quand il a expiré.

var (
	// ErrViewerName : un prénom vide, trop long ou fait de caractères de
	// contrôle.
	ErrViewerName = errors.New("invalid share link viewer name")
	// ErrTooManyViewers : le lien a déjà MaxViewersPerShare prénoms et
	// celui-ci n'en fait pas partie.
	ErrTooManyViewers = errors.New("too many viewers on this share link")
)

// MaxViewerNameRunes borne un prénom : de quoi écrire « Marie-Charlotte et
// Jean-Baptiste », pas un roman.
const MaxViewerNameRunes = 40

// MaxViewersPerShare borne les prénoms d'un lien. Le lien est public : sans
// borne, un visiteur qui invente un prénom par requête remplirait la base.
// Une famille ou un groupe d'amis tient largement dedans.
const MaxViewersPerShare = 50

// ViewerProgress est l'avancement d'un spectateur dans un lien.
type ViewerProgress struct {
	// Name est le prénom tel qu'il l'a écrit la dernière fois.
	Name string
	// Positions donne la position, en secondes, de chaque média commencé et
	// pas fini.
	Positions map[int]int
	// Finished liste les médias vus jusqu'au seuil « vu », par id croissant.
	Finished []int
	// LastMediaID est le dernier média regardé, 0 si rien ne l'a été.
	LastMediaID int
}

// NormalizeViewerName rend le prénom à afficher (espaces resserrés) et la clé
// qui le retrouve : la casse ne compte pas, « marie » est « Marie ».
func NormalizeViewerName(raw string) (name, key string, err error) {
	name = strings.Join(strings.Fields(raw), " ")
	if name == "" || utf8.RuneCountInString(name) > MaxViewerNameRunes ||
		strings.IndexFunc(name, func(r rune) bool { return !unicode.IsPrint(r) }) >= 0 {
		return "", "", ErrViewerName
	}
	return name, strings.ToLower(name), nil
}

// SaveProgress note où le spectateur rawName en est dans mediaID. Un média
// fini perd sa position : le relancer le reprend du début, et un média vu
// qu'on relance redevient « en cours ».
func (s *Store) SaveProgress(shareID int, rawName string, mediaID, positionSeconds int, finished bool) error {
	name, key, err := NormalizeViewerName(rawName)
	if err != nil {
		return err
	}
	if err := s.checkViewerRoom(shareID, key); err != nil {
		return err
	}
	if finished || positionSeconds < 0 {
		positionSeconds = 0
	}
	_, err = s.db.Exec(`
		INSERT INTO media_share_progress
			(share_id, viewer_key, viewer_name, media_id, position_seconds, finished, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (share_id, viewer_key, media_id) DO UPDATE SET
			viewer_name = excluded.viewer_name,
			position_seconds = excluded.position_seconds,
			finished = excluded.finished,
			updated_at = excluded.updated_at`,
		shareID, key, name, mediaID, positionSeconds, finished, s.now().UnixMilli())
	if err != nil {
		return fmt.Errorf("save share %d progress: %w", shareID, err)
	}
	return nil
}

// checkViewerRoom refuse un nouveau prénom quand le lien en a déjà assez ; un
// prénom déjà connu passe toujours.
func (s *Store) checkViewerRoom(shareID int, key string) error {
	var known bool
	var others int
	err := s.db.QueryRow(`
		SELECT
			EXISTS (SELECT 1 FROM media_share_progress WHERE share_id = ? AND viewer_key = ?),
			(SELECT COUNT(DISTINCT viewer_key) FROM media_share_progress WHERE share_id = ?)`,
		shareID, key, shareID).Scan(&known, &others)
	if err != nil {
		return fmt.Errorf("count share %d viewers: %w", shareID, err)
	}
	if !known && others >= MaxViewersPerShare {
		return ErrTooManyViewers
	}
	return nil
}

// Progress renvoie l'avancement du spectateur rawName dans le lien shareID :
// vide pour un prénom que le lien ne connaît pas encore.
func (s *Store) Progress(shareID int, rawName string) (ViewerProgress, error) {
	name, key, err := NormalizeViewerName(rawName)
	if err != nil {
		return ViewerProgress{}, err
	}
	rows, err := s.db.Query(`
		SELECT viewer_name, media_id, position_seconds, finished FROM media_share_progress
		WHERE share_id = ? AND viewer_key = ?
		ORDER BY updated_at DESC, media_id DESC`, shareID, key)
	if err != nil {
		return ViewerProgress{}, fmt.Errorf("load share %d progress: %w", shareID, err)
	}
	defer rows.Close()

	out := ViewerProgress{Name: name, Positions: map[int]int{}, Finished: []int{}}
	first := true
	for rows.Next() {
		var stored string
		var mediaID, position int
		var finished bool
		if err := rows.Scan(&stored, &mediaID, &position, &finished); err != nil {
			return ViewerProgress{}, fmt.Errorf("scan share %d progress: %w", shareID, err)
		}
		if first {
			out.Name, out.LastMediaID, first = stored, mediaID, false
		}
		switch {
		case finished:
			out.Finished = append(out.Finished, mediaID)
		case position > 0:
			out.Positions[mediaID] = position
		}
	}
	if err := rows.Err(); err != nil {
		return ViewerProgress{}, fmt.Errorf("load share %d progress: %w", shareID, err)
	}
	sort.Ints(out.Finished)
	return out, nil
}

// PurgeEndedProgress supprime l'avancement des liens qui ne s'ouvrent plus :
// expirés, ou vus depuis plus de ConsumedGrace. Le lien lui-même reste, pour
// que son créateur voie ce qu'il est devenu ; personne ne reprendra plus rien
// dessus. Renvoie le nombre de lignes supprimées.
func (s *Store) PurgeEndedProgress() (int64, error) {
	now := s.now()
	res, err := s.db.Exec(`
		DELETE FROM media_share_progress WHERE share_id IN (
			SELECT id FROM media_shares
			WHERE (expires_at IS NOT NULL AND expires_at <= ?)
			   OR (consumed_at IS NOT NULL AND consumed_at <= ?))`,
		now.Unix(), now.Add(-ConsumedGrace).Unix())
	if err != nil {
		return 0, fmt.Errorf("purge ended share progress: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("purge ended share progress: %w", err)
	}
	return n, nil
}
