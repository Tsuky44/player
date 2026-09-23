package middleware

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLimitBodies_StopsAnOversizedBody(t *testing.T) {
	var readErr error
	handler := LimitBodies(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.ReadAll(r.Body)
	}))

	body := strings.NewReader(strings.Repeat("x", maxRequestBody+1))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/auth/login", body))
	if readErr == nil {
		t.Fatal("a body past the limit must not be read to the end")
	}

	readErr = nil
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/auth/login", strings.NewReader(`{"username":"a"}`)))
	if readErr != nil {
		t.Fatalf("an ordinary body was refused: %v", readErr)
	}
}

func TestLimitBodies_LeavesInstallerUploadsToTheirRoute(t *testing.T) {
	var readErr error
	handler := LimitBodies(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.ReadAll(r.Body)
	}))
	body := strings.NewReader(strings.Repeat("x", maxRequestBody+1))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/downloads", body))
	if readErr != nil {
		t.Fatalf("an installer upload is bounded by its own route: %v", readErr)
	}
}
