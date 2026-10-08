// Package medialang décide dans quelle langue une fiche est servie, et garde
// les titres et synopsis des langues que la table medias ne porte pas.
//
// medias n'a qu'une langue : celle des métadonnées du serveur (« langue de
// base »). L'app, elle, existe en plusieurs langues (ADR-0047) et annonce la
// sienne sur chaque requête. Quand les deux diffèrent, les textes viennent de
// media_translations. Voir ADR-0049.
package medialang

import (
	"net/http"
	"strconv"
	"strings"

	"project-player/server/config"
)

// interfaceLocales associe chaque langue de l'interface de l'app à la locale
// TMDB qui la sert. Ajouter une langue à l'app, c'est ajouter une ligne ici.
var interfaceLocales = []struct{ code, locale, season string }{
	{"fr", "fr-FR", "Saison"},
	{"en", "en-US", "Season"},
}

func primarySubtag(tag string) string {
	tag = strings.TrimSpace(tag)
	if i := strings.IndexAny(tag, "-_;"); i >= 0 {
		tag = tag[:i]
	}
	return strings.ToLower(strings.TrimSpace(tag))
}

func localeOf(code string) (string, bool) {
	for _, l := range interfaceLocales {
		if l.code == code {
			return l.locale, true
		}
	}
	return "", false
}

// Base est la langue des textes de la table medias.
func Base() string {
	return primarySubtag(config.TMDBLanguage())
}

// FromRequest lit la langue annoncée par l'app (Accept-Language). Une langue
// que l'interface n'a pas, ou pas d'en-tête du tout, donne la langue de base :
// une app d'avant ce réglage continue de recevoir ce qu'elle recevait.
func FromRequest(r *http.Request) string {
	return FromHeader(r.Header.Get("Accept-Language"))
}

// FromHeader est FromRequest sur la valeur brute de l'en-tête. La première
// langue que l'interface connaît l'emporte : un navigateur réglé sur
// « de-DE, en » lit l'anglais, pas la langue de base. Les poids `q` ne sont
// pas lus, l'ordre de l'en-tête les suit déjà.
func FromHeader(acceptLanguage string) string {
	for _, tag := range strings.Split(acceptLanguage, ",") {
		code := primarySubtag(tag)
		if _, ok := localeOf(code); ok {
			return code
		}
	}
	return Base()
}

// SeasonLabel nomme une saison qui n'a pas de nom propre (« Saison 2 »,
// « Season 2 »). Une langue hors de l'interface garde le français, celui des
// lignes que l'indexeur écrit.
func SeasonLabel(code string, number int) string {
	word := "Saison"
	for _, l := range interfaceLocales {
		if l.code == code {
			word = l.season
		}
	}
	return word + " " + strconv.Itoa(number)
}

// TMDBLocale est la valeur du paramètre `language` de TMDB pour une langue.
// La langue de base garde la locale réglée par l'administrateur (fr-CA reste
// fr-CA).
func TMDBLocale(code string) string {
	if code == Base() {
		return config.TMDBLanguage()
	}
	if locale, ok := localeOf(code); ok {
		return locale
	}
	return config.TMDBLanguage()
}

// Secondary liste les langues de l'interface que medias ne porte pas : celles
// dont il faut garder une traduction.
func Secondary() []string {
	base := Base()
	var out []string
	for _, l := range interfaceLocales {
		if l.code != base {
			out = append(out, l.code)
		}
	}
	return out
}
