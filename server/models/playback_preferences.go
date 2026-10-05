package models

// PlaybackPreferences sont les réglages de lecture d'un compte, les mêmes sur
// tous ses appareils (ADR-0043). Ce qui dépend du matériel — décodeur,
// fréquence d'écran, téléchargements — reste sur l'appareil (ADR-0004).
type PlaybackPreferences struct {
	AutoSkipIntro bool `json:"auto_skip_intro"`
	// Code ISO 639-1 en minuscules, ou vide pour la piste par défaut du fichier.
	DefaultAudioLang string `json:"default_audio_lang"`
	// Vide tant que le compte n'a rien enregistré : le client y lit le droit
	// de déposer ses réglages locaux plutôt que de les perdre.
	UpdatedAt string `json:"updated_at"`
}
