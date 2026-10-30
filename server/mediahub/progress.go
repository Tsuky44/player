package mediahub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
)

// Download est le téléchargement en cours d'un titre, tel que MediaHub le lit
// chez Radarr, Sonarr ou sorraa.
type Download struct {
	Progress     float64 `json:"progress"`
	TimeLeft     *string `json:"timeleft"`
	Speed        *string `json:"speed"`
	Size         *string `json:"size"`
	SizeLeft     *string `json:"sizeLeft"`
	ReleaseTitle *string `json:"releaseTitle"`
}

// Import est la copie d'un téléchargement terminé dans la bibliothèque.
type Import struct {
	ReleaseName string  `json:"releaseName"`
	Progress    float64 `json:"progress"`
	Files       int     `json:"files"`
	FilesDone   int     `json:"filesDone"`
	Size        string  `json:"size"`
	SizeDone    string  `json:"sizeDone"`
	SizeLeft    string  `json:"sizeLeft"`
	Current     *string `json:"current"`
	Failed      bool    `json:"failed"`
	Message     *string `json:"message"`
}

// Progress est le suivi d'un titre (GET /progress/:tmdbId) : les widgets de
// téléchargement et d'import de MediaHub, sans rien recalculer côté Onyx.
type Progress struct {
	Active      bool      `json:"active"`
	Downloading bool      `json:"downloading"`
	Download    *Download `json:"download"`
	Imports     []Import  `json:"imports"`
}

// Progress rend le suivi d'un titre au nom du compte. ErrUnsupported dit que
// le compagnon n'a pas cette route (OnyxHub, ou un MediaHub plus ancien).
func (c Client) Progress(ctx context.Context, as Account, tmdbID int, mediaType string) (Progress, error) {
	dialect, err := c.dialect(ctx)
	if err != nil {
		return Progress{}, err
	}
	if dialect != DialectV1 {
		return Progress{}, ErrUnsupported
	}
	raw, err := c.call(ctx, http.MethodGet, V1Path+"/progress/"+strconv.Itoa(tmdbID), as, url.Values{"type": {mediaType}}, nil)
	var status *StatusError
	if errors.As(err, &status) && status.Status == http.StatusNotFound {
		return Progress{}, ErrUnsupported
	}
	if err != nil {
		return Progress{}, err
	}
	var progress Progress
	if err := json.Unmarshal(raw, &progress); err != nil {
		return Progress{}, fmt.Errorf("mediahub: decode progress: %w", err)
	}
	if progress.Imports == nil {
		progress.Imports = []Import{}
	}
	return progress, nil
}
