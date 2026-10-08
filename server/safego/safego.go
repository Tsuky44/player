// Package safego lance les tâches de fond du serveur sans qu'une panique dans
// l'une d'elles n'arrête tout le processus.
//
// net/http rattrape déjà la panique d'un handler. Celle d'une goroutine lancée
// à côté — un scan, un enrichissement, le ménage des sessions — ne l'est par
// personne : le serveur s'arrêtait, et avec lui toutes les lectures en cours,
// pour une fiche mal formée dans une tâche que personne n'attendait.
package safego

import (
	"log"
	"runtime/debug"
	"time"
)

// restartDelay espace les relances d'une boucle qui panique à chaque tour.
var restartDelay = 5 * time.Second

// Recover se pose en `defer` au début d'une goroutine : une panique y est
// journalisée avec sa pile, et la goroutine se termine. Les `defer` posés
// après lui ont déjà tourné : un drapeau « en cours » est bien rendu.
func Recover(name string) {
	if r := recover(); r != nil {
		log.Printf("PANIC dans la tâche de fond %q: %v\n%s", name, r, debug.Stack())
	}
}

// Run exécute une tâche qui a une fin (un passage d'enrichissement, une
// extraction) sous la garde de Recover.
func Run(name string, task func()) {
	defer Recover(name)
	task()
}

// Forever exécute une boucle qui ne rend la main qu'à l'arrêt du serveur. Si
// elle panique, elle est relancée après une pause : le ménage des sessions ou
// la surveillance de la médiathèque ne s'éteignent pas pour de bon sur une
// erreur passagère. Une boucle qui rend la main d'elle-même n'est pas relancée.
func Forever(name string, loop func()) {
	for !completes(name, loop) {
		time.Sleep(restartDelay)
	}
}

func completes(name string, loop func()) (done bool) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC dans la boucle de fond %q, relancée dans %v: %v\n%s",
				name, restartDelay, r, debug.Stack())
		}
	}()
	loop()
	return true
}
