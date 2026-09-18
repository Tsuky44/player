package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/julienschmidt/httprouter"
	"project-player/server/config"
	"project-player/server/database"
)

// Le journal du client, rattaché à la lecture qui l'a produit.
//
// Le client tient déjà ce journal en mémoire (voir client_log.dart), mais il y
// meurt avec le processus : une panne remarquée le lendemain n'a plus rien à
// montrer, et une panne sur le téléviseur du salon n'est lisible que depuis ce
// téléviseur. Rattachées à leur ligne d'historique, ces lignes se relisent
// depuis n'importe quel appareil, par qui administre le serveur.
//
// Ce qui monte est la tranche d'une lecture, envoyée une fois, à la fin —
// pas un flux continu. Le serveur n'est pas un collecteur de journaux : il
// garde ce qui documente une séance, borné, et l'efface avec elle.

const (
	// Au-delà, les lignes les plus anciennes de la tranche sont écartées. Un
	// démarrage de lecture en écrit une vingtaine et une séance entière
	// rarement plus de deux cents ; trois cents laisse de la marge sans qu'une
	// boucle de reconnexion puisse remplir la base.
	playbackLogMaxLines = 300
	// Le plafond dur, en octets de JSON stocké. Il prime sur le compte de
	// lignes : trois cents lignes de deux mille caractères ne doivent pas
	// entrer dans la base sous prétexte qu'elles sont trois cents.
	playbackLogMaxBytes = 128 * 1024
	// Une ligne plus longue que ça est tronquée. Le client tronque déjà au même
	// ordre de grandeur ; ceci vaut pour un client qui ne le ferait pas.
	playbackLogMaxLineLength = 2000
	// Le plafond du bloc de mesures. Un résumé tient en quelques centaines
	// d'octets ; ce qui dépasse n'est plus un résumé, et n'a rien à faire dans
	// une colonne qu'on relit à chaque ouverture de journal.
	playbackStatsMaxBytes = 4 * 1024
	// Combien de lectures gardent leur journal, au total.
	//
	// Sans ce plafond, rien ne bornerait la table : un journal disparaît avec sa
	// ligne d'historique, et l'historique ne s'efface qu'à la main. Dix séances
	// couvrent largement « la panne d'hier » — ce pour quoi tout ceci existe.
	playbackLogMaxRows = 10
)

// PlaybackLogLine is one line of a client's log.
type PlaybackLogLine struct {
	At time.Time `json:"at"`
	// Level is "error" or anything else, which reads as ordinary.
	Level   string `json:"level"`
	Message string `json:"message"`
}

// PlaybackLogs is what a client uploads, and what the history hands back.
type PlaybackLogs struct {
	Lines []PlaybackLogLine `json:"lines"`
	// HasError says at least one line is an error. Read from the lines, never
	// from the client: it decides whether a short play survives the pruning,
	// and that decision is the server's.
	HasError  bool      `json:"has_error"`
	UpdatedAt time.Time `json:"updated_at"`
	// Stats is what the client measured of itself, as it sent it.
	//
	// Volontairement opaque : le serveur ne lit aucune de ces clés, il les
	// range et les rend. Ce que sait mesurer un moteur de lecture n'est pas une
	// affaire de serveur, et lui faire connaître chaque champ obligerait à le
	// mettre à jour pour qu'un client puisse en mesurer un de plus.
	Stats json.RawMessage `json:"stats,omitempty"`
}

// AttachPlaybackLogs stores the client's log for the play this session is
// running (POST /api/playing/logs).
//
// Rattaché à la lecture **en cours**, et à elle seule : le client envoie avant
// son signal d'arrêt, donc la séance est encore ouverte. Chercher autrement —
// « la dernière ligne de cet appareil » — reviendrait à deviner, et à écrire le
// journal d'une séance sur une autre le jour où deux se suivent de près.
func AttachPlaybackLogs(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	if !config.PlaybackLogsEnabled() {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	var body struct {
		Lines []PlaybackLogLine `json:"lines"`
		Stats json.RawMessage   `json:"stats"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, playbackLogMaxBytes*2)).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid log payload")
		return
	}

	historyID, ok := playbackActivity.historyIDFor(sessionKey(bearerToken(r)), userID)
	if !ok {
		// Pas de lecture ouverte pour cette session : il n'y a rien à quoi
		// rattacher ces lignes. Ce n'est pas une erreur du client — une séance
		// a pu être fermée par le balayage pendant qu'il envoyait.
		w.WriteHeader(http.StatusNoContent)
		return
	}

	lines, hasError := normalizePlaybackLogLines(body.Lines)
	// Les mesures ont leur propre interrupteur : un serveur peut vouloir les
	// journaux sans faire interroger le moteur toutes les cinq secondes.
	// Écartées ici plutôt qu'au client, qui n'a pas le droit de lire ce réglage.
	var stats string
	if config.PlaybackStatsEnabled() {
		stats = normalizePlaybackStats(body.Stats)
	}
	// Ni lignes ni mesures : il n'y a rien à ranger. Une lecture peut n'avoir
	// que l'un des deux — un moteur qui ne mesure rien, une séance qui n'a rien
	// écrit — et chacun vaut le rangement à lui seul.
	if len(lines) == 0 && stats == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	encoded, err := json.Marshal(lines)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid log payload")
		return
	}

	if _, err := database.DB.Exec(`
		INSERT INTO playback_logs (history_id, has_error, line_count, body, stats, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(history_id) DO UPDATE SET
			has_error = excluded.has_error,
			line_count = excluded.line_count,
			body = excluded.body,
			-- Un envoi sans mesures ne doit pas effacer celles d'un envoi
			-- précédent : le journal part une première fois dès qu'un démarrage
			-- est abandonné, et une seconde à la fermeture de l'écran.
			stats = CASE WHEN excluded.stats != '' THEN excluded.stats ELSE playback_logs.stats END,
			updated_at = excluded.updated_at`,
		historyID, hasError, len(lines), string(encoded), stats, historyStamp(time.Now()),
	); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	pruneOldPlaybackLogs()
	w.WriteHeader(http.StatusNoContent)
}

// pruneOldPlaybackLogs keeps the table to the newest [playbackLogMaxRows] plays.
//
// À l'écriture plutôt que sur une minuterie : la table ne grossit qu'ici, donc
// c'est le seul moment où elle peut dépasser. Elle est bornée par construction,
// et le balayage porte sur quelques centaines de lignes.
func pruneOldPlaybackLogs() {
	if _, err := database.DB.Exec(`
		DELETE FROM playback_logs WHERE history_id NOT IN (
			SELECT history_id FROM playback_logs ORDER BY history_id DESC LIMIT ?
		)`, playbackLogMaxRows); err != nil {
		log.Printf("Activity: failed to prune playback logs: %v", err)
	}
}

// GetPlaybackLogs returns what a past play recorded
// (GET /api/admin/history/:id/logs, manage_users).
func GetPlaybackLogs(w http.ResponseWriter, _ *http.Request, ps httprouter.Params, _ int) {
	historyID, err := strconv.Atoi(ps.ByName("id"))
	if err != nil || historyID <= 0 {
		writeJSONError(w, http.StatusBadRequest, "Invalid history id")
		return
	}

	var (
		body      string
		stats     string
		hasError  bool
		updatedAt string
	)
	err = database.DB.QueryRow(
		`SELECT body, COALESCE(stats, ''), has_error, COALESCE(CAST(updated_at AS TEXT), '')
		 FROM playback_logs WHERE history_id = ?`,
		historyID,
	).Scan(&body, &stats, &hasError, &updatedAt)

	out := PlaybackLogs{Lines: []PlaybackLogLine{}}
	switch {
	case err == sql.ErrNoRows:
		// Une lecture sans journal est le cas ordinaire — un client plus ancien,
		// ou une app tuée avant d'envoyer. Une liste vide le dit mieux qu'un
		// 404, qui se confondrait avec une ligne d'historique absente.
	case err != nil:
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	default:
		if err := json.Unmarshal([]byte(body), &out.Lines); err != nil {
			out.Lines = []PlaybackLogLine{}
		}
		if stats != "" {
			out.Stats = json.RawMessage(stats)
		}
		out.HasError = hasError
		out.UpdatedAt = parseSQLiteTime(updatedAt)
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(out)
}

// normalizePlaybackLogLines trims what is stored and says whether it holds an
// error.
//
// Le plafond mord par la fin : quand une tranche dépasse, ce sont les lignes
// les plus anciennes qui partent. Ce qu'on vient chercher dans un journal est
// ce qui s'est passé juste avant l'arrêt, pas ce qui s'est passé à l'ouverture.
func normalizePlaybackLogLines(in []PlaybackLogLine) ([]PlaybackLogLine, bool) {
	if len(in) > playbackLogMaxLines {
		in = in[len(in)-playbackLogMaxLines:]
	}

	out := make([]PlaybackLogLine, 0, len(in))
	hasError := false
	size := 0
	for i := len(in) - 1; i >= 0; i-- {
		line := in[i]
		line.Message = strings.TrimSpace(line.Message)
		if line.Message == "" {
			continue
		}
		line.Message = truncateRunes(line.Message, playbackLogMaxLineLength)
		if line.Level != "error" {
			line.Level = "info"
		}
		size += len(line.Message) + 64 // l'horodatage et la ponctuation JSON
		if size > playbackLogMaxBytes {
			break
		}
		if line.Level == "error" {
			hasError = true
		}
		out = append(out, line)
	}

	// Le parcours était à l'envers pour que le plafond morde par le début ;
	// l'ordre rendu reste chronologique.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, hasError
}

// normalizePlaybackStats keeps a client's measurements only if they are a
// plausible JSON object of a reasonable size.
//
// Rendu tel quel plus tard, donc vérifié maintenant : une chaîne stockée sans
// être relue serait rendue au navigateur d'un administrateur comme du JSON,
// alors qu'elle pourrait être n'importe quoi. Le contenu des clés n'est pas
// inspecté — ce n'est pas l'affaire du serveur — mais la forme l'est.
func normalizePlaybackStats(raw json.RawMessage) string {
	if len(raw) == 0 || len(raw) > playbackStatsMaxBytes {
		return ""
	}
	var probe map[string]any
	if err := json.Unmarshal(raw, &probe); err != nil || len(probe) == 0 {
		return ""
	}
	// Réencodé depuis ce qui a été relu, et non recopié : ce qui sort est alors
	// du JSON que ce serveur a produit, sans espaces ni restes du client.
	encoded, err := json.Marshal(probe)
	if err != nil {
		return ""
	}
	return string(encoded)
}

// truncateRunes cuts on a character boundary.
//
// Couper sur un octet couperait un caractère accentué en deux — la moitié des
// messages du client sont en français — et produirait du JSON invalide en UTF-8,
// que l'encodeur remplacerait par des losanges au moment précis où on essaie de
// lire ce qui s'est passé.
func truncateRunes(s string, max int) string {
	if len(s) <= max {
		return s
	}
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max]) + "…"
}

// playbackHasErrorLog says whether a play recorded something that went wrong.
//
// C'est ce qui retient une ligne d'historique trop courte pour être gardée : la
// règle des trente secondes existe pour écarter les ouvertures accidentelles, et
// une lecture qui a échoué au démarrage n'en est pas une — c'est exactement
// celle qu'on voudra rouvrir.
func playbackHasErrorLog(historyID int64) bool {
	var found int
	err := database.DB.QueryRow(
		`SELECT 1 FROM playback_logs WHERE history_id = ? AND has_error = 1`, historyID,
	).Scan(&found)
	return err == nil
}
