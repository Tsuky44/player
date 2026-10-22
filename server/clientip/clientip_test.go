package clientip

import (
	"net/http/httptest"
	"testing"
)

func TestClient(t *testing.T) {
	cases := []struct {
		name      string
		trust     string
		remote    string
		forwarded string
		realIP    string
		want      string
		viaProxy  bool
	}{
		{"client direct : l'en-tête qu'il écrit est ignoré", "", "203.0.113.7", "198.51.100.1", "", "203.0.113.7", false},
		{"derrière un proxy local : l'entrée qu'il a ajoutée", "", "127.0.0.1", "10.9.9.9, 198.51.100.1", "", "198.51.100.1", true},
		{"deux proxys de confiance : on remonte jusqu'au premier inconnu", "", "172.18.0.2", "198.51.100.1, 10.0.0.4", "", "198.51.100.1", true},
		{"client du réseau local derrière le proxy", "", "127.0.0.1", "192.168.1.20", "", "192.168.1.20", true},
		{"X-Real-IP quand il n'y a pas de X-Forwarded-For", "", "127.0.0.1", "", "198.51.100.9", "198.51.100.9", true},
		{"entrée illisible : rien à sa gauche n'est cru", "", "127.0.0.1", "198.51.100.1, n'importe-quoi", "", "127.0.0.1", false},
		{"none : même une adresse locale n'est pas un proxy", "none", "127.0.0.1", "198.51.100.1", "", "127.0.0.1", false},
		{"proxy nommé : seul lui est cru", "172.18.0.2", "172.18.0.3", "198.51.100.1", "", "172.18.0.3", false},
		{"proxy nommé, en CIDR", "172.18.0.0/16", "172.18.0.3", "198.51.100.1", "", "198.51.100.1", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/", nil)
			req.RemoteAddr = c.remote + ":4242"
			if c.forwarded != "" {
				req.Header.Set("X-Forwarded-For", c.forwarded)
			}
			if c.realIP != "" {
				req.Header.Set("X-Real-IP", c.realIP)
			}
			got, via := Parse(c.trust).Client(req)
			if got != c.want || via != c.viaProxy {
				t.Errorf("Client = (%q, %v), want (%q, %v)", got, via, c.want, c.viaProxy)
			}
		})
	}
}

func TestParseIgnoresUnreadableEntries(t *testing.T) {
	trust := Parse("pas-une-adresse, 10.0.0.1")
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "10.0.0.1:1"
	if !trust.TrustedRemote(req) {
		t.Fatal("the readable entry must still be trusted")
	}
	req.RemoteAddr = "10.0.0.2:1"
	if trust.TrustedRemote(req) {
		t.Fatal("an address that was not named must not be trusted")
	}
}
