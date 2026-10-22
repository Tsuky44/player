package handlers

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"project-player/server/models"

	"github.com/julienschmidt/httprouter"
)

func setAvatarForTest(t *testing.T, userID int, body string) (int, models.User) {
	t.Helper()
	rec := httptest.NewRecorder()
	SetMyAvatar(rec, httptest.NewRequest(http.MethodPut, "/api/me/avatar",
		strings.NewReader(body)), nil, userID)
	var user models.User
	if rec.Code == http.StatusOK {
		if err := json.NewDecoder(rec.Body).Decode(&user); err != nil {
			t.Fatalf("decode user: %v", err)
		}
	}
	return rec.Code, user
}

func uploadPhotoForTest(t *testing.T, userID int, data []byte) (int, models.User) {
	t.Helper()
	rec := httptest.NewRecorder()
	UploadMyAvatarPhoto(rec, httptest.NewRequest(http.MethodPost, "/api/me/avatar/photo",
		bytes.NewReader(data)), nil, userID)
	var user models.User
	if rec.Code == http.StatusOK {
		if err := json.NewDecoder(rec.Body).Decode(&user); err != nil {
			t.Fatalf("decode user: %v", err)
		}
	}
	return rec.Code, user
}

func readPhotoForTest(targetID, callerID int) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	GetUserAvatar(rec, httptest.NewRequest(http.MethodGet, "/api/users/x/avatar", nil),
		httprouter.Params{{Key: "id", Value: strconv.Itoa(targetID)}}, callerID)
	return rec
}

func pngForTest(t *testing.T, side int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, side, side))
	img.Set(0, 0, color.RGBA{R: 200, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

func TestANewAccountHasNoAvatar(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})

	user, err := LoadUser(lea)
	if err != nil {
		t.Fatalf("load user: %v", err)
	}
	if user.Avatar != "" {
		t.Errorf("avatar = %q, want empty (the initial)", user.Avatar)
	}
}

func TestChoosingAGalleryAvatarIsReturnedWithTheAccount(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})

	code, user := setAvatarForTest(t, lea, `{"preset":"cat"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if user.Avatar != "preset:cat" {
		t.Errorf("avatar = %q, want preset:cat", user.Avatar)
	}
	if again, _ := LoadUser(lea); again.Avatar != "preset:cat" {
		t.Errorf("stored avatar = %q", again.Avatar)
	}
}

func TestAGalleryKeyIsANameNotArbitraryText(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})

	for _, body := range []string{`{"preset":"../etc"}`, `{"preset":"Cat"}`, `{"preset":"` + strings.Repeat("a", 33) + `"}`} {
		if code, _ := setAvatarForTest(t, lea, body); code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", body, code)
		}
	}
}

func TestAnUploadedPhotoIsServedToOtherAccountsOfTheServer(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})
	mathis := createTestUser(t, "mathis", false, models.Permissions{})
	photo := pngForTest(t, 64)

	code, user := uploadPhotoForTest(t, lea, photo)
	if code != http.StatusOK {
		t.Fatalf("upload status = %d, want 200", code)
	}
	if !strings.HasPrefix(user.Avatar, "photo:") {
		t.Fatalf("avatar = %q, want photo:<version>", user.Avatar)
	}

	rec := readPhotoForTest(lea, mathis)
	if rec.Code != http.StatusOK {
		t.Fatalf("read status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "image/png" {
		t.Errorf("content type = %q, want image/png", got)
	}
	if !bytes.Equal(rec.Body.Bytes(), photo) {
		t.Error("the served photo differs from the uploaded one")
	}
}

func TestSomethingThatIsNotAnImageIsRefused(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})

	if code, _ := uploadPhotoForTest(t, lea, []byte("<html>not a photo</html>")); code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", code)
	}
	if code, _ := uploadPhotoForTest(t, lea, pngForTest(t, maxAvatarPhotoSide+1)); code != http.StatusBadRequest {
		t.Errorf("oversized photo: status = %d, want 400", code)
	}
}

func TestChoosingAGalleryAvatarDropsTheOldPhoto(t *testing.T) {
	setupAuthDB(t)
	lea := createTestUser(t, "lea", false, models.Permissions{})
	uploadPhotoForTest(t, lea, pngForTest(t, 32))

	setAvatarForTest(t, lea, `{"preset":"rocket"}`)

	if rec := readPhotoForTest(lea, lea); rec.Code != http.StatusNotFound {
		t.Errorf("read status = %d, want 404 once the photo is replaced", rec.Code)
	}
}
