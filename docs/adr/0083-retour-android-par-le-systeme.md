# ADR-0083 — Sur Android, Retour passe par le système et lui seul

- **Statut :** accepté. Constaté puis vérifié sur l'émulateur Android TV 16 (API 36, x86_64) ;
  pas encore vu sur un téléviseur Android 11 à 15.
- **Date :** 2026-10-28
- **Portée :** `isSelfHandledBackKey` et `tvSelectShortcuts` (`app/lib/tv/tv_focus.dart`),
  `routePlayerKey`, `PlayerPopupHost.back` et le menu des réglages du lecteur ; la sortie d'un
  champ de saisie sur Android TV et Apple TV (`tv_deferred_keyboard.dart`,
  `web_tv_field_exit.dart`).

## Contexte

Sur l'émulateur Android TV 16, un appui sur Retour arrive **deux fois** dans Flutter : en touche
(`LogicalKeyboardKey.goBack`), puis en `popRoute`, **même quand la touche a été traitée**. Les
traces posées dans le lecteur le montrent pour un seul appui :

```
TRACEBACK key Go Back browsing=true
TRACEBACK popRoute browsing=false
```

Chaque endroit qui traitait la touche défaisait donc deux couches par appui :

- dans le lecteur, Retour rangeait la barre de contrôle (touche), puis quittait le film
  (`popRoute`) ;
- sur une feuille ou un dialogue, le raccourci `goBack → DismissIntent` fermait la feuille, puis
  `popRoute` fermait la page en dessous. Retour sur « Ajouter à une liste » ramenait à l'accueil ;
- dans un menu du lecteur, Retour remontait d'une section, puis fermait le menu.

`TvBackAction` était déjà désactivée sur Android pour cette raison (« doing it here too would pop
twice »), mais la règle n'était pas appliquée aux autres endroits qui lisent `kTvBackKeys`.

## Décision

1. **Sur Android, `goBack` n'est jamais traité comme une touche.** `isSelfHandledBackKey(key)`
   le dit à chaque endroit qui lisait `kTvBackKeys` : le routage des touches du lecteur, la
   portée des menus du lecteur et le menu des réglages. `tvSelectShortcuts` ne lie plus `goBack`
   sur Android. Le système en fait un `popRoute` : un seul chemin, que l'Android plus ancien
   emprunte aussi (une touche non traitée y est rejouée vers `onBackPressed`).
2. **Le chemin `popRoute` est complet.** Le Retour du lecteur passe par `PlayerPopupHost.back()`,
   qui laisse d'abord le menu ouvert répondre (`PlayerPopupBackIntent` : une section remonte à
   l'index) avant de le fermer. Ensuite viennent le panneau des épisodes, la barre, puis le film,
   comme le prévoit l'ADR-0006.
3. **Les autres touches Retour restent des touches** : Échap d'un clavier, le Menu de la Siri
   Remote, le B d'une manette. Aucun système ne les rejoue en `popRoute`.

## Conséquences

- Un appui sur Retour défait une couche, et une seule, sur Android 16 comme sur les versions
  précédentes.
- Un nouveau widget qui veut réagir à Retour sur Android passe par un `PopScope` ou par une
  `Action` que le chemin `popRoute` invoque, jamais par `onKeyEvent` sur `goBack`. Le test
  `tv_navigation_test.dart` épingle le partage des touches hors Android.
- Retour qui ferme le clavier d'Android TV (Gboard) ne retire pas le focus au champ, et Android
  n'en signale rien à l'app (aucune hauteur de clavier déclarée). Un champ resté focalisé se
  relâche donc au Retour suivant (`TvDeferredKeyboardState.releaseFocused`, appelé par la
  coquille) ou à la première flèche (`WebTvFieldExit`, installé aussi sur Android), qui fait
  dans la foulée le pas demandé.
- **Apple TV.** Le Menu de la Siri Remote arrive en touche (Échap) et jamais en `popRoute` : il
  n'a pas de doublon, et passe par `TvBackAction` jusqu'au même `PopScope`, donc par
  `releaseFocused`. `WebTvFieldExit` y est installé aussi, avec les quatre flèches, par
  précaution : son clavier plein écran garde le trackpad tant qu'il est ouvert, et le filet ne
  joue que si le champ reste focalisé après. Rien de cela n'a encore été essayé sur une Apple
  TV.
- Reste à vérifier sur un téléviseur Android 11 à 15 que la touche non traitée y devient bien un
  `popRoute`. Si un modèle ne le fait pas, Retour n'y aurait plus d'effet dans le lecteur : c'est
  le premier endroit à regarder.
