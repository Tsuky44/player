/// Longueur minimale d'un mot de passe choisi : création de compte, demande
/// d'accès, changement, réinitialisation. Le serveur applique la même
/// (`minPasswordLength`, handlers/auth.go) ; quatre caractères se devinaient
/// en quelques heures malgré les limites de débit.
///
/// La connexion n'y est pas soumise : un compte créé avec l'ancienne limite de
/// quatre caractères doit pouvoir continuer à se connecter.
const minNewPasswordLength = 8;
