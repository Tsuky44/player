package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/mediahub"
	"project-player/server/models"
)

// Se connecter à MediaHub avec son compte Onyx (ADR-0090). MediaHub lit les
// réponses de l'auth d'Onyx et rachète les codes d'« Ouvrir MediaHub » : ces
// formats, écrits par Onyx, sont épinglés sous contract/mediahub/onyx_*.json
// et se régénèrent avec ONYX_UPDATE_CONTRACT=1, comme TestAPIContract.

// Les valeurs tirées au hasard prennent une valeur fixe dans les fichiers.
const (
	pinnedToken     = "5f0c3a1e9b7d4c2a8e6f1b3d5a7c9e0f2b4d6a8c0e1f3a5b7d9c2e4f6a8b0c1d"
	pinnedChallenge = "c4e1a7b9d3f5a2c8e0b6d4f1a3c5e7b9"
)

// pinOnyxContract compare (ou écrit) contract/mediahub/<name> à la réponse
// d'Onyx, après avoir remplacé les valeurs aléatoires par leur valeur fixe.
func pinOnyxContract(t *testing.T, name string, body []byte, fix func(map[string]interface{})) {
	t.Helper()
	var value map[string]interface{}
	if err := json.Unmarshal(body, &value); err != nil {
		t.Fatalf("%s : réponse illisible : %v (%s)", name, err, body)
	}
	if fix != nil {
		fix(value)
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(mediaHubContractDir, name)
	if os.Getenv("ONYX_UPDATE_CONTRACT") != "" {
		if err := os.WriteFile(path, out.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s : %v — générer avec ONYX_UPDATE_CONTRACT=1", name, err)
	}
	if got := out.String(); got != strings.ReplaceAll(string(want), "\r\n", "\n") {
		t.Fatalf("Onyx ne répond plus contract/mediahub/%s : MediaHub lit ce format-là pour connecter un compte Onyx.\n"+
			"Si le changement est voulu, régénérer (ONYX_UPDATE_CONTRACT=1) et prévenir MediaHub.\nObtenu :\n%s", name, got)
	}
}

func issueSSO(t *testing.T, userID int) (*httptest.ResponseRecorder, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	IssueMediaHubSSO(rec, httptest.NewRequest(http.MethodPost, "/api/integrations/mediahub/sso", nil), nil, userID)
	if rec.Code != http.StatusOK {
		return rec, ""
	}
	var ticket mediahub.SSOTicket
	if err := json.Unmarshal(rec.Body.Bytes(), &ticket); err != nil {
		t.Fatalf("billet illisible : %v", err)
	}
	parsed, err := url.Parse(ticket.URL)
	if err != nil {
		t.Fatalf("adresse illisible : %q", ticket.URL)
	}
	return rec, parsed.Query().Get("code")
}

func redeemSSO(key, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/integrations/mediahub/sso/redeem", strings.NewReader(body))
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	RedeemMediaHubSSO(rec, req, nil)
	return rec
}

func TestOpenMediaHubHandsMediaHubTheAccountOnceThroughItsKey(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	server := v1StubAt(t)

	rec, code := issueSSO(t, id)
	if rec.Code != http.StatusOK || code == "" {
		t.Fatalf("émission : HTTP %d %s", rec.Code, rec.Body.String())
	}
	var ticket mediahub.SSOTicket
	_ = json.Unmarshal(rec.Body.Bytes(), &ticket)
	if !strings.HasPrefix(ticket.URL, server.URL+mediahub.SSOPath+"?code=") || ticket.ExpiresIn != 60 {
		t.Fatalf("billet = %+v", ticket)
	}

	body := `{"code":"` + code + `"}`
	if rec := redeemSSO("", body); rec.Code != http.StatusUnauthorized {
		t.Fatalf("rachat sans clé : HTTP %d, attendu 401", rec.Code)
	}
	if rec := redeemSSO("autre", body); rec.Code != http.StatusUnauthorized {
		t.Fatalf("rachat avec une autre clé : HTTP %d, attendu 401", rec.Code)
	}

	rec = redeemSSO("cle", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("rachat : HTTP %d %s", rec.Code, rec.Body.String())
	}
	var redeemed SSORedeemResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &redeemed); err != nil || redeemed.User.ID != id || redeemed.User.Username != "lea" {
		t.Fatalf("compte racheté = %+v (%v)", redeemed.User, err)
	}

	if rec := redeemSSO("cle", body); rec.Code != http.StatusGone {
		t.Fatalf("second rachat : HTTP %d, attendu 410", rec.Code)
	}
}

func TestOpenMediaHubNeedsAConfiguredMediaHub(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	t.Setenv("MEDIAHUB_URL", "")
	t.Setenv("MEDIAHUB_API_KEY", "")
	mediahub.Reset()
	if rec, _ := issueSSO(t, id); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("HTTP %d, attendu 503", rec.Code)
	}
}

func TestOpenMediaHubIsRefusedByOnyxHubWhichHasNoLandingRoute(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	hubStub(t, func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	if rec, _ := issueSSO(t, id); rec.Code != http.StatusNotImplemented {
		t.Fatalf("HTTP %d, attendu 501", rec.Code)
	}
}

func TestAnSSOCodeOfADeletedAccountIsGone(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	v1StubAt(t)
	_, code := issueSSO(t, id)
	if _, err := database.DB.Exec(`DELETE FROM users WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if rec := redeemSSO("cle", `{"code":"`+code+`"}`); rec.Code != http.StatusGone {
		t.Fatalf("HTTP %d, attendu 410", rec.Code)
	}
}

// Les réponses que MediaHub lit pour connecter un compte Onyx : le login, son
// étape OTP, /api/auth/me et le rachat d'un code. Le compte y est désigné par
// user.id, qui n'est jamais réutilisé (AUTOINCREMENT).
func TestMediaHubLoginContract(t *testing.T) {
	setupAuthDB(t)
	id := createPasswordUser(t, "lea", models.DefaultPermissions())
	v1StubAt(t)

	rec := postLogin("lea")
	if rec.Code != http.StatusOK {
		t.Fatalf("login : HTTP %d", rec.Code)
	}
	pinOnyxContract(t, "onyx_login.json", rec.Body.Bytes(), func(v map[string]interface{}) {
		v["token"] = pinnedToken
	})

	rec = httptest.NewRecorder()
	Me(rec, httptest.NewRequest(http.MethodGet, "/api/auth/me", nil), nil, id)
	pinOnyxContract(t, "onyx_me.json", rec.Body.Bytes(), nil)

	_, code := issueSSO(t, id)
	request := mediaHubContract(t, "onyx_sso_redeem_request.json")
	var shape mediahub.SSORedeemRequest
	if err := json.Unmarshal(request, &shape); err != nil || shape.Code == "" {
		t.Fatalf("onyx_sso_redeem_request.json ne se lit plus : %v", err)
	}
	rec = redeemSSO("cle", strings.Replace(string(request), shape.Code, code, 1))
	if rec.Code != http.StatusOK {
		t.Fatalf("rachat : HTTP %d %s", rec.Code, rec.Body.String())
	}
	pinOnyxContract(t, "onyx_sso_redeem.json", rec.Body.Bytes(), nil)

	enrollForTest(t, id)
	rec = postLogin("lea")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("login avec code attendu : HTTP %d", rec.Code)
	}
	pinOnyxContract(t, "onyx_login_otp.json", rec.Body.Bytes(), func(v map[string]interface{}) {
		v["otp"].(map[string]interface{})["challenge"] = pinnedChallenge
	})
}

// v1StubAt monte un faux MediaHub v1 qui ne sait que répondre au ping.
func v1StubAt(t *testing.T) *httptest.Server {
	t.Helper()
	return companionStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == mediahub.V1Path+"/ping" {
			_, _ = w.Write(mediaHubContract(t, "ping.json"))
			return
		}
		http.NotFound(w, r)
	})
}
