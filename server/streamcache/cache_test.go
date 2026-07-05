package streamcache_test

import (
	"testing"
	"time"

	"project-player/server/streamcache"
)

func TestContentTypeForPath(t *testing.T) {
	tests := map[string]string{
		"/media/Films/foo.mkv":  "video/x-matroska",
		"/media/Films/foo.MP4":  "video/mp4",
		"/media/Films/foo.unknown": "application/octet-stream",
	}
	for path, want := range tests {
		if got := streamcache.ContentTypeForPath(path); got != want {
			t.Fatalf("ContentTypeForPath(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestCacheTTL(t *testing.T) {
	entry := &streamcache.Entry{
		FilePath:    "/tmp/test.mkv",
		FileSize:    100,
		ModTime:     time.Now(),
		ContentType: "video/x-matroska",
	}
	streamcache.Global().Put(42, entry)
	got, ok := streamcache.Global().Get(42)
	if !ok || got.FilePath != entry.FilePath {
		t.Fatalf("expected cache hit for media 42")
	}
	streamcache.Global().Invalidate(42)
	if _, ok := streamcache.Global().Get(42); ok {
		t.Fatalf("expected cache miss after invalidate")
	}
	streamcache.Global().Put(1, entry)
	streamcache.Global().Clear()
	if _, ok := streamcache.Global().Get(1); ok {
		t.Fatalf("expected cache miss after clear")
	}
}
