package streaming

import (
	"testing"
	"time"

	"project-player/server/playbackauth"
)

// Une session préparée par le lecteur (standby=1) attend à côté de celle
// qu'il lit encore. Voir ADR-0056.

func newStandbyManager(t *testing.T) (*SessionManager, [32]byte) {
	t.Helper()
	saved := supersedeGrace
	supersedeGrace = 20 * time.Millisecond
	t.Cleanup(func() { supersedeGrace = saved })
	return &SessionManager{sessions: map[string]*TranscodeSession{}}, playbackauth.Digest("mine")
}

func waitGone(m *SessionManager, id string) bool {
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := m.GetSession(id); !ok {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return false
}

func TestStandby_ReplacesNothingUntilItsFirstSegmentIsServed(t *testing.T) {
	m, ticket := newStandbyManager(t)
	playing := &TranscodeSession{ID: "playing", TicketHash: ticket, TmpDir: t.TempDir()}
	prepared := &TranscodeSession{ID: "prepared", TicketHash: ticket, TmpDir: t.TempDir(), standby: true}
	m.CreateSession(playing)
	m.CreateSession(prepared)

	m.DropStandby(ticket, prepared.ID)
	time.Sleep(4 * supersedeGrace)
	if _, ok := m.GetSession("playing"); !ok {
		t.Fatal("la session lue doit survivre à une session seulement préparée")
	}

	m.Claim(prepared)
	if !waitGone(m, "playing") {
		t.Error("au premier segment servi, l'ancienne session est remplacée")
	}
	if _, ok := m.GetSession("prepared"); !ok {
		t.Error("la session que le lecteur vient de prendre doit rester")
	}

	// Les segments suivants ne remplacent plus rien.
	later := &TranscodeSession{ID: "later", TicketHash: ticket, TmpDir: t.TempDir(), standby: true}
	m.CreateSession(later)
	m.Claim(prepared)
	time.Sleep(4 * supersedeGrace)
	if _, ok := m.GetSession("later"); !ok {
		t.Error("une session déjà prise ne remplace pas la suivante en attente")
	}
}

func TestStandby_ANewOneDropsThePreviousOne(t *testing.T) {
	m, ticket := newStandbyManager(t)
	other := playbackauth.Digest("theirs")
	for id, s := range map[string]*TranscodeSession{
		"playing": {TicketHash: ticket},
		"first":   {TicketHash: ticket, standby: true},
		"second":  {TicketHash: ticket, standby: true},
		"theirs":  {TicketHash: other, standby: true},
	} {
		s.ID, s.TmpDir = id, t.TempDir()
		m.CreateSession(s)
	}

	m.DropStandby(ticket, "second")

	if _, ok := m.GetSession("first"); ok {
		t.Error("le lecteur n'en prépare qu'une : la précédente est détruite")
	}
	for _, id := range []string{"playing", "second", "theirs"} {
		if _, ok := m.GetSession(id); !ok {
			t.Errorf("la session %s ne doit pas être touchée", id)
		}
	}
}

func TestStandby_IsReapedWhenNobodyComesForIt(t *testing.T) {
	m, ticket := newStandbyManager(t)
	saved := standbyGrace
	standbyGrace = 10 * time.Millisecond
	t.Cleanup(func() { standbyGrace = saved })

	m.CreateSession(&TranscodeSession{ID: "playing", TicketHash: ticket, TmpDir: t.TempDir(), lastAccess: time.Now()})
	m.CreateSession(&TranscodeSession{ID: "prepared", TicketHash: ticket, TmpDir: t.TempDir(), standby: true, lastAccess: time.Now()})

	time.Sleep(3 * standbyGrace)
	m.reap()

	if _, ok := m.GetSession("prepared"); ok {
		t.Error("une attente que personne n'est venu chercher occupe un encodeur pour rien")
	}
	if _, ok := m.GetSession("playing"); !ok {
		t.Error("la session lue n'est pas concernée par le délai d'attente")
	}
}

func TestStandby_CountsAgainstTheCapForOtherTickets(t *testing.T) {
	m, ticket := newStandbyManager(t)
	m.CreateSession(&TranscodeSession{ID: "prepared", TicketHash: ticket, TmpDir: t.TempDir(), standby: true})

	if got := m.LiveCountExcept(playbackauth.Digest("theirs")); got != 1 {
		t.Errorf("une attente occupe un encodeur comme une autre : %d comptée(s)", got)
	}
	if got := m.LiveCountExcept(ticket); got != 0 {
		t.Errorf("elle ne compte pas contre son propre ticket : %d", got)
	}
}
