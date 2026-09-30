// Package otp porte la validation en deux étapes (ADR-0041) : les codes TOTP
// d'une application d'authentification, les codes de secours, la politique que
// l'administrateur choisit pour le serveur et les étapes de connexion en cours.
//
// Le package ne connaît pas HTTP : les handlers traduisent ses réponses en
// codes d'état.
package otp

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// Les paramètres de RFC 6238 que toutes les applications d'authentification
// comprennent sans qu'on les leur précise. SHA-256 ou huit chiffres seraient
// plus robustes sur le papier, mais Google Authenticator ignore encore une
// partie de ces options et afficherait des codes faux sans prévenir.
const (
	period = 30 * time.Second
	digits = 6
	// skew est le nombre de périodes acceptées de part et d'autre de l'heure
	// du serveur : un téléphone dont l'horloge dérive de trente secondes, ou un
	// code tapé juste avant qu'il change, passe encore.
	skew = 1
	// secretBytes : 160 bits, la taille recommandée par RFC 4226 pour HMAC-SHA1.
	secretBytes = 20
)

var secretEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// GenerateSecret tire un nouveau secret, encodé en base32 comme les
// applications l'attendent.
func GenerateSecret() (string, error) {
	raw := make([]byte, secretBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("otp: generate secret: %w", err)
	}
	return secretEncoding.EncodeToString(raw), nil
}

// ProvisioningURI est l'adresse otpauth:// que le QR code transporte.
func ProvisioningURI(issuer, account, secret string) string {
	label := url.PathEscape(issuer + ":" + account)
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", issuer)
	q.Set("algorithm", "SHA1")
	q.Set("digits", fmt.Sprint(digits))
	q.Set("period", fmt.Sprint(int(period.Seconds())))
	return "otpauth://totp/" + label + "?" + q.Encode()
}

// Step est le numéro de la période de 30 secondes qui contient t.
func Step(t time.Time) int64 {
	return t.Unix() / int64(period.Seconds())
}

// codeAt calcule le code d'une période (RFC 4226 §5.3).
func codeAt(key []byte, step int64) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step))
	mac := hmac.New(sha1.New, key)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%0*d", digits, value%1_000_000)
}

// CodeAt donne le code attendu à l'instant t. Sert aux tests, et à rien d'autre :
// le serveur ne fabrique jamais de code à envoyer.
func CodeAt(secret string, t time.Time) (string, error) {
	key, err := secretEncoding.DecodeString(strings.ToUpper(secret))
	if err != nil {
		return "", fmt.Errorf("otp: decode secret: %w", err)
	}
	return codeAt(key, Step(t)), nil
}

// normalizeCode retire les espaces et les tirets qu'on tape pour se relire.
func normalizeCode(code string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r == '-' {
			return -1
		}
		return r
	}, strings.TrimSpace(code))
}

// isTOTPShape dit si ce qui a été tapé ressemble à un code d'application
// plutôt qu'à un code de secours.
func isTOTPShape(code string) bool {
	if len(code) != digits {
		return false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// MatchTOTP cherche la période dont code est le code, autour de now, en
// ignorant celles qui ne sont pas strictement après lastStep : un code déjà
// accepté ne se rejoue pas, même pendant les trente secondes où il reste
// affiché. Renvoie la période trouvée, à retenir comme nouveau lastStep.
func MatchTOTP(secret, code string, now time.Time, lastStep int64) (int64, bool) {
	code = normalizeCode(code)
	if !isTOTPShape(code) {
		return 0, false
	}
	key, err := secretEncoding.DecodeString(strings.ToUpper(secret))
	if err != nil || len(key) == 0 {
		return 0, false
	}
	current := Step(now)
	for step := current - skew; step <= current+skew; step++ {
		if step <= lastStep {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(codeAt(key, step)), []byte(code)) == 1 {
			return step, true
		}
	}
	return 0, false
}
