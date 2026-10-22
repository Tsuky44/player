package handlers

import "project-player/server/models"

// Jusqu'où va un administrateur des comptes.
//
// manage_users suffisait à tout : s'accorder manage_settings, réinitialiser le
// mot de passe ou la validation en deux étapes d'un administrateur mieux doté,
// puis se connecter à sa place. Le droit de gérer les comptes devenait, en deux
// requêtes, tous les droits. Désormais un administrateur n'accorde ni ne
// retire que des droits qu'il a, et n'agit que sur un compte dont il tient
// lui-même chaque droit. Le propriétaire n'a pas de borne.

// mayManage dit si caller peut agir sur le compte target : ses droits, son mot
// de passe, son second facteur, ses appareils, son existence.
func mayManage(caller, target models.User) bool {
	if caller.IsOwner {
		return true
	}
	if target.IsOwner {
		return false
	}
	return caller.Permissions.Covers(target.Permissions)
}

// changesBeyond dit si passer de current à next touche un droit que caller
// n'a pas lui-même.
func changesBeyond(caller models.User, current, next models.Permissions) bool {
	if caller.IsOwner {
		return false
	}
	for _, perm := range models.PermissionList() {
		if !caller.Permissions.Has(perm) && current.Has(perm) != next.Has(perm) {
			return true
		}
	}
	return false
}

// errOutranked est le refus quand le compte visé a des droits que l'appelant
// n'a pas.
const errOutranked = "Ce compte a des droits que vous n’avez pas : seul le propriétaire peut le modifier"

// errBeyondOwnRights est le refus d'accorder ou de retirer un droit qu'on n'a
// pas.
const errBeyondOwnRights = "Vous ne pouvez accorder ou retirer que des droits que vous avez vous-même"
