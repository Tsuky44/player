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
}

// Register handles user registration (POST /api/auth/register)
func Register(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	w.Header().Set("Content-Type", "application/json")

	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error": "Invalid request body"}`, http.StatusBadRequest)
		return
	}

	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" || len(req.Password) < 4 {
		http.Error(w, `{"error": "Username must not be empty, and password must be at least 4 characters"}`, http.StatusBadRequest)
		return
	}

	// Check if user already exists
	var exists bool
	err := database.DB.QueryRow("SELECT EXISTS(SELECT 1 FROM users WHERE username = ?)", req.Username).Scan(&exists)
	if err != nil {
		log.Printf("Failed to check if user exists: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}
	if exists {
		http.Error(w, `{"error": "Username already taken"}`, http.StatusConflict)
		return
	}

	// Hash password
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("Failed to hash password: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	// Insert user
	res, err := database.DB.Exec("INSERT INTO users (username, password_hash) VALUES (?, ?)", req.Username, string(passwordHash))
	if err != nil {
		log.Printf("Failed to insert user: %v", err)
		http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		return
	}

	userID, _ := res.LastInsertId()

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
	var user models.User
	var passwordHash string
	err := database.DB.QueryRow("SELECT id, username, password_hash FROM users WHERE username = ?", req.Username).Scan(&user.ID, &user.Username, &passwordHash)
	if err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, `{"error": "Invalid username or password"}`, http.StatusUnauthorized)
		} else {
			log.Printf("Login database query error: %v", err)
			http.Error(w, `{"error": "Internal server error"}`, http.StatusInternalServerError)
		}
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

	var user models.User
	err := database.DB.QueryRow("SELECT id, username FROM users WHERE id = ?", userID).Scan(&user.ID, &user.Username)
	if err != nil {
		log.Printf("Me handler query error: %v", err)
		http.Error(w, `{"error": "User not found"}`, http.StatusNotFound)
		return
	}

	json.NewEncoder(w).Encode(user)
}
