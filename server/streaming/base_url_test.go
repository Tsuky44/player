package streaming

import (
	"net/http/httptest"
	"testing"
)

func TestBaseURLTrustsForwardedProtoOnlyFromAProxy(t *testing.T) {
	cases := []struct {
		remote, proto, want string
	}{
		{"127.0.0.1:1", "https", "https://onyx.example"},
		{"127.0.0.1:1", "javascript", "http://onyx.example"},
		{"203.0.113.7:1", "https", "http://onyx.example"},
	}
	for _, c := range cases {
		req := httptest.NewRequest("GET", "http://onyx.example/api/downloads", nil)
		req.RemoteAddr = c.remote
		req.Header.Set("X-Forwarded-Proto", c.proto)
		if got := BaseURL(req); got != c.want {
			t.Errorf("remote %s, proto %q: BaseURL = %q, want %q", c.remote, c.proto, got, c.want)
		}
	}
}
