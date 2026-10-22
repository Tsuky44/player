package handlers

import (
	"crypto/subtle"
	"log"
	"net/http"
	"sync"

	"project-player/server/clientip"
)

// Le code d'installation.
//
// Le premier compte créé devient propriétaire, et /api/auth/state dit à
// n'importe qui qu'un serveur n'en a pas encore : un serveur exposé à Internet
// avant que son propriétaire ne s'inscrive pouvait être pris par le premier
// venu. Quand cette inscription vient d'ailleurs que de la machine ou du
// réseau local, elle exige désormais un code que seul celui qui lit le
// journal du serveur connaît. Depuis la maison, rien ne change.
//
// Le code voyage dans le champ invite_token de /api/auth/register : l'app le
// demande dans le champ de l'invitation, qu'elle n'affichait pas pour le
// premier compte.

var setupCode struct {
	sync.Mutex
	code string
}

// AnnounceSetupCode écrit le code dans le journal quand le serveur n'a encore
// aucun compte. À appeler au démarrage, après InitDB.
func AnnounceSetupCode() {
	empty, err := usersTableEmpty()
	if err != nil || !empty {
		return
	}
	code, err := currentSetupCode()
	if err != nil {
		log.Printf("Setup: impossible de générer le code d'installation: %v", err)
		return
	}
	log.Printf("================================================================")
	log.Printf("Aucun compte sur ce serveur. Code d'installation : %s", code)
	log.Printf("Demandé pour créer le compte propriétaire hors du réseau local.")
	log.Printf("================================================================")
}

// currentSetupCode rend le code du processus, créé au premier appel.
func currentSetupCode() (string, error) {
	setupCode.Lock()
	defer setupCode.Unlock()
	if setupCode.code == "" {
		raw, err := generateUserCode()
		if err != nil {
			return "", err
		}
		setupCode.code = raw[:4] + "-" + raw[4:]
	}
	return setupCode.code, nil
}

// setupCodeRequired dit si l'inscription du propriétaire, envoyée par r, doit
// présenter le code : quand elle ne vient ni de la machine ni du réseau local.
func setupCodeRequired(r *http.Request) bool {
	address, _ := clientip.Client(r)
	return !isLocalAddress(address)
}

// setupCodeMatches compare ce que l'utilisateur a tapé au code, en ignorant
// la casse, le tiret et les espaces.
func setupCodeMatches(typed string) bool {
	code, err := currentSetupCode()
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(
		[]byte(normalizeUserCode(typed)), []byte(normalizeUserCode(code))) == 1
}
