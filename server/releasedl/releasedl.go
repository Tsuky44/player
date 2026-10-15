// Package releasedl va chercher les installeurs de l'app dans la GitHub Release
// qui porte la version du serveur (ADR-0062).
//
// L'image Docker n'embarque plus les APK, DMG et EXE : ils pesaient plus du
// tiers de son poids. Le serveur sait quelle version il est (buildinfo) et la
// Release `v<version>` porte les installeurs construits avec lui, donc c'est
// celle-là qu'il propose — ni la dernière publiée, ni une plus ancienne : une
// app et un serveur de la même version se parlent sans surprise.
//
// Tout passe par le disque : la liste de la Release est gardée dans un fichier,
// chaque installeur est téléchargé une fois à la première demande puis resservi
// depuis le cache. Un serveur qui perd Internet continue donc de proposer ce
// qu'il a déjà vu.
package releasedl

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"project-player/server/httpx"
)

// DefaultRepo est le dépôt dont les Releases portent les installeurs.
const DefaultRepo = "Tsuky44/player"

const (
	defaultAPI = "https://api.github.com"
	// La liste d'une Release ne change plus une fois publiée ; l'API non
	// authentifiée de GitHub, elle, est limitée à 60 requêtes par heure et par
	// adresse.
	listingTTL = 15 * time.Minute
	// Après un échec, on ne réessaie pas à chaque requête : un serveur sans
	// Internet attendrait la fin du délai à chaque affichage de la liste.
	retryDelay     = time.Minute
	listingTimeout = 10 * time.Second
)

// Asset est un fichier de la Release.
type Asset struct {
	Name      string    `json:"name"`
	Size      int64     `json:"size"`
	UpdatedAt time.Time `json:"updated_at"`
	URL       string    `json:"browser_download_url"`

	// tag est la Release d'où vient le fichier : le dossier de son cache.
	tag string
}

type release struct {
	Tag    string  `json:"tag_name"`
	Assets []Asset `json:"assets"`
}

// Config décrit une Source. Seuls Version et CacheDir sont obligatoires.
type Config struct {
	// Version est celle du serveur (buildinfo.Version).
	Version string
	// Repo vaut DefaultRepo quand il est vide.
	Repo string
	// APIBase vaut l'API de GitHub quand elle est vide ; les tests y mettent
	// leur propre serveur.
	APIBase  string
	CacheDir string
}

// Source rend les installeurs de la Release du serveur. La valeur nil est une
// Source désactivée : elle ne propose rien.
type Source struct {
	version  string
	repo     string
	apiBase  string
	cacheDir string

	mu         sync.Mutex
	current    *release
	freshUntil time.Time
	retryAt    time.Time
	locks      map[string]*sync.Mutex
}

// New prépare une Source. Elle ne touche pas au réseau avant la première
// demande.
func New(cfg Config) *Source {
	repo := cfg.Repo
	if repo == "" {
		repo = DefaultRepo
	}
	api := strings.TrimRight(cfg.APIBase, "/")
	if api == "" {
		api = defaultAPI
	}
	return &Source{
		version:  strings.TrimPrefix(strings.TrimSpace(cfg.Version), "v"),
		repo:     repo,
		apiBase:  api,
		cacheDir: cfg.CacheDir,
		locks:    map[string]*sync.Mutex{},
	}
}

var exactVersion = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// endpoint dit quelle Release demander. Une version `X.Y.Z` a sa Release
// `vX.Y.Z`. Une image de développement (`dev`, `main-<sha>`) n'en a pas : la
// plus récente est alors la seule réponse sensée.
func (s *Source) endpoint() (path, key string) {
	if exactVersion.MatchString(s.version) {
		tag := "v" + s.version
		return "/repos/" + s.repo + "/releases/tags/" + tag, tag
	}
	return "/repos/" + s.repo + "/releases/latest", "latest"
}

var errUnavailable = errors.New("la Release n'est pas joignable")

// Assets liste les fichiers de la Release du serveur, ou rien quand elle est
// introuvable et qu'aucune liste n'a jamais été gardée.
func (s *Source) Assets(ctx context.Context) []Asset {
	if s == nil {
		return nil
	}
	rel, err := s.release(ctx)
	if err != nil {
		return nil
	}
	return rel.Assets
}

// Find retrouve un fichier de la Release par son nom. Le nom doit figurer dans
// la liste : c'est ce qui borne ce que le serveur accepte de télécharger.
func (s *Source) Find(ctx context.Context, name string) (Asset, bool) {
	for _, a := range s.Assets(ctx) {
		if a.Name == name {
			return a, true
		}
	}
	return Asset{}, false
}

func (s *Source) release(ctx context.Context) (*release, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	if s.current != nil && now.Before(s.freshUntil) {
		return s.current, nil
	}
	if s.current == nil && now.Before(s.retryAt) {
		return nil, errUnavailable
	}

	rel, err := s.fetch(ctx)
	if err == nil {
		s.current = rel
		s.freshUntil = now.Add(listingTTL)
		s.writeListing(rel)
		s.prune(rel.Tag)
		return rel, nil
	}

	log.Printf("releasedl: liste de la Release %s indisponible: %v", s.version, err)
	if s.current == nil {
		s.current = s.readListing()
	}
	if s.current == nil {
		s.retryAt = now.Add(retryDelay)
		return nil, err
	}
	// On resert la dernière liste connue, et on réessaie dans une minute.
	s.freshUntil = now.Add(retryDelay)
	return s.current, nil
}

func (s *Source) fetch(ctx context.Context) (*release, error) {
	path, _ := s.endpoint()
	ctx, cancel := context.WithTimeout(ctx, listingTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.apiBase+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := httpx.Standard.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub a répondu %s", resp.Status)
	}

	var rel release
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&rel); err != nil {
		return nil, fmt.Errorf("liste illisible: %w", err)
	}
	if rel.Tag == "" {
		return nil, errors.New("Release sans tag")
	}
	tagAssets(&rel)
	return &rel, nil
}

func tagAssets(rel *release) {
	for i := range rel.Assets {
		rel.Assets[i].tag = rel.Tag
	}
}

func (s *Source) listingPath() string {
	_, key := s.endpoint()
	return filepath.Join(s.cacheDir, "listing-"+key+".json")
}

func (s *Source) writeListing(rel *release) {
	raw, err := json.Marshal(rel)
	if err != nil {
		return
	}
	if err := os.MkdirAll(s.cacheDir, 0o755); err != nil {
		log.Printf("releasedl: cache %s: %v", s.cacheDir, err)
		return
	}
	// Écrit puis renommé : un arrêt en plein écrit ne laisse pas une liste
	// tronquée que le démarrage suivant prendrait pour la bonne.
	tmp := s.listingPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		log.Printf("releasedl: écriture de la liste: %v", err)
		return
	}
	if err := os.Rename(tmp, s.listingPath()); err != nil {
		log.Printf("releasedl: écriture de la liste: %v", err)
		os.Remove(tmp)
	}
}

func (s *Source) readListing() *release {
	raw, err := os.ReadFile(s.listingPath())
	if err != nil {
		return nil // pas de liste gardée : rien à resservir
	}
	var rel release
	if json.Unmarshal(raw, &rel) != nil || rel.Tag == "" {
		return nil
	}
	tagAssets(&rel)
	return &rel
}

// prune supprime les installeurs des versions précédentes : une mise à jour du
// serveur ne doit pas laisser les anciens remplir le disque.
func (s *Source) prune(keepTag string) {
	entries, err := os.ReadDir(s.cacheDir)
	if err != nil {
		return // pas de cache encore : rien à nettoyer
	}
	for _, e := range entries {
		if e.IsDir() && e.Name() != keepTag {
			if err := os.RemoveAll(filepath.Join(s.cacheDir, e.Name())); err != nil {
				log.Printf("releasedl: nettoyage de %s: %v", e.Name(), err)
			}
		}
	}
}

func (s *Source) path(a Asset) string {
	return filepath.Join(s.cacheDir, filepath.Base(a.tag), filepath.Base(a.Name))
}

// Cached rend le chemin du fichier quand il est déjà sur le disque, entier.
func (s *Source) Cached(a Asset) (string, bool) {
	if s == nil {
		return "", false
	}
	path := s.path(a)
	info, err := os.Stat(path)
	if err != nil || info.IsDir() || (a.Size > 0 && info.Size() != a.Size) {
		return "", false
	}
	return path, true
}

func (s *Source) lockFor(name string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.locks[name]
	if !ok {
		l = &sync.Mutex{}
		s.locks[name] = l
	}
	return l
}

// Ensure rend le chemin local du fichier, en le téléchargeant si besoin. Deux
// demandes simultanées du même fichier n'en font qu'un téléchargement : la
// seconde attend, puis le trouve sur le disque.
func (s *Source) Ensure(ctx context.Context, a Asset) (string, error) {
	if s == nil {
		return "", errors.New("installeurs de la Release désactivés")
	}
	if path, ok := s.Cached(a); ok {
		return path, nil
	}
	lock := s.lockFor(a.Name)
	lock.Lock()
	defer lock.Unlock()
	if path, ok := s.Cached(a); ok {
		return path, nil
	}

	final := s.path(a)
	dir := filepath.Dir(final)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("dossier du cache: %w", err)
	}
	// `.tmp` : ni l'extension d'un installeur, ni un nom que Cached reconnaît,
	// donc un téléchargement coupé ne passe jamais pour le fichier entier.
	tmp, err := os.CreateTemp(dir, ".download-*.tmp")
	if err != nil {
		return "", fmt.Errorf("fichier temporaire: %w", err)
	}
	defer os.Remove(tmp.Name()) // sans effet une fois renommé

	if err := s.download(ctx, a, tmp); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("écriture de %s: %w", a.Name, err)
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		log.Printf("releasedl: chmod %s: %v", a.Name, err)
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		return "", fmt.Errorf("mise en place de %s: %w", a.Name, err)
	}
	return final, nil
}

func (s *Source) download(ctx context.Context, a Asset, dst io.Writer) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.URL, nil)
	if err != nil {
		return err
	}
	resp, err := httpx.Download.Do(req)
	if err != nil {
		return fmt.Errorf("téléchargement de %s: %w", a.Name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("téléchargement de %s: GitHub a répondu %s", a.Name, resp.Status)
	}
	written, err := io.Copy(dst, resp.Body)
	if err != nil {
		return fmt.Errorf("téléchargement de %s: %w", a.Name, err)
	}
	if a.Size > 0 && written != a.Size {
		return fmt.Errorf("téléchargement de %s: %d octets reçus sur %d", a.Name, written, a.Size)
	}
	return nil
}
