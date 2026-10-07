# ADR-0046 — Un build « store », et ce que les magasins exigent dans l'app

- **Statut :** accepté, en cours. Le Go et le Dart sont testés, `flutter analyze` est propre.
  **Rien n'a encore été soumis à un magasin**, et l'icône adaptative n'a pas été regardée sur un
  appareil.
- **Date :** 2026-10-06
- **Portée :** l'identifiant de l'app (`app/android/app/build.gradle.kts`,
  `app/macos/Runner/Configs/AppInfo.xcconfig`), le drapeau `STORE_BUILD`
  (`app/lib/utils/store_build.dart`, `app/android/app/src/store/AndroidManifest.xml`), la
  suppression de son propre compte (`server/handlers/account_deletion.go`, `account_page.dart`),
  le groupe « À propos » et les textes légaux (`about_group.dart`, `legal_document_screen.dart`,
  `app/assets/legal/`), et les jobs Android et iOS de `.github/workflows/release.yml`.

## Contexte

Onyx se distribuait par son propre serveur : un APK, un DMG, un exe, que l'app sait remplacer
elle-même (ADR-0030). Pour passer sur Google Play et l'App Store, quatre choses manquaient, toutes
des motifs de rejet connus :

- les identifiants différaient d'une plateforme à l'autre, dont un `com.example` sur macOS ;
- l'app Android demandait `REQUEST_INSTALL_PACKAGES` et installait ses propres APK ;
- on pouvait créer un compte dans l'app, mais pas supprimer le sien ;
- l'app ne montrait ni politique de confidentialité, ni conditions, ni attribution TMDB, ni les
  licences LGPL de ses moteurs de lecture.

## Décision

1. **Un seul identifiant : `com.tsuky.onyx`**, celui qu'iOS et tvOS portaient déjà. Android
   (`applicationId` et `namespace`) et macOS s'y alignent.
2. **Un seul binaire source, deux distributions, un drapeau.** `--dart-define=STORE_BUILD=true`
   fait un build store ; sans lui, rien ne change pour la distribution par le serveur.
   `StoreBuild.enabled` est le seul point de lecture côté Dart (gardé par
   `store_build_test.dart`), et `build.gradle.kts` décode le même `dart-define` pour superposer
   un manifeste qui retire `REQUEST_INSTALL_PACKAGES`. Un build store :
   - ne cherche jamais de mise à jour sur le serveur (`UpdateChecker.findAvailableUpdate`) ;
   - ne montre pas la page « Applications ».

   L'onglet Demandes n'est pas touché : il reste masqué tant qu'aucun service n'est relié.
3. **Chacun supprime son compte**, `POST /api/auth/account/delete`, mot de passe redemandé. Le
   propriétaire est refusé : un serveur sans propriétaire redeviendrait vierge, et le premier
   inscrit en prendrait la tête. Il transfère d'abord la propriété.
4. **Les textes légaux sont embarqués** (`assets/legal/`), pas ouverts dans un navigateur : un
   téléviseur n'en a pas, et l'app démarre hors ligne (ADR-0025). Les moteurs natifs (mpv, FFmpeg,
   AetherEngine, Media3) sont déclarés au `LicenseRegistry`, qu'aucun paquet Dart n'alimente à
   leur place.
5. **La CI produit un App Bundle** (`store-android`, hors de `/api/downloads` et de la Release)
   et passe le drapeau à l'archive TestFlight. L'APK et l'IPA de sideloading restent complets.

## Alternatives écartées

- **Des *flavors* Gradle.** Flutter exige alors `--flavor` sur chaque commande, schémas Xcode
  compris ; tous les scripts de build et la CI auraient changé pour une permission à retirer.
- **Laisser le propriétaire supprimer son compte.** Sur un serveur à un seul compte, cela rouvre
  l'inscription du premier venu en tant que propriétaire.

## Conséquences

- **L'identifiant Android change : c'est une autre app pour Android.** Un APK `com.tsuky.onyx`
  ne remplace pas une installation `com.projectplayer.project_player_app` ; il s'installe à côté,
  sans session ni téléchargements. Les installations existantes se réinstallent une fois. Même
  chose sur macOS, où le trousseau et les préférences suivent l'identifiant.
- **Windows ne change pas.** `CompanyName` et `ProductName` de `Runner.rc` forment le dossier
  `%APPDATA%\com.example\app` où vit la session ; les renommer déconnecterait chaque poste.
- Les textes de `assets/legal/` sont un premier jet rédigé sans juriste, et les magasins demandent
  en plus une **URL publique** pour la politique de confidentialité.
- L'interface reste en français : la traduction est un chantier à part.
