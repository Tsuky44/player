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
	"net/http"
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
	return &http.Client{Timeout: timeout, Transport: transport}
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
