package otp

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"fmt"
	"strings"
)

// RecoveryCodeCount est le nombre de codes de secours remis à l'activation.
const RecoveryCodeCount = 10

// recoveryEncoding : l'alphabet base32 de RFC 4648, écrit en minuscules. Il
// n'a ni 0, ni 1, ni 8, qu'on confondrait sur papier avec o, l ou b.
var recoveryEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// NewRecoveryCodes tire des codes de secours, à montrer une seule fois, et
// leurs empreintes, seules gardées en base.
//
// Dix caractères base32, soit 50 bits : les limites de débit de la connexion
// (ADR-0032) et le plafond d'essais par étape rendent ce nombre inatteignable
// à deviner.
func NewRecoveryCodes() (codes []string, digests []string, err error) {
	for i := 0; i < RecoveryCodeCount; i++ {
		raw := make([]byte, 7)
		if _, err := rand.Read(raw); err != nil {
			return nil, nil, fmt.Errorf("otp: generate recovery code: %w", err)
		}
		code := strings.ToLower(recoveryEncoding.EncodeToString(raw))[:10]
		codes = append(codes, code[:5]+"-"+code[5:])
		digests = append(digests, recoveryDigest(code))
	}
	return codes, digests, nil
}

// recoveryDigest est l'empreinte d'un code de secours, tirets et casse ignorés.
// SHA-256 sans sel suffit : le code porte 50 bits d'aléa, pas un mot choisi
// par un humain.
func recoveryDigest(code string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(normalizeCode(code))))
	return hex.EncodeToString(sum[:])
}

// encodeDigests et decodeDigests : la colonne totp_recovery garde les
// empreintes séparées par des virgules.
func encodeDigests(digests []string) string {
	return strings.Join(digests, ",")
}

func decodeDigests(raw string) []string {
	if raw == "" {
		return nil
	}
	return strings.Split(raw, ",")
}

// consumeRecovery retire code de la liste s'il y figure.
func consumeRecovery(stored, code string) (remaining string, ok bool) {
	want := recoveryDigest(code)
	digests := decodeDigests(stored)
	for i, d := range digests {
		if d == want {
			rest := append(append([]string{}, digests[:i]...), digests[i+1:]...)
			return encodeDigests(rest), true
		}
	}
	return stored, false
}
