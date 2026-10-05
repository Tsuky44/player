package models

// Les valeurs de ShowSubtitleChoice.Mode. Vide veut dire « rien de choisi pour
// cette série » : le lecteur garde alors son comportement par défaut.
const (
	SubtitleModeOff = "off"
	SubtitleModeOn  = "on"
)

// ShowSubtitleChoice décrit le sous-titre choisi par ce qui ne bouge pas d'un
// épisode à l'autre — langue, forcé ou complet, texte ou image — plutôt que
// par sa clé seule, que le serveur attribue dans l'ordre de chaque fichier.
type ShowSubtitleChoice struct {
	Mode string `json:"mode"`
	// Langue de base (`fr`), vide quand la piste d'origine n'en portait pas.
	Lang string `json:"lang"`
	// Clé canonique dans l'épisode où le choix a été fait (`fr2`, `img3`) :
	// elle départage deux pistes de même langue et de même type.
	Key    string `json:"key"`
	Forced bool   `json:"forced"`
	Image  bool   `json:"image"`
}

// ShowTrackPreferences sont la langue audio et le sous-titre qu'un compte a
// choisis pour une série : ils valent pour tous ses épisodes et sur tous les
// appareils du compte (ADR-0044).
type ShowTrackPreferences struct {
	ShowID int `json:"show_id"`
	// Code ISO en minuscules, ou vide tant qu'aucune piste audio n'a été
	// choisie pour cette série.
	AudioLang string             `json:"audio_lang"`
	Subtitle  ShowSubtitleChoice `json:"subtitle"`
	// Vide tant que le compte n'a rien enregistré pour cette série.
	UpdatedAt string `json:"updated_at"`
}
