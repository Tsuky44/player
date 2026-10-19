// Package watchlists porte les listes d'un compte (ADR-0070) : « à regarder
// plus tard », que chaque compte a d'office, et celles qu'il compose, qu'il
// peut montrer aux autres comptes du serveur.
//
// Un élément est un film ou une série, sur le serveur ou pas encore. Il est
// identifié d'abord par TMDB : un titre ajouté depuis le catalogue des
// demandes se rattache tout seul à la fiche du serveur le jour où elle arrive,
// parce que la lecture cherche la fiche qui porte le même tmdb_id. Ce qui ne
// se rattache à rien s'affiche sous l'instantané pris à l'ajout.
//
// Seul le propriétaire écrit. Une liste privée n'existe pas pour les autres :
// elle répond ErrNotFound, comme une liste qui n'existe pas.
//
// Le package ne connaît pas HTTP, ni les fiches telles que l'app les lit : le
// handler traduit les erreurs en codes d'état et joint les fiches aux
// éléments rattachés.
package watchlists

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"project-player/server/models"
)

var (
	// ErrNotFound : la liste ou l'élément n'existe pas, ou la liste est
	// privée et ce n'est pas celle du compte.
	ErrNotFound = errors.New("watch list not found")
	// ErrNotOwner : la liste est partagée, donc visible, mais seul son
	// propriétaire la modifie.
	ErrNotOwner = errors.New("watch list belongs to another account")
	// ErrInvalid : un nom, une description ou un titre refusés.
	ErrInvalid = errors.New("invalid watch list parameters")
	// ErrFixed : la liste « à regarder plus tard » ne se supprime pas.
	ErrFixed = errors.New("the watch later list cannot be deleted")
	// ErrTooMany : la borne de listes du compte ou d'éléments de la liste
	// est atteinte.
	ErrTooMany = errors.New("watch list limit reached")
)

const (
	// MaxListsPerOwner et MaxItemsPerList bornent ce qu'un compte écrit : une
	// liste partagée se lit par tous, elle ne doit pas devenir un dépôt.
	MaxListsPerOwner = 200
	MaxItemsPerList  = 1000
	MaxNameRunes     = 80
	MaxDescRunes     = 500
	maxTitleRunes    = 200
	// maxSharedLists borne la page des listes des autres : au-delà, elle ne
	// se lirait plus.
	maxSharedLists = 500
	// postersPerList est le nombre d'affiches de la vignette d'une liste.
	postersPerList = 4
)

// watchLaterName est le nom rangé en base. L'app affiche le sien, traduit :
// celui-ci ne sert qu'à un client qui ne connaît pas la sorte de liste.
const watchLaterName = "À regarder plus tard"

// tmdbPosterBase complète le chemin d'affiche que l'app envoie depuis le
// catalogue. Le serveur écrit l'adresse lui-même : une liste partagée ne doit
// pas faire charger aux autres une adresse choisie par celui qui l'a écrite.
const tmdbPosterBase = "https://image.tmdb.org/t/p/w500"

var (
	tmdbPosterPath = regexp.MustCompile(`^/[A-Za-z0-9_-]+\.(?:jpg|jpeg|png|webp)$`)
	releaseDate    = regexp.MustCompile(`^\d{4}(?:-\d{2}-\d{2})?$`)
)

// ListParams décrit une liste à créer ou à modifier.
type ListParams struct {
	Name        string
	Description string
	IsShared    bool
}

// CatalogTitle est un titre du catalogue TMDB, que le serveur n'a peut-être
// pas.
type CatalogTitle struct {
	MediaType   string
	TMDBID      int
	Title       string
	PosterPath  string
	ReleaseDate string
}

// Probe est le titre dont on demande dans quelles listes il est : une fiche du
// serveur (MediaID) ou un titre du catalogue (MediaType + TMDBID).
type Probe struct {
	MediaID   int
	MediaType string
	TMDBID    int
}

// Store lit et écrit les listes dans watch_lists et watch_list_items.
type Store struct {
	db  *sql.DB
	now func() time.Time
}

// New renvoie un Store sur db.
func New(db *sql.DB) *Store { return &Store{db: db, now: time.Now} }

// querier est ce que *sql.DB et *sql.Tx ont en commun ici.
type querier interface {
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row
}

func (s *Store) nowMillis() int64 { return s.now().UnixMilli() }

// normalizeList retire les blancs autour du nom et de la description, et
// refuse un nom vide, trop long ou fait de caractères de contrôle. Les
// longueurs se comptent en caractères, pour ne pas couper un nom accentué plus
// tôt qu'un autre.
func normalizeList(p ListParams) (ListParams, error) {
	p.Name = strings.Join(strings.Fields(p.Name), " ")
	p.Description = strings.TrimSpace(p.Description)
	if p.Name == "" || utf8.RuneCountInString(p.Name) > MaxNameRunes ||
		utf8.RuneCountInString(p.Description) > MaxDescRunes ||
		strings.IndexFunc(p.Name, func(r rune) bool { return !unicode.IsPrint(r) }) >= 0 {
		return ListParams{}, ErrInvalid
	}
	return p, nil
}

// normalizeCatalogTitle vérifie ce que l'app envoie d'un titre du catalogue.
// « tv » est le mot de TMDB pour une série : il est accepté et rangé « show ».
func normalizeCatalogTitle(t CatalogTitle) (CatalogTitle, error) {
	if t.MediaType == "tv" {
		t.MediaType = string(models.TypeShow)
	}
	t.Title = strings.Join(strings.Fields(t.Title), " ")
	t.PosterPath = strings.TrimSpace(t.PosterPath)
	t.ReleaseDate = strings.TrimSpace(t.ReleaseDate)
	if !listableType(t.MediaType) || t.TMDBID <= 0 || t.Title == "" ||
		utf8.RuneCountInString(t.Title) > maxTitleRunes ||
		(t.PosterPath != "" && !tmdbPosterPath.MatchString(t.PosterPath)) ||
		(t.ReleaseDate != "" && !releaseDate.MatchString(t.ReleaseDate)) {
		return CatalogTitle{}, ErrInvalid
	}
	return t, nil
}

// listableType : une liste nomme ce qu'on veut regarder, un film ou une série.
// La série mène à ses épisodes, et « Reprendre » sait où l'on en est.
func listableType(t string) bool {
	return t == string(models.TypeMovie) || t == string(models.TypeShow)
}

// EnsureWatchLater crée la liste « à regarder plus tard » du compte si elle
// n'existe pas encore. L'index unique partiel en garantit une seule, même si
// deux appareils la demandent en même temps.
func (s *Store) EnsureWatchLater(ownerID int) error {
	now := s.nowMillis()
	// NOT EXISTS d'abord : une insertion ignorée consommerait quand même un
	// identifiant AUTOINCREMENT, à chaque lecture des listes.
	if _, err := s.db.Exec(`
		INSERT OR IGNORE INTO watch_lists (owner_id, kind, name, created_at, updated_at)
		SELECT ?, ?, ?, ?, ?
		WHERE NOT EXISTS (SELECT 1 FROM watch_lists WHERE owner_id = ? AND kind = ?)`,
		ownerID, models.WatchListKindWatchLater, watchLaterName, now, now,
		ownerID, models.WatchListKindWatchLater,
	); err != nil {
		return fmt.Errorf("ensure watch later list: %w", err)
	}
	return nil
}

// Create enregistre une liste du compte.
func (s *Store) Create(ownerID int, p ListParams) (models.WatchList, error) {
	p, err := normalizeList(p)
	if err != nil {
		return models.WatchList{}, err
	}
	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM watch_lists WHERE owner_id = ?`, ownerID).Scan(&count); err != nil {
		return models.WatchList{}, fmt.Errorf("count watch lists: %w", err)
	}
	if count >= MaxListsPerOwner {
		return models.WatchList{}, ErrTooMany
	}
	now := s.nowMillis()
	res, err := s.db.Exec(`
		INSERT INTO watch_lists (owner_id, kind, name, description, is_shared, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		ownerID, models.WatchListKindCustom, p.Name, p.Description, p.IsShared, now, now)
	if err != nil {
		return models.WatchList{}, fmt.Errorf("insert watch list: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return models.WatchList{}, fmt.Errorf("watch list id: %w", err)
	}
	return s.summary(ownerID, int(id))
}

// Update renomme une liste, change sa description ou son partage. La liste
// « à regarder plus tard » ne garde que son partage : son nom est celui de
// l'app.
func (s *Store) Update(ownerID, listID int, p ListParams) (models.WatchList, error) {
	kind, err := s.ownedKind(s.db, ownerID, listID)
	if err != nil {
		return models.WatchList{}, err
	}
	now := s.nowMillis()
	if kind == models.WatchListKindWatchLater {
		_, err = s.db.Exec(`UPDATE watch_lists SET is_shared = ?, updated_at = ? WHERE id = ?`,
			p.IsShared, now, listID)
	} else {
		if p, err = normalizeList(p); err != nil {
			return models.WatchList{}, err
		}
		_, err = s.db.Exec(`
			UPDATE watch_lists SET name = ?, description = ?, is_shared = ?, updated_at = ?
			WHERE id = ?`, p.Name, p.Description, p.IsShared, now, listID)
	}
	if err != nil {
		return models.WatchList{}, fmt.Errorf("update watch list: %w", err)
	}
	return s.summary(ownerID, listID)
}

// Delete supprime une liste et ses éléments.
func (s *Store) Delete(ownerID, listID int) error {
	kind, err := s.ownedKind(s.db, ownerID, listID)
	if err != nil {
		return err
	}
	if kind == models.WatchListKindWatchLater {
		return ErrFixed
	}
	if _, err := s.db.Exec(`DELETE FROM watch_lists WHERE id = ?`, listID); err != nil {
		return fmt.Errorf("delete watch list: %w", err)
	}
	return nil
}

// ownedKind renvoie la sorte d'une liste du compte. Celle d'un autre est
// ErrNotOwner si elle est partagée, ErrNotFound sinon : une liste privée ne
// se devine pas.
func (s *Store) ownedKind(q querier, ownerID, listID int) (string, error) {
	var owner int
	var kind string
	var shared bool
	err := q.QueryRow(`SELECT owner_id, kind, is_shared FROM watch_lists WHERE id = ?`, listID).
		Scan(&owner, &kind, &shared)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("load watch list: %w", err)
	}
	if owner != ownerID {
		if shared {
			return "", ErrNotOwner
		}
		return "", ErrNotFound
	}
	return kind, nil
}
