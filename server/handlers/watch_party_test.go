package handlers

import (
	"testing"
	"time"
)

func newTestWatchPartyStore() *watchPartyStore {
	return &watchPartyStore{parties: make(map[string]*watchParty)}
}

func TestWatchPartyPositionExtrapolatesWhilePlaying(t *testing.T) {
	store := newTestWatchPartyStore()
	start := time.Unix(1_000_000, 0)
	party, err := store.create(&watchPartyMember{ID: "a", UserID: 1}, 42, 100, true, start)
	if err != nil {
		t.Fatal(err)
	}
	if got := party.positionAt(start.Add(5 * time.Second)); got != 105 {
		t.Fatalf("playing position = %v, want 105", got)
	}

	// A pause without a position freezes the party where it has got to.
	paused := false
	if err := store.update(party.Code, 1, watchPartyUpdate{MemberID: "a", Action: "pause", Playing: &paused}, start.Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	if got := party.positionAt(start.Add(60 * time.Second)); got != 110 {
		t.Fatalf("paused position = %v, want 110", got)
	}
}

func TestWatchPartyMediaChangeRestartsAtZero(t *testing.T) {
	store := newTestWatchPartyStore()
	now := time.Unix(1_000_000, 0)
	party, _ := store.create(&watchPartyMember{ID: "a", UserID: 1}, 42, 1200, true, now)
	if err := store.update(party.Code, 1, watchPartyUpdate{MemberID: "a", Action: "media", MediaID: 43}, now); err != nil {
		t.Fatal(err)
	}
	if party.MediaID != 43 || party.Position != 0 {
		t.Fatalf("media change: media=%d position=%v", party.MediaID, party.Position)
	}
}

func TestWatchPartyRejectsAnotherAccountsMember(t *testing.T) {
	store := newTestWatchPartyStore()
	now := time.Unix(1_000_000, 0)
	party, _ := store.create(&watchPartyMember{ID: "a", UserID: 1}, 42, 0, false, now)
	playing := true
	err := store.update(party.Code, 2, watchPartyUpdate{MemberID: "a", Action: "play", Playing: &playing}, now)
	if err != errWatchPartyNotYours {
		t.Fatalf("err = %v, want errWatchPartyNotYours", err)
	}
}

func TestWatchPartyHostLeavingHandsOver(t *testing.T) {
	store := newTestWatchPartyStore()
	now := time.Unix(1_000_000, 0)
	party, _ := store.create(&watchPartyMember{ID: "a", UserID: 1}, 42, 0, false, now)
	if err := store.join(party.Code, &watchPartyMember{ID: "b", UserID: 2}, now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := store.join(party.Code, &watchPartyMember{ID: "c", UserID: 3}, now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := store.leave(party.Code, "a", 1); err != nil {
		t.Fatal(err)
	}
	if party.HostID != "b" {
		t.Fatalf("host = %q, want the oldest remaining member b", party.HostID)
	}
}

func TestWatchPartyWakesWaitersAndDisappearsWhenEmpty(t *testing.T) {
	store := newTestWatchPartyStore()
	now := time.Unix(1_000_000, 0)
	party, _ := store.create(&watchPartyMember{ID: "a", UserID: 1}, 42, 0, false, now)
	wait := party.changed
	if err := store.join(party.Code, &watchPartyMember{ID: "b", UserID: 2}, now); err != nil {
		t.Fatal(err)
	}
	select {
	case <-wait:
	default:
		t.Fatal("join did not wake the waiting poll")
	}

	// Member a keeps polling, b goes silent: only b is reaped.
	party.Members["a"].LastSeen = now.Add(40 * time.Second)
	store.reap(now.Add(watchPartyMemberStaleAfter + time.Second))
	if _, ok := party.Members["b"]; ok {
		t.Fatal("stale member b was not reaped")
	}
	if _, ok := store.parties[party.Code]; !ok {
		t.Fatal("party with a live member was removed")
	}

	store.reap(now.Add(10 * time.Minute))
	if _, ok := store.parties[party.Code]; ok {
		t.Fatal("empty party was not removed")
	}
}
