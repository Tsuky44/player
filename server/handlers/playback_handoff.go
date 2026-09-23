package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"sort"
	"time"

	"github.com/julienschmidt/httprouter"
)

// Reprise sur un autre appareil, à la YouTube.
//
// Le téléphone ouvre l'app pendant que le PC lit : l'accueil lui propose de
// reprendre là où en est le PC (GET /api/me/now-playing). Dès que le téléphone
// démarre ce titre (signal « start »), la lecture du PC est marquée comme
// passée au téléphone ; le PC l'apprend en interrogeant GET /api/playing/handoff,
// se met en pause et propose « Reprendre ici ». Reprendre sur le PC renvoie un
// « start », qui fait l'inverse.
//
// Seul un même titre (même média, ou même série) passe la main : deux
// personnes sur un compte partagé qui regardent des choses différentes ne se
// coupent pas l'une l'autre.

// handOffLocked marks the account's other plays of the same title as moved to
// the device behind key. t.mu must be held.
func (t *playbackTracker) handOffLocked(key [32]byte, entry *activePlayback) {
	entry.handedOffTo = ""
	for otherKey, other := range t.byKey {
		if otherKey == key || other.UserID != entry.UserID {
			continue
		}
		sameShow := entry.showID.Valid && other.showID.Valid && entry.showID.Int64 == other.showID.Int64
		if other.MediaID != entry.MediaID && !sameShow {
			continue
		}
		device := entry.DeviceName
		if device == "" {
			device = "un autre appareil"
		}
		other.handedOffTo = device
		other.handedOffBy = key
	}
}

// livePlayback copies entry with its position carried forward to now: the last
// heartbeat can be 15 s old, and resuming elsewhere must not replay them.
func livePlayback(entry *activePlayback, now time.Time) NowPlaying {
	item := entry.NowPlaying
	if !item.Paused {
		if gap := now.Sub(item.UpdatedAt); gap > 0 && gap <= playbackStaleAfter {
			item.Position += int(gap.Seconds())
		}
		if item.Duration > 0 && item.Position > item.Duration {
			item.Position = item.Duration
		}
	}
	item.UpdatedAt = item.UpdatedAt.UTC()
	return item
}

// PlaybackHandoff tells a player its play moved to another device.
type PlaybackHandoff struct {
	DeviceName string      `json:"device_name"`
	Playback   *NowPlaying `json:"playback,omitempty"`
}

func (t *playbackTracker) handoffFor(key [32]byte, userID int) *PlaybackHandoff {
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	entry := t.byKey[key]
	if entry == nil || entry.UserID != userID || entry.handedOffTo == "" {
		return nil
	}
	out := &PlaybackHandoff{DeviceName: entry.handedOffTo}
	if taker := t.byKey[entry.handedOffBy]; taker != nil && now.Sub(taker.UpdatedAt) <= playbackStaleAfter {
		item := livePlayback(taker, now)
		out.Playback = &item
	}
	return out
}

// othersFor lists the account's live plays on other devices, minus those that
// already handed their play over.
func (t *playbackTracker) othersFor(key [32]byte, userID int) []NowPlaying {
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	out := []NowPlaying{}
	for otherKey, entry := range t.byKey {
		if otherKey == key || entry.UserID != userID || entry.handedOffTo != "" {
			continue
		}
		if now.Sub(entry.UpdatedAt) > playbackStaleAfter {
			continue
		}
		item := livePlayback(entry, now)
		item.Address = ""
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out
}

// RemotePlayback is a play on another device, with what this account needs to
// open it here.
type RemotePlayback struct {
	NowPlaying
	Media any `json:"media,omitempty"`
}

// GetMyRemotePlaybacks lists what this account is playing on its other devices
// (GET /api/me/now-playing).
func GetMyRemotePlaybacks(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	plays := playbackActivity.othersFor(sessionKey(bearerToken(r)), userID)
	out := make([]RemotePlayback, 0, len(plays))
	for _, p := range plays {
		item := RemotePlayback{NowPlaying: p}
		if media, err := loadWatchPartyMedia(userID, p.MediaID); err == nil {
			item.Media = media
		} else {
			log.Printf("RemotePlayback: media %d: %v", p.MediaID, err)
			continue
		}
		out = append(out, item)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(out)
}

// GetPlaybackHandoff says whether this session's play moved to another device
// (GET /api/playing/handoff). 204 when it did not.
func GetPlaybackHandoff(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	handoff := playbackActivity.handoffFor(sessionKey(bearerToken(r)), userID)
	if handoff == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(handoff)
}
