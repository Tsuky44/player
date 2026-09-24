// Package sharelinks porte les liens de partage publics d'un film ou d'un
// épisode (ADR-0037) : leur création, leurs règles d'ouverture et leur fin.
//
// Un lien s'ouvre sans compte. Ce qui le protège tient ici, et seulement ici :
//
//   - son code n'est gardé qu'en empreinte SHA-256, comme les jetons de session
//     (ADR-0032) ;
//   - un mot de passe facultatif, haché avec bcrypt ;
//   - une échéance facultative ;
//   - l'usage unique : le premier navigateur qui ouvre le lien le réserve, et
//     le lien est détruit quand ce navigateur a vu le média.
//
// Le package ne connaît ni HTTP ni les tickets de lecture : le handler traduit
// ses erreurs en codes d'état et délivre les tickets qu'il autorise.
package sharelinks

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

var (
	// ErrNotFound : aucun lien ne porte ce code, ou il a été supprimé.
	ErrNotFound = errors.New("share link not found")
	// ErrGone : le lien a existé, mais il a expiré ou il a été vu.
	ErrGone = errors.New("share link expired or already watched")
	// ErrPassword : le lien exige un mot de passe, et ce n'est pas celui-là.
	ErrPassword = errors.New("wrong share link password")
	// ErrClaimed : un lien à usage unique déjà réservé par un autre navigateur.
	ErrClaimed = errors.New("share link already in use elsewhere")
	// ErrInvalid : des paramètres de création refusés.
	ErrInvalid = errors.New("invalid share link parameters")
)

// ConsumedGrace est le temps pendant lequel le navigateur qui a vu un lien à
// usage unique peut encore renouveler ses tickets. Le lien est détruit au seuil
// « vu » (90 %), pas au générique de fin : sur un film de trois heures, les
// dix derniers pour cent durent plus longtemps qu'un ticket (15 min).
const ConsumedGrace = time.Hour

// Lifetimes sont les durées de validité proposées, en heures ; 0 veut dire
// « sans échéance ». Une liste fermée plutôt qu'une durée libre : c'est ce que
// l'app propose, et une valeur absurde n'a pas à atteindre la base.
var Lifetimes = []int{0, 24, 7 * 24, 30 * 24}

// maxPasswordBytes est la limite de bcrypt : au-delà, il ignore la suite, et
// deux mots de passe différents deviendraient le même.
const maxPasswordBytes = 72

// Share est un lien tel que la base le connaît.
type Share struct {
	ID          int
	MediaID     int
	CreatedBy   int
	HasPassword bool
	SingleUse   bool
	// ExpiresAt est zéro pour un lien sans échéance.
	ExpiresAt time.Time
	// Claimed : un navigateur a réservé ce lien à usage unique.
	Claimed bool
	// ConsumedAt est zéro tant que le lien n'a pas été vu.
	ConsumedAt time.Time
	Views      int
	CreatedAt  time.Time

	passwordHash string
	viewerDigest string
}

// Status résume l'état du lien pour l'affichage : "active", "expired" ou
// "watched".
func (s Share) Status(now time.Time) string {
	switch {
	case !s.ConsumedAt.IsZero():
		return "watched"
	case !s.ExpiresAt.IsZero() && !now.Before(s.ExpiresAt):
		return "expired"
	default:
		return "active"
	}
}

// CreateParams décrit un nouveau lien.
type CreateParams struct {
	UserID        int
	MediaID       int
	Password      string
	SingleUse     bool
	LifetimeHours int
}

// Store lit et écrit les liens dans la table media_shares.
type Store struct {
	db  *sql.DB
	now func() time.Time
}

// New renvoie un Store sur db.
func New(db *sql.DB) *Store { return &Store{db: db, now: time.Now} }

// Create enregistre un lien et renvoie son code, la seule fois où il existe en
// clair.
func (s *Store) Create(p CreateParams) (string, Share, error) {
	if p.UserID <= 0 || p.MediaID <= 0 || len(p.Password) > maxPasswordBytes || !allowedLifetime(p.LifetimeHours) {
		return "", Share{}, ErrInvalid
	}
	passwordHash := ""
	if p.Password != "" {
		hash, err := bcrypt.GenerateFromPassword([]byte(p.Password), bcrypt.DefaultCost)
		if err != nil {
			return "", Share{}, fmt.Errorf("hash share password: %w", err)
		}
		passwordHash = string(hash)
	}
	code, err := randomToken(16)
	if err != nil {
		return "", Share{}, fmt.Errorf("generate share code: %w", err)
	}

	now := s.now()
	var expires sql.NullInt64
	if p.LifetimeHours > 0 {
		expires = sql.NullInt64{Int64: now.Add(time.Duration(p.LifetimeHours) * time.Hour).Unix(), Valid: true}
	}
	res, err := s.db.Exec(`
		INSERT INTO media_shares (code_digest, media_id, created_by, password_hash, single_use, expires_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		digest(code), p.MediaID, p.UserID, passwordHash, p.SingleUse, expires, now.Unix())
	if err != nil {
		return "", Share{}, fmt.Errorf("insert share: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return "", Share{}, fmt.Errorf("share id: %w", err)
	}
	share, err := s.byID(int(id))
	return code, share, err
}

// Find renvoie le lien que code désigne, qu'il soit encore utilisable ou non.
func (s *Store) Find(code string) (Share, error) {
	if !plausibleToken(code) {
		return Share{}, ErrNotFound
	}
	return s.scanOne(`WHERE code_digest = ?`, digest(code))
}

// Open vérifie qu'un visiteur peut lire le lien : encore valide, bon mot de
// passe, et, pour un lien à usage unique, pas réservé par un autre navigateur.
//
// viewer est le jeton que ce navigateur a reçu à sa première ouverture (vide
// la première fois). Open renvoie celui qu'il doit présenter désormais : c'est
// lui qui réserve un lien à usage unique, et qui autorise ensuite Authorize.
func (s *Store) Open(code, password, viewer string) (Share, string, error) {
	share, err := s.Find(code)
	if err != nil {
		return Share{}, "", err
	}
	if share.Status(s.now()) != "active" {
		return Share{}, "", ErrGone
	}
	if share.HasPassword {
		if bcrypt.CompareHashAndPassword([]byte(share.passwordHash), []byte(password)) != nil {
			return Share{}, "", ErrPassword
		}
	}

	if share.SingleUse {
		viewer, err = s.claim(share, viewer)
		if err != nil {
			return Share{}, "", err
		}
	} else if !plausibleToken(viewer) {
		// Un lien permanent ne réserve rien, mais le navigateur garde quand même
		// un jeton : Authorize le demande à tous, un seul chemin.
		if viewer, err = randomToken(16); err != nil {
			return Share{}, "", fmt.Errorf("generate viewer token: %w", err)
		}
	}

	if _, err := s.db.Exec(`UPDATE media_shares SET views = views + 1 WHERE id = ?`, share.ID); err != nil {
		return Share{}, "", fmt.Errorf("count share view: %w", err)
	}
	share.Views++
	return share, viewer, nil
}

// claim réserve un lien à usage unique au navigateur qui présente viewer, ou
// vérifie qu'il est déjà à lui.
func (s *Store) claim(share Share, viewer string) (string, error) {
	if share.viewerDigest != "" {
		if plausibleToken(viewer) && digest(viewer) == share.viewerDigest {
			return viewer, nil
		}
		return "", ErrClaimed
	}
	token, err := randomToken(16)
	if err != nil {
		return "", fmt.Errorf("generate viewer token: %w", err)
	}
	// La condition sur viewer_digest fait de la réservation une écriture
	// atomique : deux navigateurs qui ouvrent le lien au même instant ne
	// peuvent pas le réserver tous les deux.
	res, err := s.db.Exec(`UPDATE media_shares SET viewer_digest = ? WHERE id = ? AND viewer_digest = ''`,
		digest(token), share.ID)
	if err != nil {
		return "", fmt.Errorf("claim share: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return "", ErrClaimed
	}
	return token, nil
}

// Authorize vérifie qu'un navigateur qui a ouvert le lien peut continuer à le
// lire : renouveler son ticket, signaler sa position.
//
// Un lien vu reste lisible ConsumedGrace pour le navigateur qui l'a vu, le
// temps du générique ; un lien expiré, supprimé ou vu depuis plus longtemps ne
// l'est plus pour personne.
func (s *Store) Authorize(code, viewer string) (Share, error) {
	share, err := s.Find(code)
	if err != nil {
		return Share{}, err
	}
	now := s.now()
	switch share.Status(now) {
	case "expired":
		return Share{}, ErrGone
	case "watched":
		if now.Sub(share.ConsumedAt) >= ConsumedGrace {
			return Share{}, ErrGone
		}
	}
	if share.SingleUse && (!plausibleToken(viewer) || digest(viewer) != share.viewerDigest) {
		return Share{}, ErrClaimed
	}
	return share, nil
}

// Consume détruit un lien à usage unique : il vient d'être vu. Renvoie true
// si c'est cet appel qui l'a détruit.
func (s *Store) Consume(id int) (bool, error) {
	res, err := s.db.Exec(`
		UPDATE media_shares SET consumed_at = ?
		WHERE id = ? AND single_use = 1 AND consumed_at IS NULL`, s.now().Unix(), id)
	if err != nil {
		return false, fmt.Errorf("consume share %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("consume share %d: %w", id, err)
	}
	return n > 0, nil
}

// ListByUser renvoie les liens créés par userID, du plus récent au plus ancien.
func (s *Store) ListByUser(userID int) ([]Share, error) {
	rows, err := s.db.Query(`SELECT `+shareColumns+` FROM media_shares
		WHERE created_by = ? ORDER BY created_at DESC, id DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("list shares: %w", err)
	}
	defer rows.Close()
	var out []Share
	for rows.Next() {
		share, err := scanShare(rows)
		if err != nil {
			return nil, fmt.Errorf("scan share: %w", err)
		}
		out = append(out, share)
	}
	return out, rows.Err()
}

// Delete supprime le lien id, s'il appartient à userID.
func (s *Store) Delete(id, userID int) error {
	res, err := s.db.Exec(`DELETE FROM media_shares WHERE id = ? AND created_by = ?`, id, userID)
	if err != nil {
		return fmt.Errorf("delete share %d: %w", id, err)
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteAllBy supprime tous les liens de userID et renvoie leurs ids, pour
// que l'appelant révoque les lectures qu'ils avaient ouvertes.
func (s *Store) DeleteAllBy(userID int) ([]int, error) {
	shares, err := s.ListByUser(userID)
	if err != nil {
		return nil, err
	}
	if _, err := s.db.Exec(`DELETE FROM media_shares WHERE created_by = ?`, userID); err != nil {
		return nil, fmt.Errorf("delete shares of %d: %w", userID, err)
	}
	ids := make([]int, 0, len(shares))
	for _, share := range shares {
		ids = append(ids, share.ID)
	}
	return ids, nil
}

const shareColumns = `id, media_id, created_by, password_hash, single_use, expires_at,
	viewer_digest, consumed_at, views, created_at`

type rowScanner interface{ Scan(dest ...any) error }

func scanShare(row rowScanner) (Share, error) {
	var share Share
	var expires, consumed sql.NullInt64
	var created int64
	err := row.Scan(&share.ID, &share.MediaID, &share.CreatedBy, &share.passwordHash, &share.SingleUse,
		&expires, &share.viewerDigest, &consumed, &share.Views, &created)
	if err != nil {
		return Share{}, err
	}
	share.HasPassword = share.passwordHash != ""
	share.Claimed = share.viewerDigest != ""
	if expires.Valid {
		share.ExpiresAt = time.Unix(expires.Int64, 0).UTC()
	}
	if consumed.Valid {
		share.ConsumedAt = time.Unix(consumed.Int64, 0).UTC()
	}
	share.CreatedAt = time.Unix(created, 0).UTC()
	return share, nil
}

func (s *Store) byID(id int) (Share, error) { return s.scanOne(`WHERE id = ?`, id) }

func (s *Store) scanOne(where string, arg any) (Share, error) {
	share, err := scanShare(s.db.QueryRow(`SELECT `+shareColumns+` FROM media_shares `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return Share{}, ErrNotFound
	}
	if err != nil {
		return Share{}, fmt.Errorf("load share: %w", err)
	}
	return share, nil
}

func allowedLifetime(hours int) bool {
	for _, allowed := range Lifetimes {
		if hours == allowed {
			return true
		}
	}
	return false
}

// randomToken renvoie n octets d'aléa en base64url, sans remplissage.
func randomToken(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// plausibleToken écarte avant tout accès à la base ce qui ne peut pas être un
// jeton de randomToken(16) : 22 caractères base64url.
func plausibleToken(token string) bool {
	if len(token) != 22 {
		return false
	}
	return strings.IndexFunc(token, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) < 0
}

func digest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
