package models

// PlaybackPreferences sont les réglages de lecture d'un compte, les mêmes sur
// tous ses appareils (ADR-0043). Ce qui dépend du matériel — décodeur,
// fréquence d'écran, téléchargements — reste sur l'appareil (ADR-0004).
type PlaybackPreferences struct {
	AutoSkipIntro bool `json:"auto_skip_intro"`
	// Code ISO 639-1 en minuscules, ou vide pour la piste par défaut du fichier.
	DefaultAudioLang string `json:"default_audio_lang"`

	// « Vous regardez encore ? » (ADR-0045) : après StillWatchingEpisodes
	// épisodes enchaînés sans que personne ne touche au lecteur, celui-ci
	// attend une réponse au lieu de lancer le suivant.
	StillWatchingEnabled  bool `json:"still_watching_enabled"`
	StillWatchingEpisodes int  `json:"still_watching_episodes"`
	// La plage où la question se pose, en minutes depuis minuit à l'heure de
	// l'appareil qui lit. Elle peut passer minuit (1320 → 360). Les deux à
	// StillWatchingAllDay : toute la journée.
	StillWatchingFrom  int `json:"still_watching_from"`
	StillWatchingUntil int `json:"still_watching_until"`

	// Vide tant que le compte n'a rien enregistré : le client y lit le droit
	// de déposer ses réglages locaux plutôt que de les perdre.
	UpdatedAt string `json:"updated_at"`
}

// StillWatchingAllDay est la valeur des deux bornes quand aucune plage horaire
// ne restreint la question.
const StillWatchingAllDay = -1

// DefaultPlaybackPreferences sont les réglages d'un compte qui n'a rien
// choisi. Les mêmes valeurs que les DEFAULT des colonnes.
func DefaultPlaybackPreferences() PlaybackPreferences {
	// La question est éteinte tant qu'on ne l'a pas demandée : le nombre
	// d'épisodes et la plage ne sont que ce qu'elle proposera une fois allumée.
	return PlaybackPreferences{
		StillWatchingEnabled:  false,
		StillWatchingEpisodes: 3,
		StillWatchingFrom:     StillWatchingAllDay,
		StillWatchingUntil:    StillWatchingAllDay,
	}
}
