package mediahub

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func strptr(s string) *string { return &s }

func TestLotStatusFollowsTheSlowestSeason(t *testing.T) {
	cases := []struct {
		statuses []string
		want     string
	}{
		{[]string{"available"}, "available"},
		{[]string{"available", "available"}, "available"},
		{[]string{"available", "pending"}, "partial"},
		{[]string{"partial"}, "partial"},
		{[]string{"processing", "approved"}, "approved"},
		{[]string{"pending", "processing"}, "pending"},
		{[]string{"declined", "approved"}, "approved"},
		{[]string{"declined", "declined"}, "declined"},
		{[]string{"available", "declined"}, "partial"},
		// Un statut d'une version plus récente de MediaHub ne fait pas tomber le lot.
		{[]string{"bientôt"}, "declined"},
	}
	for _, c := range cases {
		if got := lotStatus(c.statuses); got != c.want {
			t.Errorf("lotStatus(%v) = %q, attendu %q", c.statuses, got, c.want)
		}
	}
}

func TestGroupLotsMakesOneLotPerShowAndAccount(t *testing.T) {
	waiting := &Waiting{Message: "Pas encore sorti"}
	rows := []Request{
		{ID: 42, MediaType: "tv", TMDBID: 1399, Title: "GoT", Seasons: []int{2}, Status: "approved", RequestedAt: "2026-10-29T10:00:00Z", UpdatedAt: "2026-10-29T10:00:00Z", Requester: "lea", Waiting: waiting},
		{ID: 41, MediaType: "tv", TMDBID: 1399, Title: "GoT", Seasons: []int{1}, Status: "available", RequestedAt: "2026-10-29T10:00:00Z", UpdatedAt: "2026-10-29T11:30:00Z", Requester: "lea"},
		{ID: 40, MediaType: "movie", TMDBID: 603, Title: "Matrix", Seasons: []int{}, Status: "declined", Note: strptr("Doublon"), Requester: "lea"},
		{ID: 39, MediaType: "tv", TMDBID: 1399, Title: "GoT", Seasons: []int{3}, Status: "pending", Requester: "hugo"},
	}
	lots := GroupLots(rows)
	if len(lots) != 3 {
		t.Fatalf("lots = %+v", lots)
	}
	got := lots[0]
	if got.Status != "partial" || len(got.RequestIDs) != 2 || got.Seasons[0] != 1 || got.Seasons[1] != 2 ||
		got.SeasonStatuses[0].Status != "available" || got.SeasonStatuses[1].Status != "approved" ||
		got.UpdatedAt != "2026-10-29T11:30:00Z" {
		t.Fatalf("lot de la série = %+v", got)
	}
	// Une saison est arrivée : la raison d'attente ne s'affiche plus sous « partiel ».
	if got.Waiting != nil {
		t.Fatalf("attente gardée sur un lot partiel : %+v", got.Waiting)
	}
	if lots[1].Status != "declined" || lots[1].Note == nil || *lots[1].Note != "Doublon" {
		t.Fatalf("refus = %+v", lots[1])
	}
	// La même série demandée par un autre compte reste un autre lot.
	if lots[2].Requester != "hugo" || lots[2].Seasons[0] != 3 {
		t.Fatalf("lot de hugo = %+v", lots[2])
	}
}

func TestFeedEntriesGroupTheSeasonsOfOneGesture(t *testing.T) {
	rows := []Request{
		{ID: 41, MediaType: "tv", TMDBID: 1399, Seasons: []int{1}, Requester: "lea"},
		{ID: 42, MediaType: "tv", TMDBID: 1399, Seasons: []int{2}, Requester: "lea"},
		{ID: 43, MediaType: "movie", TMDBID: 603, Seasons: []int{}, Requester: "admin"},
		{ID: 44, MediaType: "movie", TMDBID: 604, Seasons: []int{}, Requester: "hugo"},
	}
	entries := feedEntries(rows, "Admin")
	if len(entries) != 2 || entries[0].ID != 41 || len(entries[0].Seasons) != 2 || entries[1].ID != 44 {
		t.Fatalf("entrées = %+v", entries)
	}
}

func TestVerifyDeliveryChecksKeyThenSignature(t *testing.T) {
	body := []byte(`{"id":"x","event":"webhook.test"}`)
	signed := http.Header{}
	signed.Set("Authorization", "Bearer cle")
	signed.Set("X-MediaHub-Signature", "sha256="+hex.EncodeToString(Sign(body, "cle")))
	if err := VerifyDelivery(signed, body, "cle"); err != nil {
		t.Fatalf("livraison valide refusée : %v", err)
	}
	if err := VerifyDelivery(signed, body, ""); err != ErrBadKey {
		t.Fatalf("sans clé réglée : %v, attendu ErrBadKey", err)
	}
	if err := VerifyDelivery(signed, append(body, ' '), "cle"); err != ErrBadSignature {
		t.Fatalf("corps changé : %v, attendu ErrBadSignature", err)
	}
	signed.Set("X-MediaHub-Signature", "sha256=zz")
	if err := VerifyDelivery(signed, body, "cle"); err != ErrBadSignature {
		t.Fatalf("signature illisible : %v", err)
	}
}

func TestDialectIsRecognisedByTheV1PingAndRemembered(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   Dialect
	}{
		{"MediaHub", http.StatusOK, `{"status":"ok","service":"mediahub","apiVersion":1}`, DialectV1},
		{"MediaHub, mauvaise clé", http.StatusUnauthorized, `{"error":"Unauthorized"}`, DialectV1},
		{"OnyxHub", http.StatusNotFound, `not found`, DialectOnyxHub},
		{"en panne", http.StatusBadGateway, ``, DialectUnknown},
	}
	for _, c := range cases {
		Reset()
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			if r.URL.Path != V1Path+"/ping" {
				t.Errorf("%s : sonde sur %s", c.name, r.URL.Path)
			}
			w.WriteHeader(c.status)
			_, _ = w.Write([]byte(c.body))
		}))
		client := Client{BaseURL: server.URL, APIKey: "cle", HTTP: &http.Client{Timeout: time.Second}}
		if got := client.Dialect(context.Background()); got != c.want {
			t.Errorf("%s : dialecte %v, attendu %v", c.name, got, c.want)
		}
		client.Dialect(context.Background())
		if c.want != DialectUnknown && calls != 1 {
			t.Errorf("%s : %d sondes, le dialecte devait être retenu", c.name, calls)
		}
		server.Close()
	}
	Reset()
}
