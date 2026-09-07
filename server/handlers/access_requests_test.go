package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"project-player/server/database"
	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

func requestAccess(t *testing.T, username, password string) *httptest.ResponseRecorder {
	t.Helper()
	body := `{"username":"` + username + `","password":"` + password +
		`","device_name":"iPhone de Mathis","message":"salut"}`
	rec := httptest.NewRecorder()
	RequestAccess(rec, httptest.NewRequest(http.MethodPost, "/api/auth/access/request",
		strings.NewReader(body)), nil)
	return rec
}

func openAccessRequest(t *testing.T, username string) AccessRequestTicket {
	t.Helper()
	rec := requestAccess(t, username, "secret")
	if rec.Code != http.StatusOK {
		t.Fatalf("RequestAccess: got %d: %s", rec.Code, rec.Body)
	}
	var ticket AccessRequestTicket
	if err := json.Unmarshal(rec.Body.Bytes(), &ticket); err != nil {
		t.Fatalf("decode ticket: %v", err)
	}
	return ticket
}

func pollAccess(t *testing.T, code string) AccessRequestVerdict {
	t.Helper()
	rec := httptest.NewRecorder()
	PollAccessRequest(rec, httptest.NewRequest(http.MethodPost, "/api/auth/access/poll",
		strings.NewReader(`{"request_code":"`+code+`"}`)), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("PollAccessRequest: got %d: %s", rec.Code, rec.Body)
	}
	var verdict AccessRequestVerdict
	if err := json.Unmarshal(rec.Body.Bytes(), &verdict); err != nil {
		t.Fatalf("decode verdict: %v", err)
	}
	return verdict
}

func pendingRequestID(t *testing.T, username string) int {
	t.Helper()
	var id int
	if err := database.DB.QueryRow(
		"SELECT id FROM access_requests WHERE username = ?", username).Scan(&id); err != nil {
		t.Fatalf("lookup request %s: %v", username, err)
	}
	return id
}

func approveAccess(t *testing.T, id, approverID int, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	ApproveAccessRequest(rec, httptest.NewRequest(http.MethodPost,
		"/api/access-requests/"+strconv.Itoa(id)+"/approve", strings.NewReader(body)),
		idParams(id), approverID)
	return rec
}

// Le trajet nominal : on sonne, un administrateur ouvre, et le demandeur relève
// une session déjà ouverte — sans jamais retaper son mot de passe.
func TestAccessRequest_ApprovalMintsAccountAndSession(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	ticket := openAccessRequest(t, "mathis")
	if verdict := pollAccess(t, ticket.RequestCode); verdict.Status != "pending" {
		t.Fatalf("avant décision: got %q, want pending", verdict.Status)
	}

	id := pendingRequestID(t, "mathis")
	if rec := approveAccess(t, id, ownerID, ""); rec.Code != http.StatusOK {
		t.Fatalf("ApproveAccessRequest: got %d: %s", rec.Code, rec.Body)
	}

	verdict := pollAccess(t, ticket.RequestCode)
	if verdict.Status != "approved" {
		t.Fatalf("après approbation: got %q, want approved", verdict.Status)
	}
	if verdict.Token == "" || verdict.User == nil {
		t.Fatalf("approbation sans session utilisable: %+v", verdict)
	}
	if verdict.User.Username != "mathis" {
		t.Fatalf("compte créé sous %q, want mathis", verdict.User.Username)
	}
	// Le compte par défaut n'est pas administrateur : il peut demander des
	// médias, rien de plus.
	if !verdict.User.Permissions.RequestMedia || verdict.User.Permissions.ManageUsers {
		t.Fatalf("droits par défaut inattendus: %+v", verdict.User.Permissions)
	}

	// Le jeton remis est une vraie session, utilisable immédiatement.
	userID, ok, err := lookupSession(verdict.Token)
	if err != nil || !ok {
		t.Fatalf("session non exploitable: ok=%v err=%v", ok, err)
	}
	if userID != verdict.User.ID {
		t.Fatalf("session ouverte sur %d, want %d", userID, verdict.User.ID)
	}

	// Usage unique : relever deux fois ne rend pas le jeton deux fois.
	if again := pollAccess(t, ticket.RequestCode); again.Status != "expired" {
		t.Fatalf("seconde relève: got %q, want expired", again.Status)
	}
}

// Le mot de passe proposé lors de la demande est celui du compte créé : sans
// cela, le demandeur serait accepté puis incapable de se reconnecter.
func TestAccessRequest_ProposedPasswordOpensTheAccount(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	openAccessRequest(t, "mathis")
	id := pendingRequestID(t, "mathis")
	if rec := approveAccess(t, id, ownerID, ""); rec.Code != http.StatusOK {
		t.Fatalf("ApproveAccessRequest: got %d: %s", rec.Code, rec.Body)
	}

	rec := httptest.NewRecorder()
	Login(rec, httptest.NewRequest(http.MethodPost, "/api/auth/login",
		strings.NewReader(`{"username":"mathis","password":"secret"}`)), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("Login après approbation: got %d: %s", rec.Code, rec.Body)
	}
}

// Un refus est dit au demandeur, une fois, et ne laisse aucun compte derrière.
func TestAccessRequest_DenialLeavesNothing(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	ticket := openAccessRequest(t, "inconnu")
	id := pendingRequestID(t, "inconnu")

	rec := httptest.NewRecorder()
	DenyAccessRequest(rec, httptest.NewRequest(http.MethodPost,
		"/api/access-requests/"+strconv.Itoa(id)+"/deny", nil), idParams(id), ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("DenyAccessRequest: got %d: %s", rec.Code, rec.Body)
	}

	if verdict := pollAccess(t, ticket.RequestCode); verdict.Status != "denied" {
		t.Fatalf("après refus: got %q, want denied", verdict.Status)
	}

	var exists bool
	if err := database.DB.QueryRow(
		"SELECT EXISTS(SELECT 1 FROM users WHERE username = 'inconnu')").Scan(&exists); err != nil {
		t.Fatalf("lookup user: %v", err)
	}
	if exists {
		t.Fatal("un refus a créé un compte")
	}

	// Le verdict n'est dû qu'une fois : la ligne disparaît en le rendant.
	if again := pollAccess(t, ticket.RequestCode); again.Status != "expired" {
		t.Fatalf("second poll après refus: got %q, want expired", again.Status)
	}
}

// La règle d'ADR-0001 tient ici aussi : un inviteur n'accorde que son gabarit,
// sinon « accepter une demande » serait le chemin par lequel il se fabrique un
// administrateur.
func TestApproveAccessRequest_InviterIsBoundByTemplate(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())
	inviterID := createTestUser(t, "frere", false,
		models.Permissions{InviteUsers: true, RequestMedia: true})
	setInviteGrants(t, inviterID, models.Permissions{RequestMedia: true})

	openAccessRequest(t, "ami")
	id := pendingRequestID(t, "ami")

	rec := approveAccess(t, id, inviterID,
		`{"permissions":{"manage_users":true,"manage_settings":true}}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("ApproveAccessRequest: got %d: %s", rec.Code, rec.Body)
	}

	var created models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode user: %v", err)
	}
	if created.Permissions.ManageUsers || created.Permissions.ManageSettings {
		t.Fatalf("l'inviteur a débordé son gabarit: %+v", created.Permissions)
	}
	if !created.Permissions.RequestMedia {
		t.Fatalf("gabarit non appliqué: %+v", created.Permissions)
	}
}

// Un administrateur, lui, choisit : il pourrait promouvoir après coup de toute
// façon.
func TestApproveAccessRequest_AdminChoosesPermissions(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	openAccessRequest(t, "colocataire")
	id := pendingRequestID(t, "colocataire")

	rec := approveAccess(t, id, ownerID,
		`{"permissions":{"manage_library":true,"request_media":true}}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("ApproveAccessRequest: got %d: %s", rec.Code, rec.Body)
	}

	var created models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode user: %v", err)
	}
	if !created.Permissions.ManageLibrary || created.Permissions.ManageUsers {
		t.Fatalf("droits choisis non appliqués: %+v", created.Permissions)
	}
	if created.IsOwner {
		t.Fatal("une demande approuvée a produit un propriétaire")
	}
}

// Une demande ne peut pas être traitée deux fois : la seconde approbation ne
// doit pas créer un second compte du même nom.
func TestApproveAccessRequest_IsSingleUse(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	openAccessRequest(t, "mathis")
	id := pendingRequestID(t, "mathis")

	if rec := approveAccess(t, id, ownerID, ""); rec.Code != http.StatusOK {
		t.Fatalf("première approbation: got %d: %s", rec.Code, rec.Body)
	}
	if rec := approveAccess(t, id, ownerID, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("seconde approbation: got %d, want 404: %s", rec.Code, rec.Body)
	}

	var count int
	if err := database.DB.QueryRow(
		"SELECT COUNT(*) FROM users WHERE username = 'mathis'").Scan(&count); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if count != 1 {
		t.Fatalf("comptes créés: %d, want 1", count)
	}
}

// Un identifiant déjà utilisé est refusé à la demande : mieux vaut le dire tout
// de suite que faire attendre une semaine pour un conflit connu d'avance.
func TestRequestAccess_RejectsTakenUsername(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "mathis", true, models.AllPermissions())

	if rec := requestAccess(t, "mathis", "secret"); rec.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", rec.Code, rec.Body)
	}
}

// Deux demandes de suite sous le même nom, c'est la même personne qui insiste.
func TestRequestAccess_CollapsesDuplicates(t *testing.T) {
	setupAuthDB(t)
	createTestUser(t, "owner", true, models.AllPermissions())

	openAccessRequest(t, "mathis")
	if rec := requestAccess(t, "mathis", "secret"); rec.Code != http.StatusConflict {
		t.Fatalf("doublon: got %d, want 409: %s", rec.Code, rec.Body)
	}
}

// Sur un serveur vierge, personne ne peut décider : la sonnette ne mène nulle
// part, et c'est l'inscription du propriétaire qu'il faut proposer.
func TestRequestAccess_RefusedOnPristineServer(t *testing.T) {
	setupAuthDB(t)

	if rec := requestAccess(t, "mathis", "secret"); rec.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403: %s", rec.Code, rec.Body)
	}
}

// La liste ne montre que ce qui attend une décision, et jamais le code privé du
// demandeur — le connaître permettrait de relever la session à sa place.
func TestListAccessRequests_ShowsPendingWithoutSecrets(t *testing.T) {
	setupAuthDB(t)
	ownerID := createTestUser(t, "owner", true, models.AllPermissions())

	ticket := openAccessRequest(t, "mathis")
	openAccessRequest(t, "refuse")
	denied := pendingRequestID(t, "refuse")
	rec := httptest.NewRecorder()
	DenyAccessRequest(rec, httptest.NewRequest(http.MethodPost, "/api/access-requests/x/deny", nil),
		idParams(denied), ownerID)

	rec = httptest.NewRecorder()
	ListAccessRequests(rec, httptest.NewRequest(http.MethodGet, "/api/access-requests", nil),
		httprouter.Params{}, ownerID)
	if rec.Code != http.StatusOK {
		t.Fatalf("ListAccessRequests: got %d: %s", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), ticket.RequestCode) {
		t.Fatal("la liste expose le code privé du demandeur")
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Fatal("la liste expose un champ mot de passe")
	}

	var requests []AccessRequest
	if err := json.Unmarshal(rec.Body.Bytes(), &requests); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(requests) != 1 || requests[0].Username != "mathis" {
		t.Fatalf("liste inattendue: %+v", requests)
	}
	if requests[0].DeviceName != "iPhone de Mathis" {
		t.Fatalf("device_name perdu: %+v", requests[0])
	}
}
