package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"project-player/server/config"
	"project-player/server/database"
	"project-player/server/models"
	"project-player/server/otp"

	"golang.org/x/crypto/bcrypt"
)

// setOTPPolicy règle la politique du serveur pour un test et la rend
// facultative ensuite : le cache de config survit d'un test à l'autre.
func setOTPPolicy(t *testing.T, policy otp.Policy) {
	t.Helper()
	raw := string(policy)
	if _, err := config.ApplyUpdate(config.UpdateRequest{OTPPolicy: &raw}); err != nil {
		t.Fatalf("set otp policy: %v", err)
	}
	t.Cleanup(func() {
		reset := string(otp.DefaultPolicy)
		config.ApplyUpdate(config.UpdateRequest{OTPPolicy: &reset}) //nolint:errcheck
	})
}

func createPasswordUser(t *testing.T, username string, perms models.Permissions) int {
	t.Helper()
	id := createTestUser(t, username, false, perms)
	hash, _ := bcrypt.GenerateFromPassword([]byte("secret"), bcrypt.MinCost)
	if _, err := database.DB.Exec(`UPDATE users SET password_hash = ? WHERE id = ?`, string(hash), id); err != nil {
		t.Fatalf("set password of %s: %v", username, err)
	}
	return id
}

func postLogin(username string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	Login(rec, httptest.NewRequest(http.MethodPost, "/api/auth/login",
		strings.NewReader(`{"username":"`+username+`","password":"secret"}`)), nil)
	return rec
}

func postLoginOTP(challenge, code string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	VerifyLoginOTP(rec, httptest.NewRequest(http.MethodPost, "/api/auth/otp/login",
		strings.NewReader(`{"challenge":"`+challenge+`","code":"`+code+`"}`)), nil)
	return rec
}

func decodeChallenge(t *testing.T, rec *httptest.ResponseRecorder) OTPChallenge {
	t.Helper()
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("login: status %d, want 401 with a challenge", rec.Code)
	}
	var resp OTPChallengeResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil || resp.OTP.Challenge == "" {
		t.Fatalf("login: no challenge in the answer (%v)", err)
	}
	return resp.OTP
}

func enrollForTest(t *testing.T, userID int) string {
	t.Helper()
	secret, err := otp.GenerateSecret()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := otp.Enable(database.DB, userID, secret, 0); err != nil {
		t.Fatalf("enable otp: %v", err)
	}
	return secret
}

func TestAnEnrolledAccountGetsNoSessionWithoutItsCode(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	secret := enrollForTest(t, id)

	challenge := decodeChallenge(t, postLogin("lea"))
	if challenge.Setup || challenge.Secret != "" {
		t.Fatal("an enrolled account must be asked for its code, not handed a new secret")
	}
	var sessions int
	database.DB.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&sessions)
	if sessions != 0 {
		t.Fatal("the password alone opened a session")
	}

	if rec := postLoginOTP(challenge.Challenge, "000000"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong code: status %d", rec.Code)
	}
	code, _ := otp.CodeAt(secret, time.Now())
	rec := postLoginOTP(challenge.Challenge, code)
	var resp LoginResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil || resp.Token == "" {
		t.Fatalf("right code: status %d, no token (%v)", rec.Code, err)
	}
	if !resp.User.OTPEnabled {
		t.Error("the profile must say the account has a code")
	}

	// L'étape est consommée : le même jeton ne rouvre pas une session.
	if rec := postLoginOTP(challenge.Challenge, code); rec.Code != http.StatusGone {
		t.Fatalf("reused challenge: status %d, want 410", rec.Code)
	}
}

func TestTheAdminsPolicyMakesAnAdministratorSetUpACodeToSignIn(t *testing.T) {
	setupAuthDB(t)
	setOTPPolicy(t, otp.Admins)
	createPasswordUser(t, "admin", models.Permissions{ManageUsers: true})
	createPasswordUser(t, "viewer", models.DefaultPermissions())

	if rec := postLogin("viewer"); rec.Code != http.StatusOK {
		t.Fatalf("a plain account must still sign in with its password, got %d", rec.Code)
	}

	challenge := decodeChallenge(t, postLogin("admin"))
	if !challenge.Setup || challenge.Secret == "" || !strings.HasPrefix(challenge.URI, "otpauth://totp/") {
		t.Fatalf("an administrator without a code must be handed one to set up: %+v", challenge)
	}
	code, _ := otp.CodeAt(challenge.Secret, time.Now())
	rec := postLoginOTP(challenge.Challenge, code)
	var resp LoginResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil || resp.Token == "" {
		t.Fatalf("setup code: status %d (%v)", rec.Code, err)
	}
	if len(resp.RecoveryCodes) != otp.RecoveryCodeCount {
		t.Fatalf("%d recovery codes handed out, want %d", len(resp.RecoveryCodes), otp.RecoveryCodeCount)
	}

	// La fois suivante, c'est le code qui est demandé, plus la configuration.
	if next := decodeChallenge(t, postLogin("admin")); next.Setup {
		t.Fatal("a configured account must not be asked to configure again")
	}
}

func TestTheDisabledPolicyLetsEveryoneInWithTheirPassword(t *testing.T) {
	setupAuthDB(t)
	setOTPPolicy(t, otp.Disabled)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	enrollForTest(t, id)

	if rec := postLogin("lea"); rec.Code != http.StatusOK {
		t.Fatalf("with the policy disabled, the password must suffice: %d", rec.Code)
	}
	rec := httptest.NewRecorder()
	StartOTPSetup(rec, httptest.NewRequest(http.MethodPost, "/api/auth/otp/setup", nil), nil, id)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("setting up a code while disabled: status %d, want 403", rec.Code)
	}
}

func TestARecoveryCodeOpensTheSessionOnce(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	secret, _ := otp.GenerateSecret()
	codes, err := otp.Enable(database.DB, id, secret, 0)
	if err != nil {
		t.Fatal(err)
	}

	first := decodeChallenge(t, postLogin("lea"))
	if rec := postLoginOTP(first.Challenge, codes[0]); rec.Code != http.StatusOK {
		t.Fatalf("recovery code: status %d", rec.Code)
	}
	second := decodeChallenge(t, postLogin("lea"))
	if rec := postLoginOTP(second.Challenge, codes[0]); rec.Code != http.StatusUnauthorized {
		t.Fatalf("reused recovery code: status %d, want 401", rec.Code)
	}
}

func TestEnablingFromTheSettingsNeedsAWorkingCode(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())

	rec := httptest.NewRecorder()
	StartOTPSetup(rec, httptest.NewRequest(http.MethodPost, "/api/auth/otp/setup", nil), nil, id)
	var setup OTPSetup
	if err := json.NewDecoder(rec.Body).Decode(&setup); err != nil || setup.Secret == "" {
		t.Fatalf("setup: status %d (%v)", rec.Code, err)
	}

	enable := func(code string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		EnableOTP(rec, httptest.NewRequest(http.MethodPost, "/api/auth/otp/enable",
			strings.NewReader(`{"code":"`+code+`"}`)), nil, id)
		return rec
	}
	if rec := enable("000000"); rec.Code != http.StatusBadRequest {
		t.Fatalf("wrong code: status %d, want 400 (a 401 would read as a lost session)", rec.Code)
	}
	if account, _ := otp.Load(database.DB, id); account.Enrolled() {
		t.Fatal("a wrong code must not enable anything")
	}
	code, _ := otp.CodeAt(setup.Secret, time.Now())
	if rec := enable(code); rec.Code != http.StatusOK {
		t.Fatalf("right code: status %d", rec.Code)
	}
	if account, _ := otp.Load(database.DB, id); !account.Enrolled() {
		t.Fatal("the code was accepted but nothing was enabled")
	}
}

func TestAnAccountCannotDropACodeThePolicyImposes(t *testing.T) {
	setupAuthDB(t)
	setOTPPolicy(t, otp.Everyone)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	enrollForTest(t, id)

	rec := httptest.NewRecorder()
	DisableOTP(rec, httptest.NewRequest(http.MethodPost, "/api/auth/otp/disable",
		strings.NewReader(`{"password":"secret"}`)), nil, id)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("disable under a mandatory policy: status %d, want 403", rec.Code)
	}
}

func TestOnlyTheOwnerResetsTheOwnersCode(t *testing.T) {
	setupAuthDB(t)
	owner := createTestUser(t, "owner", true, models.AllPermissions())
	admin := createTestUser(t, "admin", false, models.Permissions{ManageUsers: true})
	enrollForTest(t, owner)

	rec := httptest.NewRecorder()
	ResetUserOTP(rec, httptest.NewRequest(http.MethodDelete, "/api/users/1/otp", nil), idParams(owner), admin)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("admin resetting the owner: status %d, want 403", rec.Code)
	}
	if account, _ := otp.Load(database.DB, owner); !account.Enrolled() {
		t.Fatal("the owner's code was removed by an admin")
	}
}
