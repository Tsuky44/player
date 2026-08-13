package handlers

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
	"golang.org/x/crypto/bcrypt"
)

// AuthenticatedHandle is a custom handler signature that injects the authenticated userID
type AuthenticatedHandle func(w http.ResponseWriter, r *http.Request, ps httprouter.Params, userID int)

// GenerateRandomToken generates a cryptographically secure hex-encoded token
func GenerateRandomToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

// RequireAuth is a middleware wrapper that enforces authentication and injects userID
func RequireAuth(next AuthenticatedHandle) httprouter.Handle {
	return func(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, `{"error": "Authorization header required"}`, http.StatusUnauthorized)
			return
		}

		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
			http.Error(w, `{"error": "Authorization header must be Bearer <token>"}`, http.StatusUnauthorized)
			return
		}

		token := parts[1]
		var userID int

		// Verify token in database
		err := database.DB.QueryRow("SELECT user_id FROM sessions WHERE token = ?", token).Scan(&userID)
		if err != nil {
			if err == sql.ErrNoRows {
				http.Error(w, `{"error": "Invalid or expired session"}`, http.StatusUnauthorized)
			} else {
				log.Printf("Session query error: %v", err)
				http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
			}
			return
		}

		// Proceed to actual handler with userID
		next(w, r, ps, userID)
	}
}

// RegisterRequest represents the JSON payload for registration
type RegisterRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	// InviteToken is required unless the server has no account at all.
	InviteToken string `json:"invite_token"`
}

// AuthState is the public payload the login screen reads to decide whether to
// offer the sign-up form (GET /api/auth/state). It exposes a single boolean and
// nothing else.
type AuthState struct {
	SetupRequired bool `json:"setup_required"`
}

// GetAuthState reports whether the server is still pristine (no account yet).
func GetAuthState(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	empty, err := usersTableEmpty()
	if err != nil {
		log.Printf("GetAuthState error: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	json.NewEncoder(w).Encode(AuthState{SetupRequired: empty})
}

func usersTableEmpty() (bool, error) {
	var n int
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM users").Scan(&n); err != nil {
		return false, err
	}
	return n == 0, nil
}

// Register handles user registration (POST /api/auth/register).
//
// Self-service sign-up is closed: an account is born either as the very first
// one on a pristine server — which makes it the owner — or by redeeming a
// single-use invitation, which decides its permissions. The inviter never picks
// those permissions, so holding invite_users grants no path to escalation.
func Register(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" || len(req.Password) < 4 {
		writeJSONError(w, http.StatusBadRequest, "Username must not be empty, and password must be at least 4 characters")
		return
	}

	firstAccount, err := usersTableEmpty()
	if err != nil {
		log.Printf("Register: failed to count users: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// Resolve what this account will be allowed to do before touching the DB.
	permissions := models.DefaultPermissions()
	var invitation *Invitation
	switch {
	case firstAccount:
		// Bootstrap: nobody exists to invite anyone, so the first account takes
		// everything and becomes the owner.
		permissions = models.AllPermissions()
	case strings.TrimSpace(req.InviteToken) == "":
		writeJSONError(w, http.StatusForbidden, "Une invitation est requise pour créer un compte")
		return
	default:
		invitation, err = redeemableInvitation(strings.TrimSpace(req.InviteToken))
		if err != nil {
			log.Printf("Register: invitation lookup failed: %v", err)
			writeJSONError(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		if invitation == nil {
			writeJSONError(w, http.StatusForbidden, "Invitation invalide, expirée ou déjà utilisée")
			return
		}
		permissions = invitation.Grants
	}

	// Check if user already exists
	var exists bool
	err = database.DB.QueryRow("SELECT EXISTS(SELECT 1 FROM users WHERE username = ?)", req.Username).Scan(&exists)
	if err != nil {
		log.Printf("Failed to check if user exists: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if exists {
		writeJSONError(w, http.StatusConflict, "Username already taken")
		return
	}

	// Hash password
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("Failed to hash password: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	res, err := database.DB.Exec(
		`INSERT INTO users (
			username, password_hash, is_owner,
			perm_manage_settings, perm_manage_library, perm_manage_users,
			perm_delete_media, perm_invite_users, perm_request_media
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		req.Username, string(passwordHash), firstAccount,
		permissions.ManageSettings, permissions.ManageLibrary, permissions.ManageUsers,
		permissions.DeleteMedia, permissions.InviteUsers, permissions.RequestMedia,
	)
	if err != nil {
		log.Printf("Failed to insert user: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	userID, _ := res.LastInsertId()

	if invitation != nil {
		if err := markInvitationUsed(invitation.Token, int(userID)); err != nil {
			// The account exists and is usable; leaving the link consumable would
			// be worse than a stale row, so this is logged, not fatal.
			log.Printf("Failed to mark invitation %s used: %v", invitation.Token, err)
		}
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "success",
		"message": "User registered successfully",
		"user": map[string]interface{}{
			"id":       userID,
			"username": req.Username,
		},
	})
}

// LoginRequest represents the JSON payload for login
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// LoginResponse represents the response from a successful login
type LoginResponse struct {
	Token string      `json:"token"`
	User  models.User `json:"user"`
}

// Login handles user login (POST /api/auth/login)
func Login(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	// Find user
	var passwordHash string
	var userID int
	err := database.DB.QueryRow("SELECT id, password_hash FROM users WHERE username = ?", req.Username).Scan(&userID, &passwordHash)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Invalid username or password"}`, http.StatusUnauthorized)
		} else {
			log.Printf("Login database query error: %v", err)
			http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		}
		return
	}

	// Load the full profile so the client knows its permissions from the start.
	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("Login: failed to load user %d: %v", userID, err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	// Verify password
	if err := bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(req.Password)); err != nil {
		http.Error(w, `{"error": "Invalid username or password"}`, http.StatusUnauthorized)
		return
	}

	// Generate secure token
	token, err := GenerateRandomToken()
	if err != nil {
		log.Printf("Failed to generate token: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	// Store session in DB
	_, err = database.DB.Exec("INSERT INTO sessions (token, user_id) VALUES (?, ?)", token, user.ID)
	if err != nil {
		log.Printf("Failed to save session token: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	// Return token and user info
	json.NewEncoder(w).Encode(LoginResponse{
		Token: token,
		User:  user,
	})
}

// Logout handles user logout (POST /api/auth/logout)
func Logout(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, `{"error": "Authorization header required"}`, http.StatusUnauthorized)
		return
	}

	parts := strings.Split(authHeader, " ")
	if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
		http.Error(w, `{"error": "Invalid Authorization header"}`, http.StatusUnauthorized)
		return
	}

	token := parts[1]

	// Delete session from DB
	_, err := database.DB.Exec("DELETE FROM sessions WHERE token = ?", token)
	if err != nil {
		log.Printf("Logout database deletion error: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	w.Write([]byte(`{"status": "success", "message": "Logged out successfully"}`))
}

// Me returns the currently logged in user info (GET /api/auth/me)
func Me(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	user, err := LoadUser(userID)
	if err != nil {
		log.Printf("Me handler query error: %v", err)
		http.Error(w, `{"error": "User not found"}`, http.StatusNotFound)
		return
	}

	json.NewEncoder(w).Encode(user)
}

// ChangePasswordRequest is the body of POST /api/auth/password.
type ChangePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// ChangePassword lets any account rotate its own password. Without it, the
// password an admin typed at account creation would stay the user's forever.
func ChangePassword(w http.ResponseWriter, r *http.Request, _ httprouter.Params, userID int) {
	w.Header().Set("Content-Type", "application/json")

	var req ChangePasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if len(req.NewPassword) < 4 {
		writeJSONError(w, http.StatusBadRequest, "Le nouveau mot de passe doit faire au moins 4 caractères")
		return
	}

	var currentHash string
	if err := database.DB.QueryRow("SELECT password_hash FROM users WHERE id = ?", userID).Scan(&currentHash); err != nil {
		log.Printf("ChangePassword: failed to load user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(currentHash), []byte(req.CurrentPassword)); err != nil {
		writeJSONError(w, http.StatusUnauthorized, "Mot de passe actuel incorrect")
		return
	}

	if err := setUserPassword(userID, req.NewPassword); err != nil {
		log.Printf("ChangePassword: failed to update user %d: %v", userID, err)
		writeJSONError(w, http.StatusInternalServerError, "Internal server error")
		return
	}

	// Other devices keep their session: the user knows the old password here, so
	// this is a rotation, not a recovery. An admin reset is the one that kills
	// every session.
	w.Write([]byte(`{"status": "success"}`))
}

// setUserPassword hashes and stores a new password.
func setUserPassword(userID int, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	_, err = database.DB.Exec("UPDATE users SET password_hash = ? WHERE id = ?", string(hash), userID)
	return err
}
