package handlers

import (
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/julienschmidt/httprouter"
)

// Limites de débit des routes ouvertes sans compte.
//
// Rien ne bornait le rythme de ces routes. Un mot de passe se devinait donc à
// la vitesse du processeur (bcrypt seul freinait), et les routes qui créent une
// ligne en base — un appairage de téléviseur, une demande d'accès, que les
// administrateurs doivent ensuite traiter — se remplissaient à volonté.
//
// Un seau par adresse : chaque requête prend un jeton, et les jetons reviennent
// à un rythme fixe. La capacité laisse passer ce qu'un humain fait (quelques
// fautes de frappe, un téléviseur qui interroge toutes les deux secondes) et
// arrête ce qu'un script fait. Tout vit en mémoire : un redémarrage remet les
// compteurs à zéro, ce qui ne rend à un attaquant que quelques essais.

// rateLimiter est un ensemble de seaux à jetons, un par clé.
type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*tokenBucket
	// burst est la capacité d'un seau, every le temps qu'il faut pour y
	// rendre un jeton.
	burst float64
	every time.Duration
	now   func() time.Time
}

type tokenBucket struct {
	tokens float64
	last   time.Time
}

// maxRateLimitKeys borne la mémoire d'un limiteur face à des adresses qui
// changent à chaque requête. Au-delà, les seaux redevenus pleins sont oubliés
// — un seau plein ne retient plus rien.
const maxRateLimitKeys = 10_000

func newRateLimiter(burst int, every time.Duration) *rateLimiter {
	return &rateLimiter{
		buckets: make(map[string]*tokenBucket),
		burst:   float64(burst),
		every:   every,
		now:     time.Now,
	}
}

// allow prend un jeton pour key. Quand le seau est vide, il dit combien de
// temps attendre avant le prochain.
func (l *rateLimiter) allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) >= maxRateLimitKeys {
			l.forgetFullLocked(now)
		}
		b = &tokenBucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens = math.Min(l.burst, b.tokens+float64(now.Sub(b.last))/float64(l.every))
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) * float64(l.every))
	return false, wait
}

// exhausted dit si key n'a plus de jeton, sans en prendre.
func (l *rateLimiter) exhausted(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		return false
	}
	return b.tokens+float64(l.now().Sub(b.last))/float64(l.every) < 1
}

func (l *rateLimiter) forgetFullLocked(now time.Time) {
	for key, b := range l.buckets {
		if b.tokens+float64(now.Sub(b.last))/float64(l.every) >= l.burst {
			delete(l.buckets, key)
		}
	}
}

// Les limiteurs des routes publiques. Chacun est dimensionné sur l'usage
// légitime le plus soutenu de sa route.
var (
	// Dix essais d'affilée, puis un toutes les six secondes : de quoi se
	// tromper plusieurs fois, pas de quoi parcourir un dictionnaire.
	LoginLimiter = newRateLimiter(10, 6*time.Second)
	// Créer un compte, un appairage ou une demande d'accès est rare.
	SignupLimiter = newRateLimiter(5, 30*time.Second)
	// Un téléviseur interroge toutes les deux secondes (devicePairingPollInterval),
	// un demandeur toutes les cinq : une par seconde leur laisse de la marge.
	PollLimiter = newRateLimiter(30, time.Second)
	// Les échecs de connexion par compte, toutes adresses confondues : un
	// essai réparti sur mille adresses passe sous LoginLimiter, pas sous
	// celui-ci. Assez large pour qu'un inconnu ne puisse pas, en quelques
	// essais, fermer la porte au vrai titulaire du compte.
	accountLoginLimiter = newRateLimiter(20, 30*time.Second)
)

// RateLimited refuse la requête avec 429 quand l'adresse qui l'envoie a épuisé
// son seau.
func RateLimited(limiter *rateLimiter, next httprouter.Handle) httprouter.Handle {
	return func(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
		if ok, wait := limiter.allow(rateLimitKey(r)); !ok {
			seconds := int(math.Ceil(wait.Seconds()))
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			writeJSONError(w, http.StatusTooManyRequests, "Trop de tentatives, réessaie dans quelques secondes")
			return
		}
		next(w, r, ps)
	}
}

// rateLimitKey est l'adresse à qui imputer une requête.
//
// L'adresse de la connexion, sauf quand elle vient du réseau local ou de la
// machine elle-même : c'est alors, le plus souvent, le proxy inverse devant le
// serveur, et le client est la dernière adresse qu'il a ajoutée à
// X-Forwarded-For. Pas la première : celle-là, le client l'écrit lui-même et
// peut en changer à chaque requête. Un client connecté directement depuis le
// réseau local peut encore se forger une adresse ; il est déjà dans la maison.
func rateLimitKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if !isLocalAddress(host) {
		return host
	}
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
			return last
		}
	}
	if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
		return real
	}
	return host
}
