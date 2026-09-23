package middleware

import (
	"net/http"
	"strings"
)

// maxRequestBody borne le corps de toute requête qui ne dit pas le contraire.
//
// Une vingtaine de routes lisaient leur JSON sans aucune borne, dont
// l'inscription et la connexion, ouvertes à tous : un corps de plusieurs
// gigaoctets était lu jusqu'au bout avant d'être refusé. 8 Mio laissent large
// au plus gros document légitime — un lot de progression d'un serveur lié, 4 Mio
// — et les routes qui attendent moins gardent leur propre borne, plus serrée.
const maxRequestBody = 8 << 20

// LimitBodies applique maxRequestBody à chaque requête, sauf aux envois
// d'installateurs, qui font des centaines de mégaoctets et que leur route borne
// elle-même (maxUploadBytes).
func LimitBodies(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && !isInstallerUpload(r) {
			r.Body = http.MaxBytesReader(w, r.Body, maxRequestBody)
		}
		next.ServeHTTP(w, r)
	})
}

func isInstallerUpload(r *http.Request) bool {
	return r.Method == http.MethodPost && strings.TrimSuffix(r.URL.Path, "/") == "/api/downloads"
}
