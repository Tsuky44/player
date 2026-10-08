package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Le client HTTP d'Emby, et l'index qui relie ses éléments aux contenus
// d'Onyx par identité (TMDB, saison, épisode). Voir emby_sync.go.

// ==================== CLIENT EMBY ====================

func embyAuthorization(deviceID string) string {
	return fmt.Sprintf(`Emby Client="Onyx", Device="Onyx Server", DeviceId="%s", Version="1.0.0"`, deviceID)
}

func embyRequest(ctx context.Context, base, token, deviceID, method, path string, query url.Values, body, out any) error {
	target := base + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Emby-Authorization", embyAuthorization(deviceID))
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("X-Emby-Token", token)
	}
	resp, err := embyHTTP.Do(req)
	if err != nil {
		// Le détail reste dans le journal. Renvoyé à l'appelant, il disait si
		// une adresse du réseau interne refuse la connexion ou ne répond pas —
		// de quoi cartographier ce réseau depuis n'importe quel compte.
		log.Printf("Emby: %s %s: %v", method, base, err)
		return errors.New("Emby injoignable à cette adresse")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return &embyStatusError{resp.StatusCode, errEmbyAuth.Error()}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &embyStatusError{resp.StatusCode, fmt.Sprintf("Emby a répondu %d sur %s", resp.StatusCode, path)}
	}
	if out == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("Réponse Emby illisible : %w", err)
	}
	return nil
}

func (l embyLink) call(ctx context.Context, method, path string, query url.Values, body, out any) error {
	return embyRequest(ctx, l.url, l.token, l.deviceID, method, path, query, body, out)
}

func isEmbyAuthError(err error) bool {
	var status *embyStatusError
	return errors.As(err, &status) && (status.status == http.StatusUnauthorized || status.status == http.StatusForbidden)
}

type embyAuthResult struct {
	AccessToken string `json:"AccessToken"`
	User        struct {
		ID   string `json:"Id"`
		Name string `json:"Name"`
	} `json:"User"`
}

func embyAuthenticate(ctx context.Context, base, deviceID, username, password string) (embyAuthResult, error) {
	var result embyAuthResult
	err := embyRequest(ctx, base, "", deviceID, http.MethodPost, "/Users/AuthenticateByName", nil,
		map[string]string{"Username": username, "Pw": password}, &result)
	if isEmbyAuthError(err) {
		return result, errors.New("Nom d’utilisateur ou mot de passe Emby incorrect")
	}
	if err != nil {
		return result, err
	}
	if result.AccessToken == "" || result.User.ID == "" {
		return result, errors.New("Ce serveur ne ressemble pas à un serveur Emby")
	}
	return result, nil
}

// embyItems lit toutes les pages d'une requête sur la bibliothèque de l'utilisateur.
func (l embyLink) items(ctx context.Context, path string, query url.Values) ([]embyItem, error) {
	var all []embyItem
	for start := 0; ; start += embyPage {
		query.Set("StartIndex", strconv.Itoa(start))
		query.Set("Limit", strconv.Itoa(embyPage))
		var page embyItemsPage
		if err := l.call(ctx, http.MethodGet, path, query, nil, &page); err != nil {
			return nil, err
		}
		all = append(all, page.Items...)
		if len(page.Items) < embyPage || len(all) >= page.TotalRecordCount {
			return all, nil
		}
	}
}

func embyLibraryQuery(types string) url.Values {
	return url.Values{
		"Recursive":        {"true"},
		"IncludeItemTypes": {types},
		"Fields":           {"ProviderIds"},
		"EnableImages":     {"false"},
	}
}

func providerTMDB(ids map[string]string) int {
	for key, value := range ids {
		if strings.EqualFold(key, "tmdb") {
			if id, err := strconv.Atoi(strings.TrimSpace(value)); err == nil && id > 0 {
				return id
			}
		}
	}
	return 0
}

func parseEmbyDate(raw string) time.Time {
	if raw == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil || t.Year() < 1971 {
		return time.Time{}
	}
	return t.UTC()
}

// ==================== INDEX ====================

func (l embyLink) buildIndex(ctx context.Context) (*embyIndex, error) {
	idx := &embyIndex{
		builtAt:    time.Now(),
		movies:     map[int]string{},
		series:     map[int]string{},
		seriesTMDB: map[string]int{},
		episodes:   map[string]map[[2]int]string{},
	}
	path := "/Users/" + url.PathEscape(l.embyUserID) + "/Items"
	movies, err := l.items(ctx, path, embyLibraryQuery("Movie"))
	if err != nil {
		return nil, err
	}
	for _, m := range movies {
		if tmdb := providerTMDB(m.ProviderIds); tmdb > 0 {
			idx.movies[tmdb] = m.ID
		}
	}
	shows, err := l.items(ctx, path, embyLibraryQuery("Series"))
	if err != nil {
		return nil, err
	}
	for _, s := range shows {
		if tmdb := providerTMDB(s.ProviderIds); tmdb > 0 {
			idx.series[tmdb] = s.ID
			idx.seriesTMDB[s.ID] = tmdb
		}
	}
	return idx, nil
}

func (l embyLink) episodeIndex(ctx context.Context, idx *embyIndex, seriesID string) (map[[2]int]string, error) {
	if eps, ok := idx.episodes[seriesID]; ok {
		return eps, nil
	}
	query := url.Values{
		"UserId":         {l.embyUserID},
		"EnableImages":   {"false"},
		"EnableUserData": {"false"},
	}
	items, err := l.items(ctx, "/Shows/"+url.PathEscape(seriesID)+"/Episodes", query)
	if err != nil {
		return nil, err
	}
	eps := map[[2]int]string{}
	for _, e := range items {
		if e.ParentIndexNumber != nil && e.IndexNumber != nil {
			eps[[2]int{*e.ParentIndexNumber, *e.IndexNumber}] = e.ID
		}
	}
	idx.episodes[seriesID] = eps
	return eps, nil
}

func (l embyLink) resolve(ctx context.Context, idx *embyIndex, e PortableProgress) (string, error) {
	if e.Type == "movie" {
		return idx.movies[e.TMDBID], nil
	}
	seriesID := idx.series[e.TMDBID]
	if seriesID == "" {
		return "", nil
	}
	eps, err := l.episodeIndex(ctx, idx, seriesID)
	if err != nil {
		return "", err
	}
	return eps[[2]int{e.Season, e.Episode}], nil
}
