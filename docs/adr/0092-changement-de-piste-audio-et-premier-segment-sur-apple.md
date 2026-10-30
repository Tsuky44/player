# ADR-0092 — Piste audio et premier segment sur Apple

- **Statut :** accepté, à vérifier sur Mac et iPhone (le Swift n'est pas compilé sous Windows)
- **Date :** 2026-10-30
- **Portée :** `packages/onyx_player_apple`, AetherEngine 7.42

## Contexte

Journal macOS 1.1.26 (Spider-Man, 3832×1600 HEVC, EAC3 Atmos en stream-copy) :

1. Changer de piste audio en lecture fait `reload begin … resumeAt=2313.60s`, un nouveau
   `HLSVideoEngine` et un nouvel item AVPlayer : ~0,7-1 s sans image.
2. Au démarrage, `seg575: served 15638093 B (wait=1102.8ms)` : le premier segment attend 1,1 s.

## Décision

**Audio.** Un changement sans rechargement n'est pas faisable avec AetherEngine 7.42. Sa boucle HLS
locale n'écrit qu'**une** rendition audio (`masterAudioRendition`, muxée, sans URI) : il n'existe
pas de `AVMediaSelectionGroup` audio à basculer. Les pistes listées ne sont que celles du MKV.
Régénérer un flux audio seul demanderait un correctif dans le moteur (LGPL : à publier) : hors
portée. Le moteur fait déjà `selectAudioTrack` → `reloadWithAudioOverride` en gardant l'image
(`holdPictureAcrossItemSwap`, depuis 7.29), en reprenant à la position exacte
(`positionForSessionRebuild`) et en réarmant le sous-titre (piste du fichier, WebVTT, PGS affiché).
Le plugin ne le contourne pas ; il documente le coût. À suivre : la 7.43+ (`#348`, segments produits
pendant le changement de mode de l'écran) demande Swift 6.1 / Xcode 16.3, hors de cet ADR.

**Premier segment.** `LoadOptions.progressiveSegmentDelivery = true` pour le fichier brut : la
boucle locale envoie chaque fragment (~0,5 s) dès qu'il est écrit au lieu d'attendre la coupe des
~15 Mo. Le HLS de transcodage (`.m3u8`) garde le comportement par défaut. Aucun changement de
flux : Dolby Vision et Atmos en stream-copy restent des octets recopiés, seule la livraison change.

## Conséquences

- Gain attendu sur `wait=` du premier segment : de ~1,1 s vers ~0,5 s (à mesurer).
- Risque : jamais mesuré ici avec DV / Atmos. À vérifier sur appareil ; en cas de régression,
  retirer la ligne (le test garde la signalera).
