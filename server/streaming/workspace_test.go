package streaming

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"project-player/server/playbackauth"
)

func TestResetWorkspace_RemovesOnlyOrphanSessions(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"hls-123", "hls-abc", "autre-chose"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "hls-fichier"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	resetWorkspace(root)

	// HLS_DIR peut désigner un dossier partagé : seuls les dossiers de
	// session sont à nous.
	for name, kept := range map[string]bool{"hls-123": false, "hls-abc": false, "autre-chose": true, "hls-fichier": true} {
		_, err := os.Stat(filepath.Join(root, name))
		if kept != (err == nil) {
			t.Errorf("%s: kept=%v, want %v", name, err == nil, kept)
		}
	}
}

func TestMaxTranscodes_ReadsTheEnvironment(t *testing.T) {
	t.Setenv("MAX_TRANSCODES", "3")
	if got := maxTranscodes(); got != 3 {
		t.Errorf("MAX_TRANSCODES=3 gives %d", got)
	}
	t.Setenv("MAX_TRANSCODES", "0")
	if got := maxTranscodes(); got != 0 {
		t.Errorf("MAX_TRANSCODES=0 must lift the limit, gives %d", got)
	}
	t.Setenv("MAX_TRANSCODES", "")
	if got := maxTranscodes(); got < 4 {
		t.Errorf("the default must allow at least 4 sessions, gives %d", got)
	}
}

func TestSupersede_ReplacesTheTicketsOldSessionsAfterAGrace(t *testing.T) {
	saved := supersedeGrace
	supersedeGrace = 20 * time.Millisecond
	t.Cleanup(func() { supersedeGrace = saved })

	m := &SessionManager{sessions: map[string]*TranscodeSession{}}
	mine, theirs := playbackauth.Digest("mine"), playbackauth.Digest("theirs")
	for id, ticket := range map[string][32]byte{"old": mine, "new": mine, "other": theirs} {
		m.CreateSession(&TranscodeSession{ID: id, TicketHash: ticket, TmpDir: t.TempDir()})
	}

	if got := m.LiveCountExcept(mine); got != 1 {
		t.Fatalf("a new session for a ticket must not count that ticket's own: %d", got)
	}

	m.Supersede(mine, "new")
	if got := m.LiveCountExcept(theirs); got != 1 {
		t.Errorf("the replaced session must stop counting against the cap: %d live", got)
	}
	if _, ok := m.GetSession("old"); !ok {
		t.Fatal("the replaced session must survive the grace period, the client is still showing it")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := m.GetSession("old"); !ok {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, ok := m.GetSession("old"); ok {
		t.Error("the replaced session was never destroyed")
	}
	for _, id := range []string{"new", "other"} {
		if _, ok := m.GetSession(id); !ok {
			t.Errorf("session %s must not be touched", id)
		}
	}
}

func TestPurgeBehind_KeepsTheRetainedWindowInEverySeries(t *testing.T) {
	dir := t.TempDir()
	touch := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 10; i++ {
		touch(segmentName(0, i))
		touch(segmentName(1, i))
	}
	touch("init_0.mp4")

	s := &TranscodeSession{ID: "s", TmpDir: dir, SegmentExt: ".m4s", Variants: 2, RetainSegments: 3}
	s.NoteSegment(8)
	s.purgeBehind()

	for i := 0; i < 10; i++ {
		for v := 0; v < 2; v++ {
			_, err := os.Stat(filepath.Join(dir, segmentName(v, i)))
			if want := i >= 5; want != (err == nil) {
				t.Errorf("stream_%d segment %d: present=%v, want %v", v, i, err == nil, want)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "init_0.mp4")); err != nil {
		t.Error("the initialisation segment must never be purged")
	}

	// Sans fenêtre déclarée, rien n'est effacé : un client plus ancien recule
	// dans la session sans savoir en rouvrir une.
	keep := &TranscodeSession{ID: "k", TmpDir: dir, SegmentExt: ".m4s", Variants: 2}
	keep.NoteSegment(9)
	keep.purgeBehind()
	if _, err := os.Stat(filepath.Join(dir, segmentName(0, 5))); err != nil {
		t.Error("a session without retain window purged a segment")
	}
}

func segmentName(variant, index int) string {
	return fmt.Sprintf("stream_%d_%03d.m4s", variant, index)
}
