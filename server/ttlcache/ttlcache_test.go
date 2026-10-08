package ttlcache

import (
	"strconv"
	"testing"
	"time"
)

// Le cache des fiches du catalogue grossissait sans fin : une entrée par
// identifiant TMDB ouvert, jamais rendue.
func TestCacheNeverHoldsMoreThanItsMax(t *testing.T) {
	c := New[int](time.Hour, 3)
	for i := 0; i < 50; i++ {
		c.Put(strconv.Itoa(i), i)
		if c.Len() > 3 {
			t.Fatalf("after %d puts the cache holds %d entries, max is 3", i+1, c.Len())
		}
	}
	if got, ok := c.Get("49"); !ok || got != 49 {
		t.Errorf("the newest entry must survive, got %d %v", got, ok)
	}
	if _, ok := c.Get("0"); ok {
		t.Errorf("the oldest entry should have been evicted")
	}
}

func TestExpiredEntriesAreNotServedAndGoFirst(t *testing.T) {
	c := New[string](30*time.Millisecond, 2)
	c.Put("old", "x")
	time.Sleep(60 * time.Millisecond)
	if _, ok := c.Get("old"); ok {
		t.Fatal("an expired entry was served")
	}

	c.Put("a", "1")
	time.Sleep(60 * time.Millisecond)
	c.Put("b", "2")
	c.Put("c", "3") // plein : « a », expirée, part avant « b »
	if _, ok := c.Get("b"); !ok {
		t.Errorf("a live entry was evicted while an expired one was there to go")
	}
	if _, ok := c.Get("c"); !ok {
		t.Errorf("the entry just put is missing")
	}
}

func TestReplacingAKeyEvictsNothing(t *testing.T) {
	c := New[int](time.Hour, 2)
	c.Put("a", 1)
	c.Put("b", 2)
	c.Put("a", 3)
	if got, _ := c.Get("a"); got != 3 {
		t.Errorf("a = %d, want 3", got)
	}
	if _, ok := c.Get("b"); !ok {
		t.Errorf("replacing a key evicted another one")
	}
}
