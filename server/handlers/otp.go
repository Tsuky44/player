package handlers

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/otp"

	"github.com/julienschmidt/httprouter"
	"golang.org/x/crypto/bcrypt"
)

// Validation en deux étapes (ADR-0041). Le package otp porte les codes, les
// codes de secours et la politique ; ce fichier les branche sur la connexion
// et sur les réglages du compte.

// otpIssuer est le nom sous lequel le compte apparaît dans l'application
// d'authentification.
const otpIssuer = "Onyx"

var (
	// loginChallenges : les connexions arrêtées entre le mot de passe et le
	// code. Cinq minutes suffisent pour ouvrir une application et recopier six
	// chiffres, ou pour scanner un QR code.
	loginChallenges = otp.NewChallenges(5 * time.Minute)
	// otpEnrollments : les activations lancées depuis les réglages du compte,
	// une par compte, rangées sous son identifiant.
	otpEnrollments = otp.NewChallenges(10 * time.Minute)
)

// errOTPGoneMessage : l'étape n'existe plus. L'app recommence alors la connexion au
// lieu de redemander un code qui ne pourra jamais passer.
const errOTPGoneMessage = "Étape de vérification expirée, reconnecte-toi"

// OTPChallenge est ce que la connexion renvoie quand le mot de passe ne suffit
// pas. Secret et URI ne sont remplis que pour une configuration imposée.
type OTPChallenge struct {
	Challenge string `json:"challenge"`
	Setup     bool   `json:"setup"`
	Secret    string `json:"secret,omitempty"`
	URI       string `json:"uri,omitempty"`
}

// OTPChallengeResponse est le corps du 401 d'une connexion qui attend un code.
// Le message est pour les versions de l'app qui ne connaissent pas encore
// l'étape : elles l'affichent tel quel.
type OTPChallengeResponse struct {
	Error string       `json:"error"`
	OTP   OTPChallenge `json:"otp"`
}

func otpAccountLabel(username string) string {
	if name := strings.TrimSpace(config.ServerName()); name != "" {
		return username + "@" + name
	}
	return username
}

// beginLoginOTP arrête la connexion avant la session quand la politique ou le
// compte l'exigent, et répond à la place de Login. false : rien à demander.
func beginLoginOTP(w http.ResponseWriter, user models.User) bool {
	step := config.OTPPolicy().NextLoginStep(user.OTPEnabled, user.Administers())
	if step == otp.StepNone {
		return false
	}

	c := otp.Challenge{UserID: user.ID, Username: user.Username, Setup: step == otp.StepSetup}
	message := "Code de vérification requis. Mets l'application à jour si elle ne te le demande pas."
	if c.Setup {
		secret, err := otp.GenerateSecret()
		if err != nil {
			log.Printf("Login: otp secret: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return true
		}
		c.Secret = secret
		message = "La validation en deux étapes est obligatoire sur ce serveur. Mets l'application à jour pour la configurer."
	}
	token, err := loginChallenges.Issue(c)
	if err != nil {
		log.Printf("Login: otp challenge: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return true
	}

	resp := OTPChallengeResponse{
		Error: message,
		OTP:   OTPChallenge{Challenge: token, Setup: c.Setup},
	}
	if c.Setup {
		resp.OTP.Secret = c.Secret
		resp.OTP.URI = otp.ProvisioningURI(otpIssuer, otpAccountLabel(user.Username), c.Secret)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	json.NewEncoder(w).Encode(resp)
	return true
}

// VerifyLoginOTPRequest est le corps de POST /api/auth/otp/login.
type VerifyLoginOTPRequest struct {
	Challenge string `json:"challenge"`
	Code      string `json:"code"`
}

// VerifyLoginOTP termine une connexion arrêtée par beginLoginOTP
// (POST /api/auth/otp/login).
//
// Publique comme /api/auth/login : on n'y arrive qu'avec le jeton d'étape
// qu'un mot de passe correct a obtenu. Chaque étape n'admet que
// otp.MaxAttempts essais, et les échecs comptent contre le compte comme ceux
// du mot de passe.
func VerifyLoginOTP(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req VerifyLoginOTPRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	c, ok := loginChallenges.Attempt(req.Challenge)
	if !ok {
		writeJSONError(w, http.StatusGone, errOTPGoneMessage)
		return
	}
	account := strings.ToLower(c.Username)
	if accountLoginLimiter.exhausted(account) {
		w.Header().Set("Retry-After", "30")
		writeJSONError(w, http.StatusTooManyRequests, "Trop de tentatives sur ce compte, réessaie dans un moment")
		return
	}

	var recoveryCodes []string
	if c.Setup {
		step, matched := otp.MatchTOTP(c.Secret, req.Code, time.Now(), 0)
		if !matched {
			accountLoginLimiter.allow(account)
			writeJSONError(w, http.StatusUnauthorized, "Code incorrect")
			return
		}
		codes, err := otp.Enable(database.DB, c.UserID, c.Secret, step)
		if errors.Is(err, otp.ErrAlreadyEnrolled) {
			// Un autre appareil a configuré un code entre-temps : celui-ci
			// n'est pas le bon secret, il faut recommencer.
			loginChallenges.Finish(req.Challenge)
			writeJSONError(w, http.StatusGone, errOTPGoneMessage)
			return
		}
		if err != nil {
			log.Printf("VerifyLoginOTP: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		recoveryCodes = codes
	} else {
		verdict, err := otp.Verify(database.DB, c.UserID, req.Code, time.Now())
		if errors.Is(err, sql.ErrNoRows) {
			loginChallenges.Finish(req.Challenge)
			writeJSONError(w, http.StatusGone, errOTPGoneMessage)
			return
		}
		if err != nil {
			log.Printf("VerifyLoginOTP: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		if verdict == otp.Rejected {
			accountLoginLimiter.allow(account)
			writeJSONError(w, http.StatusUnauthorized, "Code incorrect")
			return
		}
	}
	loginChallenges.Finish(req.Challenge)

	user, err := LoadUser(c.UserID)
	if err != nil {
		log.Printf("VerifyLoginOTP: failed to load user %d: %v", c.UserID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	openLoginSession(w, user, recoveryCodes)
}

// OTPStatus est l'état de la validation en deux étapes du compte appelant
// (GET /api/auth/otp).
type OTPStatus struct {
	Policy            string `json:"policy"`
	Enabled           bool   `json:"enabled"`
	Required          bool   `json:"required"`
	RecoveryCodesLeft int    `json:"recovery_codes_left"`
}

// GetOTPStatus décrit la validation en deux étapes du compte appelant.
func GetOTPStatus(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	user, account, ok := loadOTPAccount(w, userID)
	if !ok {
		return
	}
	policy := config.OTPPolicy()
	json.NewEncoder(w).Encode(OTPStatus{
		Policy:            string(policy),
		Enabled:           account.Enrolled(),
		Required:          policy.Available() && policy.RequiredFor(user.Administers()),
		RecoveryCodesLeft: account.RecoveryCodesLeft(),
	})
}

// OTPSetup est ce qu'il faut à une application d'authentification.
type OTPSetup struct {
	Secret string `json:"secret"`
	URI    string `json:"uri"`
}

// StartOTPSetup tire un secret pour le compte appelant
// (POST /api/auth/otp/setup). Rien n'est enregistré avant qu'un premier code
// prouve que l'application l'a bien reçu : un QR code mal scanné ne ferme pas
// la porte à son titulaire.
func StartOTPSetup(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	if !config.OTPPolicy().Available() {
		writeJSONError(w, http.StatusForbidden, "La validation en deux étapes est désactivée sur ce serveur")
		return
	}
	user, account, ok := loadOTPAccount(w, userID)
	if !ok {
		return
	}
	if account.Enrolled() {
		writeJSONError(w, http.StatusConflict, "La validation en deux étapes est déjà activée")
		return
	}

	secret, err := otp.GenerateSecret()
	if err != nil {
		log.Printf("StartOTPSetup: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	otpEnrollments.Put(strconv.Itoa(userID), otp.Challenge{
		UserID: userID, Username: user.Username, Setup: true, Secret: secret,
	})
	json.NewEncoder(w).Encode(OTPSetup{
		Secret: secret,
		URI:    otp.ProvisioningURI(otpIssuer, otpAccountLabel(user.Username), secret),
	})
}

// OTPCodeRequest porte un code tapé par l'utilisateur.
type OTPCodeRequest struct {
	Code string `json:"code"`
}

// OTPRecoveryCodes sont à montrer une fois, puis perdus pour le serveur.
type OTPRecoveryCodes struct {
	RecoveryCodes []string `json:"recovery_codes"`
}

// EnableOTP enregistre le secret de StartOTPSetup quand le premier code est
// juste (POST /api/auth/otp/enable).
//
// Un mauvais code répond 400 et pas 401 : sur une route authentifiée, un 401
// voudrait dire que la session est perdue.
func EnableOTP(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req OTPCodeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if !config.OTPPolicy().Available() {
		writeJSONError(w, http.StatusForbidden, "La validation en deux étapes est désactivée sur ce serveur")
		return
	}

	key := strconv.Itoa(userID)
	c, ok := otpEnrollments.Attempt(key)
	if !ok {
		writeJSONError(w, http.StatusGone, "Configuration expirée, recommence")
		return
	}
	step, matched := otp.MatchTOTP(c.Secret, req.Code, time.Now(), 0)
	if !matched {
		writeJSONError(w, http.StatusBadRequest, "Code incorrect")
		return
	}
	codes, err := otp.Enable(database.DB, userID, c.Secret, step)
	otpEnrollments.Finish(key)
	if errors.Is(err, otp.ErrAlreadyEnrolled) {
		writeJSONError(w, http.StatusConflict, "La validation en deux étapes est déjà activée")
		return
	}
	if err != nil {
		log.Printf("EnableOTP: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	json.NewEncoder(w).Encode(OTPRecoveryCodes{RecoveryCodes: codes})
}

// OTPPasswordRequest : désactiver le code ou en tirer de nouveaux de secours
// redemande le mot de passe. Une session laissée ouverte sur un appareil
// prêté ne doit pas suffire à retirer la protection du compte.
type OTPPasswordRequest struct {
	Password string `json:"password"`
}

// DisableOTP retire la validation en deux étapes du compte appelant
// (POST /api/auth/otp/disable), sauf si la politique la lui impose.
func DisableOTP(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req OTPPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	user, _, ok := loadOTPAccount(w, userID)
	if !ok {
		return
	}
	if policy := config.OTPPolicy(); policy.Available() && policy.RequiredFor(user.Administers()) {
		writeJSONError(w, http.StatusForbidden, "La validation en deux étapes est obligatoire pour ce compte")
		return
	}
	if !passwordMatches(w, userID, req.Password) {
		return
	}
	if err := otp.Disable(database.DB, userID); err != nil {
		log.Printf("DisableOTP: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status": "success"}`))
}

// RegenerateOTPRecoveryCodes remplace les codes de secours du compte appelant
// (POST /api/auth/otp/recovery-codes).
func RegenerateOTPRecoveryCodes(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req OTPPasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	_, account, ok := loadOTPAccount(w, userID)
	if !ok {
		return
	}
	if !account.Enrolled() {
		writeJSONError(w, http.StatusConflict, "La validation en deux étapes n'est pas activée")
		return
	}
	if !passwordMatches(w, userID, req.Password) {
		return
	}
	codes, err := otp.RegenerateRecoveryCodes(database.DB, userID)
	if err != nil {
		log.Printf("RegenerateOTPRecoveryCodes: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	json.NewEncoder(w).Encode(OTPRecoveryCodes{RecoveryCodes: codes})
}

// ResetUserOTP retire la validation en deux étapes d'un autre compte
// (DELETE /api/users/:id/otp) : c'est le recours de qui a perdu son téléphone
// et ses codes de secours. Si la politique l'impose, le compte la
// reconfigurera à sa prochaine connexion.
func ResetUserOTP(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	target, ok := loadTarget(w, ps)
	if !ok {
		return
	}
	caller, err := LoadUser(userID)
	if err != nil {
		log.Printf("ResetUserOTP: failed to load caller %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	// Même asymétrie que pour le mot de passe : retirer le second facteur du
	// propriétaire, c'est ouvrir la voie à qui aurait deviné son mot de passe.
	if target.IsOwner && !caller.IsOwner {
		writeJSONError(w, http.StatusForbidden, "La validation en deux étapes du propriétaire ne peut pas être réinitialisée")
		return
	}
	if err := otp.Disable(database.DB, target.ID); err != nil {
		log.Printf("ResetUserOTP: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	w.Write([]byte(`{"status": "success"}`))
}

// loadOTPAccount lit le compte et son état OTP, et répond lui-même en cas
// d'échec.
func loadOTPAccount(w http.ResponseWriter, userID int) (models.User, otp.Account, bool) {
	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("otp: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return models.User{}, otp.Account{}, false
	}
	account, err := otp.Load(database.DB, userID)
	if err != nil {
		log.Printf("otp: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return models.User{}, otp.Account{}, false
	}
	return user, account, true
}

// passwordMatches compare password au mot de passe du compte, et répond
// lui-même quand il ne correspond pas.
func passwordMatches(w http.ResponseWriter, userID int, password string) bool {
	var hash string
	if err := database.DB.QueryRow("SELECT password_hash FROM users WHERE id = ?", userID).Scan(&hash); err != nil {
		log.Printf("otp: failed to load password of user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return false
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		writeJSONError(w, http.StatusBadRequest, "Mot de passe incorrect")
		return false
	}
	return true
}
