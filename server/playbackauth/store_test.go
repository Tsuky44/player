package playbackauth

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestTicketLifecycleAndScope(t *testing.T) {
	s := NewStore()
	now := time.Date(2026, 9, 13, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	token, _, err := s.Issue(1, 42)
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "invalid", token + "extra"} {
		if _, ok := s.Validate(bad, 42); ok {
			t.Fatal("invalid token accepted")
		}
	}
	if _, ok := s.Validate(token, 43); ok {
		t.Fatal("ticket crossed media boundary")
	}
	if _, err := s.Renew(token, 2); err == nil {
		t.Fatal("another user renewed ticket")
	}
	s.Revoke(token, 2)
	if _, ok := s.Validate(token, 42); !ok {
		t.Fatal("another user revoked ticket")
	}
	now = now.Add(10 * time.Minute)
	if _, err := s.Renew(token, 1); err != nil {
		t.Fatal(err)
	}
	now = now.Add(10 * time.Minute)
	if _, ok := s.Validate(token, 42); !ok {
		t.Fatal("renewal did not extend deadline")
	}
	s.Revoke(token, 1)
	if _, ok := s.Validate(token, 42); ok {
		t.Fatal("revoked ticket accepted")
	}
	if _, err := s.Renew(token, 1); err == nil {
		t.Fatal("renewal resurrected revoked ticket")
	}
	token, ticket, _ := s.Issue(1, 42)
	now = ticket.ExpiresAt
	if _, ok := s.Validate(token, 42); ok {
		t.Fatal("ticket valid at expiry boundary")
	}
}

func TestTicketReadsDoNotExtendDeadlineAndStoreIsBounded(t *testing.T) {
	s := NewStore()
	now := time.Now()
	s.now = func() time.Time { return now }
	token, original, _ := s.Issue(1, 7)
	now = now.Add(time.Minute)
	ticket, ok := s.Validate(token, 7)
	if !ok || !ticket.LastActivity.Equal(now) || !ticket.ExpiresAt.Equal(original.ExpiresAt) {
		t.Fatal("invalid activity/deadline")
	}
	for i := 1; i < 32; i++ {
		if _, _, err := s.Issue(1, 7); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := s.Issue(1, 7); err == nil {
		t.Fatal("unbounded user tickets")
	}
	now = now.Add(TTL)
	if _, _, err := s.Issue(1, 7); err != nil {
		t.Fatal("expired entries still consume capacity")
	}
	if len(s.tickets) != 1 {
		t.Fatal("expired tickets not reaped")
	}
}

func TestRevocationStopsOpenResponse(t *testing.T) {
	s := NewStore()
	token, _, _ := s.Issue(1, 7)
	r := httptest.NewRequest("GET", "/stream?media_id=7&ticket="+token, nil)
	recorder := httptest.NewRecorder()
	w, ok := Protect(recorder, r, s, 7)
	if !ok {
		t.Fatal("valid ticket rejected")
	}
	if _, err := w.Write([]byte("first")); err != nil {
		t.Fatal(err)
	}
	s.Revoke(token, 1)
	if _, err := w.Write([]byte("secret")); err == nil {
		t.Fatal("write after revocation accepted")
	}
	if recorder.Body.String() != "first" {
		t.Fatal("bytes leaked after revocation")
	}
}

func TestOpenResponseFollowsExpiryAndRenewal(t *testing.T) {
	s := NewStore()
	now := time.Date(2026, 9, 13, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	token, _, _ := s.Issue(1, 7)
	r := httptest.NewRequest("GET", "/stream?media_id=7&ticket="+token, nil)
	w, _ := Protect(httptest.NewRecorder(), r, s, 7)

	now = now.Add(TTL - time.Minute)
	if _, err := s.Renew(token, 1); err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Minute) // past the first deadline, inside the renewed one
	if _, err := w.Write([]byte("a")); err != nil {
		t.Fatal("renewed ticket refused mid-stream")
	}
	now = now.Add(TTL)
	if _, err := w.Write([]byte("b")); err == nil {
		t.Fatal("expired ticket kept streaming")
	}
}

func TestRevocationStopsCopiedResponse(t *testing.T) {
	s := NewStore()
	token, _, _ := s.Issue(1, 7)
	r := httptest.NewRequest("GET", "/stream?media_id=7&ticket="+token, nil)
	recorder := httptest.NewRecorder()
	w, _ := Protect(recorder, r, s, 7)
	body := strings.Repeat("x", copyBufferSize+10)
	if _, err := io.CopyN(w, strings.NewReader(body), int64(len(body))); err != nil {
		t.Fatal(err)
	}
	if recorder.Body.Len() != len(body) {
		t.Fatalf("copied %d bytes, want %d", recorder.Body.Len(), len(body))
	}
	s.Revoke(token, 1)
	if _, err := io.Copy(w, strings.NewReader("secret")); err == nil {
		t.Fatal("copy after revocation accepted")
	}
}
