# Interface

La direction s'appelle **Quiet Premium** : une scène charbon OLED, un accent bleu utilisé avec parcimonie, un mouvement bref. L'image du média porte l'émotion, le chrome s'efface.

## Sources de vérité

- `PROJECT_DESIGN.md` est le contrat visuel en vigueur : palette, typographie, composants, mouvement (§10), à faire et à éviter (§11). Lis la section du composant que tu touches.
- `PRODUCT.md` porte les principes produit et l'accessibilité.
- `design.md` est l'ancien brief « Cinematic Glass ». Il sert de référence, et `PROJECT_DESIGN.md` l'emporte en cas de désaccord.
- `docs/specs/player-ui-skins.md` couvre les skins du lecteur et le studio.
- Pour le savoir-faire UI approfondi (critique, polish, audit, animation, accessibilité), lis `.agents/skills/impeccable/SKILL.md` et `.agents/skills/tasteful-ui/SKILL.md` par leur chemin. Les liens de `.claude/skills/` vers ces dossiers sont cassés sous Windows.

## Tokens

- Couleurs : `AppColors` (`theme/app_colors.dart`). Mouvement : `AppMotion` (`theme/app_motion.dart`). Thème : `AppTheme`.
- Le nouveau code n'écrit ni `Color(0x…)` ni `Duration(milliseconds: …)` d'animation. Il reste ~110 couleurs brutes et ~110 durées brutes : convertis celles des lignes que tu touches.
- Une valeur qui manque s'ajoute au fichier de tokens, avec un commentaire sur son rôle, avant d'être utilisée.
- Mouvement : durées de 180 à 280 ms (`micro`, `standard`, `emphasis`) et une seule courbe, `AppMotion.curve`. `AppMotion.fade(context)` sert à l'opacité et aux couleurs (conservé sous « réduire les animations »). `AppMotion.move(context)` sert à tout ce qui est géométrique (ramené à zéro).
- Le lancement d'une lecture depuis « Reprendre » est un zoom simple. La page du lecteur ne subit jamais de transformation (rideau abandonné).

## Composants imposés

| Besoin | Utilise | Pourquoi |
|---|---|---|
| Curseur | `AppSlider` | Le `Slider` de Material fige l'arbre d'accessibilité sous Windows (ADR-0024). |
| Champ de saisie | enveloppé par `TvDeferredKeyboard` | Sur TV, le clavier plein écran piège le focus. Imposé par `no_bare_text_field_test.dart`. |
| Image réseau | `AppNetworkImage` + `utils/poster_url.dart` | Décodage à la taille affichée et cache partagé. |
| Chargement, vide, erreur | `LoadingView`, `EmptyStateView`, `ErrorStateView` | Un seul langage pour les trois états. |
| Page de réglages | `SettingsPage`, `SettingsGroup`, `SettingsTile`… (`settings/widgets/settings_ui.dart`) | Une mise en page et une densité cohérentes. |
| Mise en page, grilles | `Responsive` (`utils/responsive.dart`) | Points de rupture, marges, colonnes d'affiches et taille tactile minimale. |
| Verre, chrome | `glass_chrome.dart`, `control_chrome.dart` | Un seul rendu de verre. |

Avant de créer un composant, cherche dans `widgets/global/` et dans les `widgets/` de l'écran voisin. Un composant utilisé par un deuxième écran monte dans `widgets/global/`.

## TV et télécommande

Chaque écran atteignable sur TV se pilote entièrement au D-pad.

- Activer : `kTvSelectKeys`. Revenir : `kTvBackKeys`. Tous deux sont dans `tv/tv_focus.dart`, jamais réécrits par widget.
- Le focus est toujours visible (ADR-0008), il est mémorisé par ligne au retour sur l'écran (`tv_focus_memory.dart`, `tv_focus_rows.dart`), et le premier élément utile le reçoit à l'ouverture.
- L'échelle vient de `tv_ui_scale.dart`, et la répétition des touches de `tv_key_repeat.dart`.
- Le lecteur à la télécommande suit ADR-0006.
- Un écran TV nouveau ou modifié reçoit un test de focus sur le modèle de `tv_focus_test.dart` ou `onyx_settings_menu_tv_test.dart`.

## Qualité d'écran

- **Trois états** pour toute donnée asynchrone : chargement, vide et erreur avec une action pour réessayer. Les données en cache s'affichent pendant la revalidation.
- **Poids de l'arbre** (ADR-0025) : garde de la légèreté sous Windows. Utilise des constructeurs `.builder` pour les listes longues, un `const` partout où c'est possible, et découpe en petits widgets pour que chaque `setState` ou `notifyListeners` ne reconstruise que ce qui change.
- **Accessibilité** : un bouton-icône porte un `tooltip` ou un label `Semantics`, et les cibles tactiles respectent `Responsive.minTouchTarget`. Le texte suit la hiérarchie de `PROJECT_DESIGN.md` §7.
- **Textes** : français, en phrases, courts. Un message d'erreur dit ce qui s'est passé et quoi faire.
- **Vérification** : lance l'app, puis regarde l'écran en largeur téléphone et en largeur desktop, avec le focus TV si l'écran est concerné, et sous « réduire les animations » si tu as ajouté du mouvement. Pour une passe de finition, applique `.agents/skills/impeccable/reference/polish.md`.
