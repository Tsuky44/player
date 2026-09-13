package streaming

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

var playlistURI = regexp.MustCompile(`URI="([^"]*)"`)
var playlistFile = regexp.MustCompile(`^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$`)

// ProtectPlaylist covers variant/segment lines and every URI attribute,
// including EXT-X-MEDIA and EXT-X-MAP. Refuse foreign or escaping resources
// rather than sending a bearer secret to an arbitrary host.
func ProtectPlaylist(playlist, token string) (string, error) {
	if len(token) != 43 {
		return "", errors.New("missing playlist authorization")
	}
	protect := func(raw string) (string, error) {
		u, err := url.Parse(raw)
		if err != nil || u.IsAbs() || u.Host != "" || u.User != nil || u.Fragment != "" || !playlistFile.MatchString(u.Path) || strings.Contains(u.Path, "..") {
			return "", errors.New("non-local playlist resource")
		}
		q := u.Query()
		q.Set("ticket", token)
		u.RawQuery = q.Encode()
		return u.String(), nil
	}
	lines := strings.Split(playlist, "\n")
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "#") {
			secured, err := protect(line)
			if err != nil {
				return "", err
			}
			lines[i] = secured
			continue
		}
		var failure error
		if strings.Count(line, "URI=") != len(playlistURI.FindAllString(line, -1)) {
			return "", errors.New("malformed playlist resource")
		}
		lines[i] = playlistURI.ReplaceAllStringFunc(line, func(attribute string) string {
			secured, err := protect(playlistURI.FindStringSubmatch(attribute)[1])
			if err != nil {
				failure = err
				return ""
			}
			return `URI="` + secured + `"`
		})
		if failure != nil {
			return "", failure
		}
	}
	return strings.Join(lines, "\n"), nil
}
