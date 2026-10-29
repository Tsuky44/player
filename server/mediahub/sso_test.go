package mediahub

import (
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAnSSOCodeIsRedeemedOnceForItsAccount(t *testing.T) {
	codes := NewSSOCodes(time.Minute, 8)
	code, err := codes.Issue(3)
	if err != nil {
		t.Fatal(err)
	}
	if len(code) != 64 {
		t.Fatalf("code de %d caractères, attendu 64 hex", len(code))
	}
	if id, ok := codes.Redeem(code); !ok || id != 3 {
		t.Fatalf("premier rachat = %d, %v", id, ok)
	}
	if _, ok := codes.Redeem(code); ok {
		t.Fatal("un code racheté ne doit plus rien ouvrir")
	}
}

func TestAnExpiredSSOCodeOpensNothing(t *testing.T) {
	codes := NewSSOCodes(time.Minute, 8)
	now := time.Now()
	codes.now = func() time.Time { return now }
	code, _ := codes.Issue(3)
	now = now.Add(time.Minute)
	if _, ok := codes.Redeem(code); ok {
		t.Fatal("un code lu après son échéance (historique, capture) a ouvert une session")
	}
}

func TestTwoRedeemsRacingOnOneCodeLetOnlyOneThrough(t *testing.T) {
	codes := NewSSOCodes(time.Minute, 8)
	code, _ := codes.Issue(3)
	var wins atomic.Int32
	var wg sync.WaitGroup
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, ok := codes.Redeem(code); ok {
				wins.Add(1)
			}
		}()
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("%d rachats ont réussi, attendu 1", wins.Load())
	}
}

func TestPendingSSOCodesStayBounded(t *testing.T) {
	codes := NewSSOCodes(time.Minute, 2)
	first, _ := codes.Issue(1)
	codes.Issue(2) //nolint:errcheck
	last, _ := codes.Issue(3)
	if len(codes.pending) != 2 {
		t.Fatalf("%d codes gardés, attendu 2", len(codes.pending))
	}
	if _, ok := codes.Redeem(first); ok {
		t.Error("le plus ancien code devait céder sa place")
	}
	if id, ok := codes.Redeem(last); !ok || id != 3 {
		t.Error("le dernier code tiré doit rester rachetable")
	}
}

func TestSSOURLLandsOnMediaHubWithTheCodeOnly(t *testing.T) {
	got := SSOURL("https://hub.example/ ", "abc")
	parsed, err := url.Parse(got)
	if err != nil || !strings.HasPrefix(got, "https://hub.example"+SSOPath+"?") || parsed.Query().Get("code") != "abc" {
		t.Fatalf("SSOURL = %q", got)
	}
}

func TestOnlyTheIntegrationKeyPassesVerifyKey(t *testing.T) {
	header := http.Header{}
	if VerifyKey(header, "cle") == nil {
		t.Error("sans en-tête")
	}
	header.Set("Authorization", "Bearer autre")
	if VerifyKey(header, "cle") == nil {
		t.Error("mauvaise clé")
	}
	header.Set("Authorization", "Bearer ")
	if VerifyKey(header, "") == nil {
		t.Error("une clé vide côté Onyx ne doit rien laisser passer")
	}
	header.Set("Authorization", "Bearer cle")
	if err := VerifyKey(header, "cle"); err != nil {
		t.Errorf("bonne clé refusée : %v", err)
	}
}
