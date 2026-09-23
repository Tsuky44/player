// Package httpx holds the process-wide outbound HTTP clients.
//
// Every call to TMDB, MediaHub and TheIntroDB goes through one of the clients
// declared here so they all share a single connection pool. Building an
// http.Client per call — which is what the indexer and the request handlers
// used to do — gives each one its own idle-connection pool, so nothing is ever
// reused and every lookup pays a fresh TCP+TLS handshake to the same host.
// Against api.themoviedb.org that is 100–300 ms added to each call, and the
// detail screens make several in a row.
//
// Timeouts are the one thing that legitimately differs between callers, so the
// clients are split by deadline rather than by destination.
package httpx

import (
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// transport is shared by every client below. MaxIdleConnsPerHost is raised well
// above net/http's default of 2 because the traffic here is concentrated on a
// handful of hosts: with the default, a burst of parallel TMDB lookups closes
// and reopens connections instead of reusing them.
var transport = &http.Transport{
	Proxy:               http.ProxyFromEnvironment,
	MaxIdleConns:        64,
	MaxIdleConnsPerHost: 16,
	IdleConnTimeout:     90 * time.Second,
	ForceAttemptHTTP2:   true,
}

func newClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, Transport: retryOnThrottle{transport}}
}

// retryOnThrottle rejoue une lecture que l'hôte a refusée pour excès de
// requêtes (429), après le délai qu'il demande.
//
// TMDB limite le rythme par adresse, et une analyse de médiathèque enchaîne
// des centaines d'appels : un refus passager devenait une fiche sans affiche ni
// résumé, laissée pour compte jusqu'au prochain rattrapage. Seules les lectures
// sont rejouées — un POST peut avoir agi — et l'attente est bornée, parce que
// l'appelant attend derrière et que sa propre échéance court toujours.
type retryOnThrottle struct {
	base http.RoundTripper
}

const (
	throttleRetries = 2
	throttleMaxWait = 10 * time.Second
	throttleDefault = 2 * time.Second
)

func (t retryOnThrottle) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		return resp, err
	}
	for attempt := 0; attempt < throttleRetries && err == nil && resp.StatusCode == http.StatusTooManyRequests; attempt++ {
		wait := retryAfter(resp.Header.Get("Retry-After"))
		if wait > throttleMaxWait {
			return resp, nil
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		timer := time.NewTimer(wait)
		select {
		case <-req.Context().Done():
			timer.Stop()
			return nil, req.Context().Err()
		case <-timer.C:
		}
		resp, err = t.base.RoundTrip(req)
	}
	return resp, err
}

// retryAfter lit Retry-After en secondes ; absent ou illisible, un délai court.
func retryAfter(raw string) time.Duration {
	if seconds, err := strconv.Atoi(strings.TrimSpace(raw)); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second
	}
	if when, err := http.ParseTime(raw); err == nil {
		if d := time.Until(when); d > 0 {
			return d
		}
		return 0
	}
	return throttleDefault
}

var (
	// Fast serves screens that must degrade rather than stall: the caller falls
	// back to local-only data when the deadline is hit.
	Fast = newClient(3 * time.Second)

	// Standard is the default for TMDB metadata lookups (indexing, enrichment,
	// catalog details).
	Standard = newClient(12 * time.Second)

	// Catalog serves the request-catalog browsing endpoints, which page through
	// TMDB discover/search and tolerate a slightly longer wait.
	Catalog = newClient(15 * time.Second)

	// Long is for the MediaHub proxy, where the upstream does real work before
	// answering.
	Long = newClient(30 * time.Second)
)

// UserDirected sert les appels vers une adresse qu'un utilisateur a saisie
// lui-même : le serveur Emby de son compte.
//
// N'importe quel compte peut en saisir une, et c'est le serveur qui s'y
// connecte. Sans garde, c'était une façon de lui faire interroger ce qu'il est
// seul à pouvoir joindre — en premier lieu le service de métadonnées d'un
// hébergeur cloud (169.254.169.254), qui distribue des identifiants. Le réseau
// local et la machine elle-même restent permis : c'est là qu'est, d'ordinaire,
// le serveur Emby d'un foyer.
var UserDirected = &http.Client{
	Timeout: 30 * time.Second,
	Transport: &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout: 10 * time.Second,
			Control: refuseReservedAddresses,
		}).DialContext,
		MaxIdleConnsPerHost: 4,
		IdleConnTimeout:     90 * time.Second,
		ForceAttemptHTTP2:   true,
	},
}

// ErrReservedAddress est le refus de refuseReservedAddresses.
var ErrReservedAddress = errors.New("adresse réservée refusée")

// refuseReservedAddresses est appelé sur l'adresse effectivement composée,
// après la résolution DNS et après chaque redirection : un nom qui pointe sur
// une adresse interdite, ou une redirection vers elle, est refusé aussi.
func refuseReservedAddresses(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return ErrReservedAddress
	}
	if ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() {
		return ErrReservedAddress
	}
	return nil
}
