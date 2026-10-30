package mediahub

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// v1Server rend un MediaHub v1 qui répond au ping, puis au suivi.
func v1Server(t *testing.T, progress func(w http.ResponseWriter, r *http.Request)) Client {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/ping"):
			_, _ = w.Write([]byte(`{"status":"ok","service":"mediahub","apiVersion":1}`))
		case strings.Contains(r.URL.Path, "/progress/"):
			progress(w, r)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return Client{BaseURL: server.URL, APIKey: "key", HTTP: server.Client()}
}

func TestProgressReadsDownloadAndImportFromMediaHub(t *testing.T) {
	client := v1Server(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("type"); got != "tv" {
			t.Errorf("type = %q, want tv", got)
		}
		_, _ = w.Write([]byte(`{"active":true,"downloading":true,
			"download":{"progress":42.5,"timeleft":"4m","speed":"3 MB/s","size":"1 GB","sizeLeft":"600 MB","releaseTitle":"Show.S01"},
			"imports":[{"releaseName":"Show.S01","progress":10,"files":10,"filesDone":1,"size":"1 GB","sizeDone":"100 MB","sizeLeft":"900 MB","current":null,"failed":false,"message":null}]}`))
	})

	got, err := client.Progress(context.Background(), Account{ID: 1, Username: "mathis"}, 1399, "tv")
	if err != nil {
		t.Fatalf("Progress: %v", err)
	}
	if got.Download == nil || got.Download.Progress != 42.5 || *got.Download.TimeLeft != "4m" {
		t.Fatalf("download = %+v", got.Download)
	}
	if len(got.Imports) != 1 || got.Imports[0].FilesDone != 1 {
		t.Fatalf("imports = %+v", got.Imports)
	}
}

func TestProgressMissingRouteIsUnsupportedNotAnError(t *testing.T) {
	client := v1Server(t, func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })

	_, err := client.Progress(context.Background(), Account{ID: 1, Username: "mathis"}, 1399, "movie")
	if err != ErrUnsupported {
		t.Fatalf("err = %v, want ErrUnsupported (un MediaHub plus ancien n'a pas la route)", err)
	}
}

func TestProgressWithNothingRunningHasEmptyImportsNotNull(t *testing.T) {
	client := v1Server(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"active":false,"downloading":false,"download":null,"imports":null}`))
	})

	got, err := client.Progress(context.Background(), Account{ID: 1, Username: "mathis"}, 1, "movie")
	if err != nil {
		t.Fatalf("Progress: %v", err)
	}
	if got.Active || got.Imports == nil {
		t.Fatalf("got = %+v", got)
	}
}
