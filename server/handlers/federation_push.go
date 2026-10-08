package handlers

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"project-player/server/database"
	"time"
)

// Transmission de la progression aux serveurs liés, par une tâche de fond qui
// suit progress_changes. Voir federation.go.

// ==================== TRANSMISSION ====================

type peerBackoff struct {
	failures int
	retryAt  time.Time
}

var peerBackoffs = map[int]*peerBackoff{}
var peerBackoffWake = make(chan int, 16)

func resetPeerBackoff(id int) {
	select {
	case peerBackoffWake <- id:
	default:
	}
}

// RunFederation transmet la progression aux serveurs liés jusqu'à l'arrêt du
// contexte. Chaque passe reprend là où la précédente s'est arrêtée
// (account_links.pushed_seq) : un serveur injoignable pendant une semaine
// reçoit tout à son retour, sans file d'attente à entretenir.
func RunFederation(ctx context.Context) {
	ticker := time.NewTicker(federationTick)
	defer ticker.Stop()
	for {
		federationPass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-federationWake:
		case id := <-peerBackoffWake:
			delete(peerBackoffs, id)
		}
	}
}

func peerFailed(peer peerRow, err error) {
	b := peerBackoffs[peer.id]
	if b == nil {
		b = &peerBackoff{}
		peerBackoffs[peer.id] = b
	}
	b.failures++
	delay := federationTick << min(b.failures, 6) // jusqu'à ~5 min
	b.retryAt = time.Now().Add(delay)
	_, _ = database.DB.Exec(`UPDATE peer_servers SET last_error = ? WHERE id = ?`, err.Error(), peer.id)
}

func peerSucceeded(peer peerRow) {
	delete(peerBackoffs, peer.id)
	_, _ = database.DB.Exec(`UPDATE peer_servers SET last_error = '', last_contact_at = CURRENT_TIMESTAMP
		WHERE id = ? AND (last_error != '' OR last_contact_at IS NULL OR last_contact_at < datetime('now', '-1 minute'))`, peer.id)
}

func queryPeers(where string) []peerRow {
	rows, err := database.DB.Query(`SELECT ` + peerColumns + ` FROM peer_servers WHERE ` + where)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var peers []peerRow
	for rows.Next() {
		if p, err := scanPeer(rows); err == nil {
			peers = append(peers, p)
		}
	}
	return peers
}

func federationPass(ctx context.Context) {
	if database.DB == nil {
		return
	}
	now := time.Now()
	for _, peer := range queryPeers(`local_approved = 1 AND approval_sent = 0`) {
		if b := peerBackoffs[peer.id]; b != nil && now.Before(b.retryAt) {
			continue
		}
		status, err := peerCall(ctx, peer, "/api/federation/approval", struct{}{}, nil)
		if err != nil {
			if status == http.StatusUnauthorized {
				err = errors.New("L’autre serveur ne connaît pas ce lien : un compte doit être lié de nouveau")
			}
			peerFailed(peer, err)
			continue
		}
		_, _ = database.DB.Exec(`UPDATE peer_servers SET approval_sent = 1 WHERE id = ?`, peer.id)
		peerSucceeded(peer)
	}
	for _, peer := range queryPeers(`local_approved = 1 AND remote_approved = 1`) {
		if b := peerBackoffs[peer.id]; b != nil && now.Before(b.retryAt) {
			continue
		}
		if err := pushPeer(ctx, peer); err != nil {
			peerFailed(peer, err)
		} else {
			peerSucceeded(peer)
		}
	}
}

type linkRow struct {
	id, userID, remoteUserID, pushedSeq int
}

func pushPeer(ctx context.Context, peer peerRow) error {
	rows, err := database.DB.Query(`SELECT l.id, l.user_id, l.remote_user_id, l.pushed_seq FROM account_links l
		WHERE l.peer_id = ? AND EXISTS (SELECT 1 FROM progress_changes c WHERE c.user_id = l.user_id AND c.seq > l.pushed_seq)`, peer.id)
	if err != nil {
		return err
	}
	var links []linkRow
	for rows.Next() {
		var l linkRow
		if rows.Scan(&l.id, &l.userID, &l.remoteUserID, &l.pushedSeq) == nil {
			links = append(links, l)
		}
	}
	rows.Close()
	for _, link := range links {
		if err := pushLink(ctx, peer, link); err != nil {
			return err
		}
	}
	return nil
}

// pendingChanges lit les progressions modifiées après seq, dans l'ordre. Les
// médias sans identité portable avancent le curseur sans être transmis.
func pendingChanges(userID, after int) (entries []PortableProgress, lastSeq int, read int, err error) {
	rows, err := database.DB.Query(`WITH content(id, type, tmdb, season, episode) AS (`+portableMedia+`)
		SELECT c.seq, ct.type, ct.tmdb, ct.season, ct.episode,
			p.current_position_seconds, p.is_finished, p.updated_at
		FROM progress_changes c
		LEFT JOIN progressions p ON p.user_id = c.user_id AND p.media_id = c.media_id
		LEFT JOIN content ct ON ct.id = c.media_id
		WHERE c.user_id = ? AND c.seq > ? ORDER BY c.seq LIMIT ?`, userID, after, federationBatch)
	if err != nil {
		return nil, after, 0, err
	}
	defer rows.Close()
	lastSeq = after
	entries = []PortableProgress{}
	for rows.Next() {
		var seq int
		var kind sql.NullString
		var tmdb, season, episode, position sql.NullInt64
		var finished sql.NullBool
		var stamp sql.NullString
		if err := rows.Scan(&seq, &kind, &tmdb, &season, &episode, &position, &finished, &stamp); err != nil {
			return nil, after, 0, err
		}
		read++
		lastSeq = seq
		date := scanSQLiteTime(stamp)
		if !kind.Valid || !position.Valid || date.IsZero() {
			continue
		}
		entries = append(entries, PortableProgress{
			Type: kind.String, TMDBID: int(tmdb.Int64), Season: int(season.Int64), Episode: int(episode.Int64),
			Position: int(position.Int64), Finished: finished.Bool, UpdatedAt: date.UTC().Format(time.RFC3339Nano),
		})
	}
	return entries, lastSeq, read, rows.Err()
}

func pushLink(ctx context.Context, peer peerRow, link linkRow) error {
	for {
		entries, lastSeq, read, err := pendingChanges(link.userID, link.pushedSeq)
		if err != nil || read == 0 {
			return err
		}
		if len(entries) > 0 {
			status, err := peerCall(ctx, peer, "/api/federation/progress", peerProgressBody{
				FromUserID: link.userID, ToUserID: link.remoteUserID, Entries: entries,
			}, nil)
			switch {
			case status == http.StatusNotFound:
				// L'autre serveur ne connaît plus ce lien : dissocié là-bas, ou
				// compte supprimé. Il n'y a plus rien à transmettre.
				_, _ = database.DB.Exec(`DELETE FROM account_links WHERE id = ?`, link.id)
				return nil
			case status == http.StatusUnauthorized:
				_, _ = database.DB.Exec(`UPDATE peer_servers SET remote_approved = 0 WHERE id = ?`, peer.id)
				return errors.New("L’autre serveur ne reconnaît plus ce lien")
			case status == http.StatusForbidden:
				_, _ = database.DB.Exec(`UPDATE peer_servers SET remote_approved = 0 WHERE id = ?`, peer.id)
				return errors.New("En attente de l’administrateur de l’autre serveur")
			case err != nil:
				return err
			}
		}
		if _, err := database.DB.Exec(`UPDATE account_links SET pushed_seq = ? WHERE id = ?`, lastSeq, link.id); err != nil {
			return err
		}
		link.pushedSeq = lastSeq
		if read < federationBatch {
			return nil
		}
	}
}
