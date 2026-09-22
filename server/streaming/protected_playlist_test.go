package streaming

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"project-player/server/playbackauth"
	"strings"
	"testing"
)

func TestProtectEveryPlaylistResource(t *testing.T) {
	token := strings.Repeat("a", 43)
	input := "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"stream_1.m3u8\"\n#EXT-X-MAP:URI=\"init_0.mp4\"\n#EXTINF:2,\nstream_0_000.m4s\nstream_0.m3u8?existing=1\n"
	got, err := ProtectPlaylist(input, token)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(got, "ticket="+token) != 4 || !strings.Contains(got, "existing=1&ticket=") {
		t.Fatal("playlist contains unprotected resources")
	}
	for _, foreign := range []string{"https://example.test/x", "//example.test/x", "../secret", "%2e%2e/secret", "/absolute", "init.mp4#fragment"} {
		for _, input := range []string{"#EXTM3U\n" + foreign, "#EXTM3U\n#EXT-X-MAP:URI=\"" + foreign + "\""} {
			if _, err := ProtectPlaylist(input, token); err == nil {
				t.Fatalf("unsafe resource accepted: %s", foreign)
			}
		}
	}
}

func TestHLSTicketAndSessionIsolation(t *testing.T) {
	store := playbackauth.NewStore()
	token, _, _ := store.Issue(1, 42)
	other, _, _ := store.Issue(2, 42)
	wrongMedia, _, _ := store.Issue(1, 43)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "stream_0.m3u8"), []byte("#EXTM3U\n#EXT-X-MAP:URI=\"init_0.mp4\"\nstream_0_000.m4s\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "init_0.mp4"), []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	manager := &SessionManager{sessions: map[string]*TranscodeSession{"session": {
		ID: "session", MediaID: 42, TicketHash: playbackauth.Digest(token), TmpDir: dir,
		MasterPlaylist: "#EXTM3U\nstream_0.m3u8\n",
	}}}
	h := &Handler{manager: manager, tickets: store}
	for _, c := range []struct {
		path, token string
		status      int
	}{
		{"42/session/master.m3u8", "", 401},
		{"42/session/master.m3u8", wrongMedia, 401},
		{"42/session/master.m3u8", other, 404},
		{"43/session/master.m3u8", wrongMedia, 404},
		{"42/session/master.m3u8", token, 200},
		{"42/session/stream_0.m3u8", token, 200},
		{"42/session/init_0.mp4", token, 200},
	} {
		r := httptest.NewRequest("GET", "/api/v1/stream/"+c.path+"?ticket="+c.token, nil)
		w := httptest.NewRecorder()
		h.Dispatch(w, r, nil)
		if w.Code != c.status {
			t.Fatalf("%s returned %d, want %d", c.path, w.Code, c.status)
		}
		if c.status == 200 && strings.HasSuffix(c.path, ".m3u8") && !strings.Contains(w.Body.String(), "ticket="+token) {
			t.Fatal("playlist missing ticket")
		}
	}
	w := httptest.NewRecorder()
	h.Dispatch(w, httptest.NewRequest("DELETE", "/api/v1/stream/42/session?ticket="+other, nil), nil)
	if w.Code != 404 {
		t.Fatal("another ticket can destroy session")
	}
	store.Revoke(token, 1)
	w = httptest.NewRecorder()
	h.Dispatch(w, httptest.NewRequest("GET", "/api/v1/stream/42/session/init_0.mp4?ticket="+token, nil), nil)
	if w.Code != 401 || strings.Contains(w.Body.String(), "private") {
		t.Fatal("revoked ticket leaked media")
	}
}

func TestStartAtBeginningPinsTheMediaPlaylistStart(t *testing.T) {
	media := "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:4.0,\nstream_0_0.m4s\n"
	got := StartAtBeginning(media)
	if !strings.HasPrefix(got, "#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n#EXT-X-VERSION:7\n") {
		t.Fatalf("EXT-X-START must follow #EXTM3U, got:\n%s", got)
	}
	if StartAtBeginning(got) != got {
		t.Error("a playlist that already says where to start must be left alone")
	}

	master := "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nstream_0.m3u8\n"
	if StartAtBeginning(master) != master {
		t.Error("a master playlist must not carry EXT-X-START")
	}
}
