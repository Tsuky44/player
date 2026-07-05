package streamcache

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const defaultTTL = 5 * time.Minute

// Entry holds cached file metadata for streaming.
type Entry struct {
	FilePath    string
	FileSize    int64
	ModTime     time.Time
	ContentType string
	MediaType   string
	CachedAt    time.Time
}

// Cache maps media_id to resolved file metadata for the /stream hot path.
type Cache struct {
	mu      sync.RWMutex
	entries map[int]*Entry
	ttl     time.Duration
}

var global = &Cache{
	entries: make(map[int]*Entry),
	ttl:     defaultTTL,
}

// Global returns the process-wide stream metadata cache.
func Global() *Cache {
	return global
}

// Get returns a cached entry when still valid.
func (c *Cache) Get(mediaID int) (*Entry, bool) {
	c.mu.RLock()
	entry, ok := c.entries[mediaID]
	c.mu.RUnlock()
	if !ok {
		return nil, false
	}
	if time.Since(entry.CachedAt) > c.ttl {
		return nil, false
	}
	return entry, true
}

// Put stores or refreshes an entry.
func (c *Cache) Put(mediaID int, entry *Entry) {
	entry.CachedAt = time.Now()
	c.mu.Lock()
	c.entries[mediaID] = entry
	c.mu.Unlock()
}

// Invalidate removes one media entry (e.g. file replaced).
func (c *Cache) Invalidate(mediaID int) {
	c.mu.Lock()
	delete(c.entries, mediaID)
	c.mu.Unlock()
}

// Clear drops every cached entry (after indexer scan).
func (c *Cache) Clear() {
	c.mu.Lock()
	c.entries = make(map[int]*Entry)
	c.mu.Unlock()
}

// ContentTypeForPath maps a file extension to a video MIME type.
func ContentTypeForPath(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mp4", ".m4v", ".mov":
		return "video/mp4"
	case ".mkv":
		return "video/x-matroska"
	case ".webm":
		return "video/webm"
	case ".avi":
		return "video/x-msvideo"
	case ".wmv":
		return "video/x-ms-wmv"
	case ".flv":
		return "video/x-flv"
	default:
		return "application/octet-stream"
	}
}

// StatFile reads file metadata from disk.
func StatFile(path string) (size int64, modTime time.Time, err error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, time.Time{}, err
	}
	return info.Size(), info.ModTime(), nil
}
