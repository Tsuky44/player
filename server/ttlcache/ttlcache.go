// Package ttlcache est le petit cache en mémoire des réponses de TMDB et de
// MediaHub : une durée de vie, et un nombre d'entrées plafonné.
//
// Les caches qu'il remplace n'évinçaient rien. Celui des fiches du catalogue
// des demandes avait pour clé un identifiant TMDB quelconque : chaque fiche
// ouverte y restait jusqu'au redémarrage, quelques dizaines de kilo-octets à
// la fois, sur un serveur censé tenir en 20 Mo au repos.
package ttlcache

import (
	"sync"
	"time"
)

type entry[T any] struct {
	value    T
	storedAt time.Time
}

// Cache associe une clé à une valeur pendant ttl, pour au plus max entrées.
type Cache[T any] struct {
	mu      sync.Mutex
	ttl     time.Duration
	max     int
	entries map[string]entry[T]
}

// New crée un cache. max borne le nombre d'entrées gardées en mémoire.
func New[T any](ttl time.Duration, max int) *Cache[T] {
	return &Cache[T]{ttl: ttl, max: max, entries: map[string]entry[T]{}}
}

// Get rend la valeur gardée sous key, si elle n'a pas expiré.
func (c *Cache[T]) Get(key string) (T, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok || time.Since(e.storedAt) > c.ttl {
		if ok {
			delete(c.entries, key)
		}
		var zero T
		return zero, false
	}
	return e.value, true
}

// Put garde value sous key. Un cache plein rend d'abord ses entrées expirées,
// puis la plus ancienne.
func (c *Cache[T]) Put(key string, value T) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, replacing := c.entries[key]; !replacing && len(c.entries) >= c.max {
		c.evict()
	}
	c.entries[key] = entry[T]{value: value, storedAt: time.Now()}
}

// Delete oublie key : la prochaine lecture retourne à la source.
func (c *Cache[T]) Delete(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.entries, key)
}

// Len est le nombre d'entrées en mémoire, expirées comprises.
func (c *Cache[T]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.entries)
}

func (c *Cache[T]) evict() {
	var oldestKey string
	var oldest time.Time
	for key, e := range c.entries {
		if time.Since(e.storedAt) > c.ttl {
			delete(c.entries, key)
			continue
		}
		if oldestKey == "" || e.storedAt.Before(oldest) {
			oldestKey, oldest = key, e.storedAt
		}
	}
	if len(c.entries) >= c.max && oldestKey != "" {
		delete(c.entries, oldestKey)
	}
}
