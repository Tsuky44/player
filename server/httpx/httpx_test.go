package httpx

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestRefuseReservedAddresses(t *testing.T) {
	for address, refused := range map[string]bool{
		// Le service de métadonnées des hébergeurs cloud, et ses cousins.
		"169.254.169.254:80": true,
		"[fe80::1]:8096":     true,
		"0.0.0.0:8096":       true,
		"224.0.0.1:8096":     true,
		// Là où vit un serveur Emby de foyer.
		"192.168.1.20:8096": false,
		"10.0.0.5:8096":     false,
		"127.0.0.1:8096":    false,
		"203.0.113.9:443":   false,
	} {
		err := refuseReservedAddresses("tcp", address, nil)
		if refused != errors.Is(err, ErrReservedAddress) {
			t.Errorf("%s: err=%v, want refused=%v", address, err, refused)
		}
	}
}

func TestThrottledReadsAreReplayed(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	client := newClient(5 * time.Second)
	resp, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || calls.Load() != 2 {
		t.Fatalf("status %d after %d call(s), want 200 after 2", resp.StatusCode, calls.Load())
	}

	// Une écriture n'est jamais rejouée : elle a pu agir.
	calls.Store(0)
	resp, err = client.Post(server.URL, "text/plain", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests || calls.Load() != 1 {
		t.Fatalf("POST: status %d after %d call(s), want 429 after 1", resp.StatusCode, calls.Load())
	}
}
