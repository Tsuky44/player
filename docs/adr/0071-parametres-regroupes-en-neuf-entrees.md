# ADR-0071 — Les paramètres regroupés en neuf entrées

- **Statut :** accepté
- **Date :** 2026-10-19
- **Portée :** l'app (`app/lib/screens/settings/settings_categories.dart`,
  `app/lib/screens/settings/settings_sections.dart`, `app/lib/screens/settings/settings_screen.dart`,
  `app/lib/screens/settings/widgets/settings_category_body.dart`,
  `app/lib/screens/settings/widgets/settings_page.dart`, `app/lib/screens/settings/pages/device_page.dart`).

## Contexte

La navigation des paramètres avait grandi d'une entrée par page : dix-huit pour un administrateur
(neuf dans « Mon espace », neuf dans « Administration »). Quelqu'un qui ouvre les paramètres deux
fois par an ne savait plus où chercher : « Serveurs », « Synchro Emby » et « Serveurs liés » se
ressemblaient, « Tableau de bord », « Historique » et « Statistiques » montraient la même activité
par trois portes, et « Cet appareil » répétait la place des téléchargements que la page
« Téléchargements » affichait déjà.

## Décision

1. **Une entrée réunit les pages qu'on cherche au même endroit.** « Mon espace » : Mon compte,
   Général, Lecture, Téléchargements, Serveurs et partage. « Administration » : Activité,
   Utilisateurs, Bibliothèque, Serveurs liés. Neuf entrées au plus pour un administrateur, cinq
   pour un membre (épinglé par `settings_screen_test.dart`).
2. **Deux formes de regroupement.** Les pages courtes qu'on lit d'un trait s'empilent sur un seul
   défilement, chacune sous un intertitre (Serveurs + Synchro Emby + Liens de partage ;
   Bibliothèque + Métadonnées). Les pages longues ou lourdes à charger passent derrière des
   onglets (Activité : vue d'ensemble, historique, statistiques ; Utilisateurs : comptes,
   appareils, message à tous), pour ne pas tout charger d'un coup.
3. **Les pages n'en savent rien.** Elles construisent toujours un `SettingsPage` ;
   `SettingsPageFrame` dit à celui-ci s'il porte la catégorie (titre de la navigation, onglets,
   sections ajoutées après ses groupes) ou s'il n'est qu'une section.
4. **Une page garde son adresse.** `SettingsSections.activity` ouvre la catégorie Activité sur
   l'onglet Historique ; un lien entre deux onglets d'une même catégorie change d'onglet sur place.
5. **Le rare passe en sous-page.** Le journal et l'installation d'Onyx sur un autre appareil ne
   sont plus des entrées : ce sont des lignes de « Général » (groupes Aide et Autres appareils)
   qui ouvrent leur page par-dessus (`pushSettingsSubpage`).
6. **« Cet appareil » devient « Général »** et ne montre plus la place des téléchargements : elle
   reste dans « Téléchargements », seul endroit où on la gère.

## Conséquences

- Une nouvelle page de réglages ne crée pas d'entrée d'office : elle rejoint la catégorie où on
  la chercherait, et une nouvelle entrée doit passer le test des neuf.
- Le tirer-pour-actualiser d'une page empilée est celui de la page qui la porte ; une section
  garde ses boutons d'action (« Actualiser » des liens de partage).
- `settings_ui.dart` repasse sous 800 lignes (la page et sa coquille vivent dans
  `settings_page.dart`) et sort de la liste du garde-fou de taille.
