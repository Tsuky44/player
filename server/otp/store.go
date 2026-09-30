package otp

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ErrAlreadyEnrolled : le compte a déjà un code configuré. Enable ne remplace
// jamais un secret en place, pour qu'une activation restée ouverte sur un
// second appareil n'invalide pas en silence l'application du premier.
var ErrAlreadyEnrolled = errors.New("otp: already enrolled")

// Account est l'état de la validation en deux étapes d'un compte, tel que la
// table users le garde (migration 15).
//
// Le secret TOTP est en clair : le serveur doit pouvoir recalculer le code, et
// aucune clé ne pourrait le chiffrer sans vivre à côté de la base. Une copie
// de player.db livre donc les secrets, mais pas les mots de passe (bcrypt) :
// le second facteur ne protège pas contre ce vol-là, il protège contre un mot
// de passe deviné ou réutilisé ailleurs. Voir ADR-0041.
type Account struct {
	Secret string
	// LastStep est la dernière période TOTP acceptée : un code ne sert qu'une fois.
	LastStep int64
	// recovery : les empreintes des codes de secours encore valables.
	recovery string
}

// Enrolled dit si le compte a configuré un code.
func (a Account) Enrolled() bool {
	return a.Secret != ""
}

// RecoveryCodesLeft est le nombre de codes de secours encore utilisables.
func (a Account) RecoveryCodesLeft() int {
	return len(decodeDigests(a.recovery))
}

// Load lit l'état d'un compte.
func Load(db *sql.DB, userID int) (Account, error) {
	var a Account
	err := db.QueryRow(
		`SELECT totp_secret, totp_last_step, totp_recovery FROM users WHERE id = ?`, userID,
	).Scan(&a.Secret, &a.LastStep, &a.recovery)
	if err != nil {
		return Account{}, fmt.Errorf("otp: load user %d: %w", userID, err)
	}
	return a, nil
}

// Enable enregistre secret pour le compte, dont le code de la période step
// vient d'être vérifié, et renvoie les codes de secours à montrer.
func Enable(db *sql.DB, userID int, secret string, step int64) ([]string, error) {
	codes, digests, err := NewRecoveryCodes()
	if err != nil {
		return nil, err
	}
	res, err := db.Exec(
		`UPDATE users SET totp_secret = ?, totp_last_step = ?, totp_recovery = ?
		 WHERE id = ? AND totp_secret = ''`,
		secret, step, encodeDigests(digests), userID,
	)
	if err != nil {
		return nil, fmt.Errorf("otp: enable for user %d: %w", userID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrAlreadyEnrolled
	}
	return codes, nil
}

// Disable efface le secret et les codes de secours du compte.
func Disable(db *sql.DB, userID int) error {
	if _, err := db.Exec(
		`UPDATE users SET totp_secret = '', totp_last_step = 0, totp_recovery = '' WHERE id = ?`, userID,
	); err != nil {
		return fmt.Errorf("otp: disable for user %d: %w", userID, err)
	}
	return nil
}

// RegenerateRecoveryCodes remplace tous les codes de secours du compte.
func RegenerateRecoveryCodes(db *sql.DB, userID int) ([]string, error) {
	codes, digests, err := NewRecoveryCodes()
	if err != nil {
		return nil, err
	}
	res, err := db.Exec(
		`UPDATE users SET totp_recovery = ? WHERE id = ? AND totp_secret <> ''`,
		encodeDigests(digests), userID,
	)
	if err != nil {
		return nil, fmt.Errorf("otp: regenerate recovery codes for user %d: %w", userID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, fmt.Errorf("otp: user %d has no code configured", userID)
	}
	return codes, nil
}

// Verdict est l'issue d'une vérification.
type Verdict int

const (
	// Rejected : ni un code valable, ni un code de secours restant.
	Rejected Verdict = iota
	// AcceptedCode : le code de l'application, consommé.
	AcceptedCode
	// AcceptedRecovery : un code de secours, rayé de la liste.
	AcceptedRecovery
)

// Verify vérifie ce que le compte a tapé et le consomme.
//
// La consommation est une écriture conditionnelle : deux requêtes simultanées
// qui présentent le même code ne passent pas toutes les deux, parce que la
// seconde ne trouve plus la ligne dans l'état qu'elle a lu.
func Verify(db *sql.DB, userID int, code string, now time.Time) (Verdict, error) {
	a, err := Load(db, userID)
	if err != nil {
		return Rejected, err
	}
	if !a.Enrolled() {
		return Rejected, nil
	}

	if step, ok := MatchTOTP(a.Secret, code, now, a.LastStep); ok {
		res, err := db.Exec(
			`UPDATE users SET totp_last_step = ? WHERE id = ? AND totp_last_step < ?`,
			step, userID, step,
		)
		if err != nil {
			return Rejected, fmt.Errorf("otp: consume code for user %d: %w", userID, err)
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return Rejected, nil
		}
		return AcceptedCode, nil
	}

	remaining, ok := consumeRecovery(a.recovery, code)
	if !ok {
		return Rejected, nil
	}
	res, err := db.Exec(
		`UPDATE users SET totp_recovery = ? WHERE id = ? AND totp_recovery = ?`,
		remaining, userID, a.recovery,
	)
	if err != nil {
		return Rejected, fmt.Errorf("otp: consume recovery code for user %d: %w", userID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return Rejected, nil
	}
	return AcceptedRecovery, nil
}
