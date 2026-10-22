// Package clientip dit qui envoie une requête quand un proxy inverse peut se
// trouver devant le serveur.
//
// X-Forwarded-For est écrit par chaque proxy traversé, mais aussi par le
// client lui-même : seule la partie ajoutée par des proxys de confiance est
// fiable. L'adresse retenue est donc la première, en partant de la droite, qui
// n'est pas un proxy de confiance.
//
// Par défaut, toute adresse de la machine ou du réseau local est un proxy de
// confiance : c'est ce qui fait marcher sans réglage un Caddy ou un Traefik
// dans le réseau Docker. Ce défaut a un prix : un client qui se connecte
// lui-même depuis une adresse privée (Docker Desktop, un VPN, la passerelle
// d'un NAT) choisit l'adresse qu'il déclare. TRUSTED_PROXIES le referme en
// nommant les proxys (« 172.18.0.2, 10.0.0.0/8 »), ou « none » sans proxy.
package clientip

import (
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
)

// Trust est l'ensemble des proxys dont X-Forwarded-For est cru.
type Trust struct {
	nets []*net.IPNet
	// local : le défaut, la machine et le réseau local.
	local bool
}

// Parse lit une valeur de TRUSTED_PROXIES. Une entrée illisible est ignorée
// et signalée, plutôt que d'empêcher le démarrage.
func Parse(raw string) Trust {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Trust{local: true}
	}
	if strings.EqualFold(raw, "none") {
		return Trust{}
	}
	var t Trust
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if !strings.Contains(entry, "/") {
			if ip := net.ParseIP(entry); ip != nil {
				bits := 128
				if ip.To4() != nil {
					bits = 32
				}
				entry += "/" + strconv.Itoa(bits)
			}
		}
		_, network, err := net.ParseCIDR(entry)
		if err != nil {
			log.Printf("TRUSTED_PROXIES: entrée ignorée %q: %v", entry, err)
			continue
		}
		t.nets = append(t.nets, network)
	}
	return t
}

// Trusts dit si ip est un proxy de confiance.
func (t Trust) Trusts(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if t.local && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
		return true
	}
	for _, network := range t.nets {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// Client rend l'adresse du client, et viaProxy quand elle vient d'un en-tête
// plutôt que de la connexion elle-même.
func (t Trust) Client(r *http.Request) (address string, viaProxy bool) {
	remote := Remote(r)
	if !t.Trusts(net.ParseIP(remote)) {
		return remote, false
	}
	forwarded := r.Header.Values("X-Forwarded-For")
	var hops []string
	for _, header := range forwarded {
		for _, hop := range strings.Split(header, ",") {
			if hop = strings.TrimSpace(hop); hop != "" {
				hops = append(hops, hop)
			}
		}
	}
	if len(hops) == 0 {
		if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(real) != nil {
			return real, true
		}
		return remote, false
	}
	address = remote
	for i := len(hops) - 1; i >= 0; i-- {
		ip := net.ParseIP(hops[i])
		if ip == nil {
			// Une entrée illisible : rien de plus à gauche n'est fiable.
			return address, viaProxy
		}
		address, viaProxy = hops[i], true
		if !t.Trusts(ip) {
			return address, true
		}
	}
	return address, viaProxy
}

// TrustedRemote dit si la connexion vient d'un proxy de confiance, dont les
// en-têtes X-Forwarded-* peuvent être crus.
func (t Trust) TrustedRemote(r *http.Request) bool {
	return t.Trusts(net.ParseIP(Remote(r)))
}

// Remote est l'adresse de la connexion, sans le port.
func Remote(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// Configured est la confiance lue dans TRUSTED_PROXIES au démarrage.
var Configured = Parse(os.Getenv("TRUSTED_PROXIES"))

// Client est Configured.Client.
func Client(r *http.Request) (string, bool) { return Configured.Client(r) }

// TrustedRemote est Configured.TrustedRemote.
func TrustedRemote(r *http.Request) bool { return Configured.TrustedRemote(r) }
