package otp

// Policy est ce que l'administrateur exige du serveur entier.
type Policy string

const (
	// Disabled coupe la validation en deux étapes partout : personne ne peut
	// l'activer, et la connexion ne demande aucun code, même à un compte qui
	// l'avait configurée. Les secrets restent en base : rallumer la politique
	// rend à chacun la protection qu'il s'était donnée.
	//
	// C'est aussi la porte de secours du propriétaire qui a perdu son téléphone
	// et ses codes de secours : la valeur se réécrit dans app_settings.
	Disabled Policy = "disabled"
	// Optional laisse chaque compte décider pour lui-même.
	Optional Policy = "optional"
	// Admins l'impose aux comptes qui administrent le serveur, facultative
	// pour les autres.
	Admins Policy = "admins"
	// Everyone l'impose à tous les comptes.
	Everyone Policy = "everyone"
)

// DefaultPolicy est la politique d'un serveur où personne n'a rien choisi :
// disponible, jamais imposée, pour qu'une mise à jour n'enferme personne dehors.
const DefaultPolicy = Optional

// ParsePolicy lit une politique écrite en base ou reçue d'un client.
func ParsePolicy(raw string) (Policy, bool) {
	switch p := Policy(raw); p {
	case Disabled, Optional, Admins, Everyone:
		return p, true
	}
	return "", false
}

// Available dit si un compte peut configurer un code et si la connexion en
// demande un.
func (p Policy) Available() bool {
	return p != Disabled
}

// RequiredFor dit si la politique impose le code à un compte. privileged :
// le compte administre le serveur (voir models.User.Administers).
func (p Policy) RequiredFor(privileged bool) bool {
	switch p {
	case Everyone:
		return true
	case Admins:
		return privileged
	}
	return false
}

// LoginStep est ce que la connexion doit encore demander, une fois le mot de
// passe vérifié.
type LoginStep int

const (
	// StepNone : le mot de passe suffit, la session s'ouvre.
	StepNone LoginStep = iota
	// StepCode : le compte a configuré un code, il faut le taper.
	StepCode
	// StepSetup : la politique impose un code que le compte n'a pas encore
	// configuré ; il le configure pendant la connexion, sans session ouverte
	// entre-temps.
	StepSetup
)

// NextLoginStep décide de la suite d'une connexion.
func (p Policy) NextLoginStep(enrolled, privileged bool) LoginStep {
	switch {
	case !p.Available():
		return StepNone
	case enrolled:
		return StepCode
	case p.RequiredFor(privileged):
		return StepSetup
	}
	return StepNone
}
