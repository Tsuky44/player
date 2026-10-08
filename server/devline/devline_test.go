package devline

import (
	"net/http/httptest"
	"testing"
	"time"
)

func TestLineSpacesWritesAtItsRate(t *testing.T) {
	l := &line{enabled: true, bps: 8000} // 1000 octets par seconde
	now := time.Unix(0, 0)

	if wait := l.reserve(500, now); wait != 0 {
		t.Fatalf("le premier envoi part tout de suite, attendu %v", wait)
	}
	if wait := l.reserve(500, now); wait != 500*time.Millisecond {
		t.Fatalf("500 octets à 1000 o/s prennent 500 ms, attendu %v", wait)
	}
	// Deux réponses se partagent la même ligne : la suivante attend les deux.
	if wait := l.reserve(1, now); wait != time.Second {
		t.Fatalf("la ligne est commune, attendu %v", wait)
	}
}

func TestLineForgetsIdleTime(t *testing.T) {
	l := &line{enabled: true, bps: 8000}
	now := time.Unix(0, 0)
	l.reserve(1000, now)

	// Une ligne restée libre ne donne pas de crédit : pas de rafale après.
	later := now.Add(time.Minute)
	if wait := l.reserve(1000, later); wait != 0 {
		t.Fatalf("après un silence, l'envoi part tout de suite, attendu %v", wait)
	}
	if wait := l.reserve(1, later); wait != time.Second {
		t.Fatalf("le silence ne s'accumule pas en avance, attendu %v", wait)
	}
}

func TestUnlimitedLineNeverWaits(t *testing.T) {
	l := &line{enabled: true}
	if wait := l.reserve(1<<20, time.Unix(0, 0)); wait != 0 {
		t.Fatalf("0 kbit/s veut dire libre, attendu %v", wait)
	}
}

func TestWrapIsTransparentOutsideDevelopment(t *testing.T) {
	previous := shared
	defer func() { shared = previous }()

	shared = &line{}
	rec := httptest.NewRecorder()
	if Wrap(rec) != rec {
		t.Fatal("hors développement, la réponse n'est pas enveloppée")
	}

	shared = &line{enabled: true}
	w := Wrap(rec)
	if w == rec {
		t.Fatal("en développement, la réponse passe par la ligne")
	}
	if _, err := w.Write(make([]byte, 3*chunk+1)); err != nil {
		t.Fatal(err)
	}
	if rec.Body.Len() != 3*chunk+1 {
		t.Fatalf("tout doit arriver, reçu %d octets", rec.Body.Len())
	}
}
