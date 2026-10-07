# ADR-0047 — L'interface en anglais, par un dictionnaire dont le français est la clé

- **Statut :** accepté, en cours. `flutter analyze` est propre et la suite de tests passe ; le
  dictionnaire couvre chaque texte passé à `tr()`. **L'interface anglaise n'a été relue sur aucun
  écran réel** : ni les débordements de mise en page, ni le ton, ni les pluriels.
- **Date :** 2026-10-06
- **Portée :** `app/lib/l10n/` (`tr.dart`, `app_language.dart`, `en.dart`), tous les textes
  affichés de `app/lib/`, le réglage « Langue » de `device_page.dart`, le démarrage dans
  `main.dart`. Ni le serveur, ni les textes légaux de `assets/legal/`, ni les fiches natives
  (`Info.plist`).

## Contexte

L'app n'existait qu'en français, textes en dur dans ~170 fichiers. Les magasins d'applications
attendent au moins l'anglais (ADR-0046), et la fiche store en a déjà une version.

## Décision

**Le texte français écrit dans le code est la clé de sa traduction.**

1. `tr('Annuler')` rend le texte dans la langue de l'app. `kEnglish` (`en.dart`) associe chaque
   texte français à son anglais ; une clé absente retombe sur le français.
2. Une valeur variable passe en argument : `tr('Saison {0}', [n])`. Une phrase interpolée
   (`'Saison $n'`) aurait une clé différente à chaque valeur.
3. `AppLanguage` porte la langue : celle choisie dans Paramètres › Cet appareil, sinon le
   français sur un appareil en français et l'anglais partout ailleurs. Elle est lue avant la
   première image. En changer reconstruit l'app depuis sa racine.
4. **Le français reste la langue par défaut du code**, donc celle des tests : ils cherchent les
   textes tels qu'ils sont écrits.
5. Une table constante (mois, langues, libellés d'énumération) ne peut pas appeler `tr()` : c'est
   son point d'affichage qui traduit, ou un accesseur (`String get label => tr(_label)`).
6. `test/l10n_coverage_test.dart` échoue si un texte passé à `tr()` n'a pas d'entrée dans
   `en.dart`, ou si une traduction réclame une valeur que sa clé n'offre pas.

On continue d'écrire l'interface en français, en phrases : la règle du dépôt ne change pas, elle
gagne une étape — envelopper le texte dans `tr()` et ajouter son entrée.

## Alternatives écartées

- **`gen-l10n` et des fichiers ARB.** Chaque texte devient un identifiant
  (`l10n.settingsAccountDeleteTitle`) qu'il faut nommer, et qui demande un `BuildContext` — que
  n'ont ni les providers ni les services qui fabriquent des messages d'erreur. Le français
  disparaît du code, et les ~860 tests qui cherchent un texte devraient charger les délégués.
- **Traduire côté serveur.** Les messages d'erreur du serveur restent en français ; ils ne sont
  qu'une petite partie de ce que l'utilisateur lit.

## Conséquences

- Les pluriels écrits `{0} épisode{1}` reçoivent le même `s` en anglais qu'en français : juste
  quand les deux langues mettent un `s`, approximatif ailleurs.
- Un texte fabriqué dans un argument (`cond ? 'a' : 'b'` à l'intérieur d'un `tr`) doit lui-même
  passer par `tr()` ; le test de couverture ne voit que les littéraux directs.
- Les messages du serveur, les textes légaux et les descriptions d'autorisations d'iOS restent
  en français.
- Material n'est pas localisé (`flutter_localizations` n'est pas embarqué) : ses rares textes
  propres, comme la page des licences, restent en anglais dans les deux langues.
