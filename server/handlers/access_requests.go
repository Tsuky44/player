package handlers

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
	"golang.org/x/crypto/bcrypt"
)

// Demandes d'accès — comment on entre sur un serveur qui ne vous connaît pas.
//
// L'invitation (ADR-0001) est poussée : un administrateur fabrique un lien et
// le fait parvenir. Cela suppose un canal hors de l'app, et que l'initiative
// vienne du serveur. La demande d'accès est le mouvement inverse : quelqu'un
// qui possède déjà un compte ailleurs sonne à la porte, un administrateur
// ouvre ou non. C'est ce qui permet à une même app de tenir plusieurs serveurs
// sans qu'aucun d'eux n'ait à connaître les autres.
//
// La forme est celle de l'appairage TV : demander → interroger → décider. Ce
// qui change, c'est la durée (un administrateur n'est pas dans la pièce) et le
// fait que l'approbation crée un compte au lieu d'en emprunter un.

// accessRequestTTL est la durée de vie d'une demande sans réponse. Une semaine,
// comme l'invitation : la personne qui décide peut très bien ne rouvrir l'app
// que le week-end, et une demande qui meurt en cinq minutes ne servirait qu'aux
// serveurs déjà administrés en continu.
const accessRequestTTL = 7 * 24 * time.Hour

// accessRequestPollInterval est le rythme conseillé au demandeur, en secondes.
// Plus lent que l'appairage TV : personne ne regarde l'écran en attendant.
const accessRequestPollInterval = 5

// maxPendingAccessRequests plafonne la file d'attente. La route est ouverte par
// nécessité — le demandeur n'a pas de compte — donc elle doit avoir un fond :
// sans ce plafond, n'importe qui pourrait remplir la table et noyer l'écran de
// l'administrateur sous des milliers de lignes.
const maxPendingAccessRequests = 50

const accessRequestReaperInterval = 6 * time.Hour

// AccessRequest est ce que voit l'administrateur. Le hash du mot de passe
// proposé n'en fait évidemment pas partie, et le code privé du demandeur non
// plus : le connaître permettrait de relever la session à sa place.
type AccessRequest struct {
	ID         int       `json:"id"`
	Username   string    `json:"username"`
	DeviceName string    `json:"device_name,omitempty"`
	Message    string    `json:"message,omitempty"`
	Status     string    `json:"status"` // pending | approved | denied | expired
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	DecidedBy  string    `json:"decided_by,omitempty"`
}

// AccessRequestTicket est la réponse à POST /api/auth/access/request : de quoi
// revenir chercher le verdict, et rien d'autre.
type AccessRequestTicket struct {
	// RequestCode est la poignée privée du demandeur sur sa demande. Jamais
	// affichée à l'administrateur, c'est le seul moyen de relever la session.
	RequestCode string `json:"request_code"`
	Username    string `json:"username"`
	ExpiresIn   int    `json:"expires_in"`
	Interval    int    `json:"interval"`
}

// AccessRequestVerdict est la réponse à POST /api/auth/access/poll.
//
// Status vaut "pending", "approved", "denied" ou "expired". Token et User ne
// sont remplis que sur "approved", et une seule fois : relever la session
// consomme la ligne.
type AccessRequestVerdict struct {
	Status string       `json:"status"`
	Token  string       `json:"token,omitempty"`
	User   *models.User `json:"user,omitempty"`
}

type accessRequestBody struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	DeviceName string `json:"device_name"`
	Message    string `json:"message"`
}

type accessPollBody struct {
	RequestCode string `json:"request_code"`
}

const accessRequestColumns = `a.id, a.username, a.device_name, a.message, a.status,
	a.created_at, a.expires_at, COALESCE(d.username, '')`

func scanAccessRequest(row rowScanner) (AccessRequest, error) {
	var req AccessRequest
	var createdAt, expiresAt sql.NullString
	if err := row.Scan(
		&req.ID, &req.Username, &req.DeviceName, &req.Message, &req.Status,
		&createdAt, &expiresAt, &req.DecidedBy,
	); err != nil {
		return AccessRequest{}, err
	}
	req.CreatedAt = scanSQLiteTime(createdAt)
	req.ExpiresAt = scanSQLiteTime(expiresAt)
	// L'expiration est dérivée à la lecture, comme pour les invitations : pas de
	// tâche de fond dont dépendrait l'exactitude de l'affichage.
	if req.Status == "pending" && !req.ExpiresAt.IsZero() && time.Now().After(req.ExpiresAt) {
		req.Status = "expired"
	}
	return req, nil
}

// RequestAccess ouvre une demande (POST /api/auth/access/request).
//
// Non authentifiée par nécessité : le demandeur n'a précisément pas de compte
// ici. Ce qu'elle accepte est donc délibérément pauvre — un identifiant, un mot
// de passe, deux libellés — et elle ne crée rien : tant que personne n'a
// approuvé, il n'existe pas de compte, pas de session, et rien à révoquer.
func RequestAccess(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var body accessRequestBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	username := strings.TrimSpace(body.Username)
	if username == "" || len(body.Password) < 4 {
		writeJSONError(w, http.StatusBadRequest,
			"Un nom d'utilisateur et un mot de passe d'au moins 4 caractères sont requis")
		return
	}
	if len(username) > 64 {
		writeJSONError(w, http.StatusBadRequest, "Nom d'utilisateur trop long")
		return
	}

	// Un serveur vierge n'a personne pour décider : la demande resterait en
	// attente jusqu'à son expiration sans que quiconque puisse la voir. Le
	// premier compte se crée par l'inscription, pas par la sonnette.
	empty, err := usersTableEmpty()
	if err != nil {
		log.Printf("RequestAccess: failed to count users: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if empty {
		writeJSONError(w, http.StatusForbidden,
			"Ce serveur n'a pas encore de compte propriétaire : créez-le d'abord")
		return
	}

	var taken bool
	if err := database.DB.QueryRow(
		"SELECT EXISTS(SELECT 1 FROM users WHERE username = ?)", username,
	).Scan(&taken); err != nil {
		log.Printf("RequestAccess: username lookup failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if taken {
		writeJSONError(w, http.StatusConflict, "Ce nom d'utilisateur est déjà pris sur ce serveur")
		return
	}

	// Une demande en attente sur le même identifiant : c'est la même personne
	// qui insiste, pas une nouvelle demande. Deux lignes n'apporteraient qu'un
	// doublon dans la liste de l'administrateur.
	var duplicate bool
	if err := database.DB.QueryRow(`
		SELECT EXISTS(
			SELECT 1 FROM access_requests
			WHERE username = ? AND status = 'pending' AND expires_at > datetime('now'))`,
		username,
	).Scan(&duplicate); err != nil {
		log.Printf("RequestAccess: duplicate lookup failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if duplicate {
		writeJSONError(w, http.StatusConflict,
			"Une demande est déjà en attente pour ce nom d'utilisateur")
		return
	}

	var pending int
	if err := database.DB.QueryRow(`
		SELECT COUNT(*) FROM access_requests
		WHERE status = 'pending' AND expires_at > datetime('now')`,
	).Scan(&pending); err != nil {
		log.Printf("RequestAccess: pending count failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if pending >= maxPendingAccessRequests {
		writeJSONError(w, http.StatusTooManyRequests,
			"Trop de demandes en attente sur ce serveur, réessayez plus tard")
		return
	}

	// Le mot de passe est haché tout de suite : la ligne en attente n'est pas un
	// compte, mais elle porte un secret d'utilisateur, et elle doit le porter
	// exactement comme la table users le ferait.
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("RequestAccess: hash failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	code, err := GenerateRandomToken()
	if err != nil {
		log.Printf("RequestAccess: code generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if _, err := database.DB.Exec(`
		INSERT INTO access_requests
			(request_code, username, password_hash, device_name, message, expires_at)
		VALUES (?, ?, ?, ?, ?, datetime('now', ?))`,
		code, username, string(passwordHash),
		clampText(body.DeviceName, 64), clampText(body.Message, 280),
		sqliteFuture(accessRequestTTL),
	); err != nil {
		log.Printf("RequestAccess: insert failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(AccessRequestTicket{
		RequestCode: code,
		Username:    username,
		ExpiresIn:   int(accessRequestTTL.Seconds()),
		Interval:    accessRequestPollInterval,
	})
}

// PollAccessRequest rend le verdict au demandeur (POST /api/auth/access/poll),
// et lui remet la session quand il y en a une.
//
// Non authentifiée pour la même raison que la demande, et sans danger pour la
// même raison que l'appairage TV : le code est un secret de 256 bits que seul
// l'appareil demandeur détient.
func PollAccessRequest(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var body accessPollBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	code := strings.TrimSpace(body.RequestCode)
	if code == "" {
		writeJSONError(w, http.StatusBadRequest, "request_code is required")
		return
	}

	var (
		id          int
		status      string
		createdUser sql.NullInt64
		token       sql.NullString
		expired     bool
	)
	err := database.DB.QueryRow(`
		SELECT id, status, created_user_id, session_token, expires_at <= datetime('now')
		FROM access_requests WHERE request_code = ?`, code,
	).Scan(&id, &status, &createdUser, &token, &expired)
	if err == sql.ErrNoRows {
		// Inconnue et déjà relevée se ressemblent volontairement.
		json.NewEncoder(w).Encode(AccessRequestVerdict{Status: "expired"})
		return
	}
	if err != nil {
		log.Printf("PollAccessRequest: query failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	switch status {
	case "denied":
		// Le refus est dit une fois, puis la ligne disparaît : la garder ne
		// ferait qu'entretenir un registre de qui a sonné pour rien.
		deleteAccessRequest(id)
		json.NewEncoder(w).Encode(AccessRequestVerdict{Status: "denied"})
		return
	case "approved":
		if !token.Valid || !createdUser.Valid {
			// Session déjà relevée sur un autre appareil.
			json.NewEncoder(w).Encode(AccessRequestVerdict{Status: "expired"})
			return
		}
		user, err := LoadUser(int(createdUser.Int64))
		if err != nil {
			log.Printf("PollAccessRequest: failed to load user %d: %v", createdUser.Int64, err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		// Usage unique : le jeton vit dans la table sessions à partir d'ici.
		deleteAccessRequest(id)
		json.NewEncoder(w).Encode(AccessRequestVerdict{
			Status: "approved",
			Token:  token.String,
			User:   &user,
		})
		return
	}

	// Une demande approuvée est honorée même passé son échéance : le délai
	// protège la demande sans réponse, pas la session qu'elle a produite.
	if expired {
		deleteAccessRequest(id)
		json.NewEncoder(w).Encode(AccessRequestVerdict{Status: "expired"})
		return
	}
	json.NewEncoder(w).Encode(AccessRequestVerdict{Status: "pending"})
}

// ListAccessRequests renvoie les demandes en attente (GET /api/access-requests).
//
// Ouverte à invite_users autant qu'à manage_users, pour la même raison que les
// invitations : accepter quelqu'un est exactement ce que fait déjà un lien
// d'invitation, et le gabarit borne ce que cela accorde.
func ListAccessRequests(w http.ResponseWriter, r *http.Request, _ httprouter.Params, _ int) {
	w.Header().Set("Content-Type", "application/json")

	rows, err := database.DB.Query(`
		SELECT ` + accessRequestColumns + `
		FROM access_requests a
		LEFT JOIN users d ON d.id = a.decided_by_user_id
		WHERE a.status = 'pending' AND a.expires_at > datetime('now')
		ORDER BY a.created_at ASC`)
	if err != nil {
		log.Printf("ListAccessRequests: query failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer rows.Close()

	requests := []AccessRequest{}
	for rows.Next() {
		req, err := scanAccessRequest(rows)
		if err != nil {
			log.Printf("ListAccessRequests: scan failed: %v", err)
			continue
		}
		requests = append(requests, req)
	}

	json.NewEncoder(w).Encode(requests)
}

// ApproveAccessRequest crée le compte et la session (POST /api/access-requests/:id/approve).
//
// Les droits accordés suivent la règle d'ADR-0001 : un administrateur choisit,
// un simple inviteur applique le gabarit qu'un administrateur lui a fixé. Sans
// cela, « accepter une demande » deviendrait le chemin détourné par lequel un
// inviteur se fabrique un administrateur.
func ApproveAccessRequest(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Identifiant de demande invalide")
		return
	}

	approver, err := LoadUser(userID)
	if err != nil {
		log.Printf("ApproveAccessRequest: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	permissions := approver.InviteGrants
	if approver.Permissions.ManageUsers {
		// Un administrateur peut promouvoir n'importe qui après coup : le
		// laisser choisir ici n'ouvre rien de neuf. Corps facultatif.
		permissions = models.DefaultPermissions()
		var body struct {
			Permissions *models.Permissions `json:"permissions"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil && body.Permissions != nil {
			permissions = *body.Permissions
		}
	}

	token, err := GenerateRandomToken()
	if err != nil {
		log.Printf("ApproveAccessRequest: token generation failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// Le compte, la session et la décision doivent atterrir ensemble : un compte
	// sans session laisse le demandeur devant un mot de passe qu'il croit refusé,
	// et une décision sans compte le fait attendre indéfiniment.
	tx, err := database.DB.Begin()
	if err != nil {
		log.Printf("ApproveAccessRequest: begin failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	defer tx.Rollback() //nolint:errcheck // sans effet une fois validée

	var username, passwordHash string
	err = tx.QueryRow(`
		SELECT username, password_hash FROM access_requests
		WHERE id = ? AND status = 'pending' AND expires_at > datetime('now')`, id,
	).Scan(&username, &passwordHash)
	if err == sql.ErrNoRows {
		writeJSONError(w, http.StatusNotFound, "Demande introuvable, expirée ou déjà traitée")
		return
	}
	if err != nil {
		log.Printf("ApproveAccessRequest: load failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// L'identifiant était libre au moment de la demande ; une semaine a pu
	// passer. C'est ici que la question se tranche pour de bon.
	var taken bool
	if err := tx.QueryRow(
		"SELECT EXISTS(SELECT 1 FROM users WHERE username = ?)", username,
	).Scan(&taken); err != nil {
		log.Printf("ApproveAccessRequest: username lookup failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if taken {
		writeJSONError(w, http.StatusConflict,
			"Ce nom d'utilisateur a été pris entre-temps : la demande doit être refusée")
		return
	}

	res, err := tx.Exec(`
		INSERT INTO users (
			username, password_hash, is_owner,
			perm_manage_settings, perm_manage_library, perm_manage_users,
			perm_delete_media, perm_invite_users, perm_request_media
		) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)`,
		username, passwordHash,
		permissions.ManageSettings, permissions.ManageLibrary, permissions.ManageUsers,
		permissions.DeleteMedia, permissions.InviteUsers, permissions.RequestMedia,
	)
	if err != nil {
		log.Printf("ApproveAccessRequest: user insert failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	newUserID, _ := res.LastInsertId()

	if _, err := tx.Exec(
		`INSERT INTO sessions (token, user_id) VALUES (?, ?)`, token, newUserID,
	); err != nil {
		log.Printf("ApproveAccessRequest: session insert failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if _, err := tx.Exec(`
		UPDATE access_requests
		SET status = 'approved', decided_at = CURRENT_TIMESTAMP,
		    decided_by_user_id = ?, created_user_id = ?, session_token = ?
		WHERE id = ? AND status = 'pending'`, userID, newUserID, token, id,
	); err != nil {
		log.Printf("ApproveAccessRequest: update failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("ApproveAccessRequest: commit failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	user, err := LoadUser(int(newUserID))
	if err != nil {
		log.Printf("ApproveAccessRequest: failed to load new user %d: %v", newUserID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(user)
}

// DenyAccessRequest refuse une demande (POST /api/access-requests/:id/deny).
//
// La ligne survit au refus le temps que le demandeur vienne lire le verdict :
// une demande qui disparaît sans un mot est indistinguable d'une demande
// perdue, et la personne resonne.
func DenyAccessRequest(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	id, err := strconv.Atoi(ps.ByName("id"))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "Identifiant de demande invalide")
		return
	}

	res, err := database.DB.Exec(`
		UPDATE access_requests
		SET status = 'denied', decided_at = CURRENT_TIMESTAMP, decided_by_user_id = ?,
		    password_hash = ''
		WHERE id = ? AND status = 'pending'`, userID, id)
	if err != nil {
		log.Printf("DenyAccessRequest: update failed: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONError(w, http.StatusNotFound, "Demande introuvable ou déjà traitée")
		return
	}

	w.Write([]byte(`{"status": "success"}`))
}

func deleteAccessRequest(id int) {
	if _, err := database.DB.Exec("DELETE FROM access_requests WHERE id = ?", id); err != nil {
		log.Printf("Access request: failed to delete %d: %v", id, err)
	}
}

// clampText coupe un libellé libre à ce qu'un écran peut en montrer. Les deux
// champs concernés sont décoratifs, donc tronquer vaut mieux que refuser.
func clampText(raw string, max int) string {
	value := strings.TrimSpace(raw)
	if len(value) > max {
		return value[:max]
	}
	return value
}

// StartAccessRequestReaper balaie les demandes mortes. L'expiration est
// appliquée à la lecture, donc ceci ne fait que récupérer des lignes.
func StartAccessRequestReaper() {
	go func() {
		for {
			purgeExpiredAccessRequests()
			time.Sleep(accessRequestReaperInterval)
		}
	}()
}

func purgeExpiredAccessRequests() {
	grace := "-" + strconv.Itoa(int(accessRequestTTL.Seconds())) + " seconds"

	// Une demande approuvée mais jamais relevée laisse une session dont personne
	// ne détient le jeton. Elle s'éteindrait d'elle-même au bout de quatre-vingt
	// -dix jours ; la tuer avec sa demande, c'est le même ménage plus tôt.
	if _, err := database.DB.Exec(`
		DELETE FROM sessions
		WHERE token IN (
			SELECT session_token FROM access_requests
			WHERE session_token IS NOT NULL AND expires_at <= datetime('now', ?)
		)`, grace); err != nil {
		log.Printf("Access request reaper: orphan session sweep: %v", err)
	}

	res, err := database.DB.Exec(
		`DELETE FROM access_requests WHERE expires_at <= datetime('now', ?)`, grace)
	if err != nil {
		log.Printf("Access request reaper: %v", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		log.Printf("Access request reaper: removed %d stale request(s)", n)
	}
}
