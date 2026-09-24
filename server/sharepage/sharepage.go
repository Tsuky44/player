// Package sharepage sert la page qu'ouvre un lien de partage public
// (ADR-0037) : https://serveur/share#code.
//
// Une page à part plutôt que l'app web Flutter : le visiteur n'a pas de compte,
// souvent un téléphone, et vient pour un seul média. Le bundle Flutter pèse
// plusieurs mégaoctets et son lecteur suppose un compte à chaque étape
// (pistes, progression, reprise) ; cette page tient en quelques kilo-octets et
// ne parle qu'aux routes /api/shared/* et au flux HLS protégé par ticket.
package sharepage

import (
	"embed"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"path"

	"github.com/julienschmidt/httprouter"
)

//go:embed assets
var assets embed.FS

// contentSecurityPolicy n'autorise que ce que la page utilise : ses propres
// fichiers, hls.js chez cdnjs (la même source que media_kit sur le web), les
// affiches TMDB, et les flux du serveur lui-même.
const contentSecurityPolicy = "default-src 'none'; " +
	"script-src 'self' https://cdnjs.cloudflare.com; " +
	"style-src 'self'; " +
	"img-src 'self' https: data:; " +
	"media-src 'self' blob:; " +
	"connect-src 'self'; " +
	"worker-src 'self' blob:; " +
	"base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

// Page sert la page elle-même (GET /share).
func Page(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
	serve(w, r, "index.html")
}

// Asset sert ses feuilles de style et son script (GET /share/assets/:file).
func Asset(w http.ResponseWriter, r *http.Request, ps httprouter.Params) {
	name := path.Base(ps.ByName("file"))
	if name == "index.html" {
		http.NotFound(w, r)
		return
	}
	serve(w, r, name)
}

func serve(w http.ResponseWriter, r *http.Request, name string) {
	body, err := fs.ReadFile(assets, "assets/"+name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	contentType := mime.TypeByExtension(path.Ext(name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", contentType)
	// Revalider plutôt que garder : une mise à jour du serveur doit changer la
	// page tout de suite, et elle est assez petite pour qu'on n'y perde rien.
	h.Set("Cache-Control", "no-cache")
	h.Set("Content-Security-Policy", contentSecurityPolicy)
	// Le code du lien est dans le fragment, que le navigateur n'envoie jamais ;
	// ces deux en-têtes gardent aussi la page hors des moteurs de recherche et
	// hors des en-têtes Referer des affiches chargées ailleurs.
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Robots-Tag", "noindex, nofollow")
	h.Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		return
	}
	if _, err := w.Write(body); err != nil {
		log.Printf("sharepage: write %s: %v", name, err)
	}
}
