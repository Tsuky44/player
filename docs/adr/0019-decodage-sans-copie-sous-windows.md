# ADR-0019 — Sous Windows, l'image décodée reste sur le GPU

- **Statut :** proposé. Le build applique le correctif et l'app sait revenir en arrière. La
  mesure avant/après sur une vraie lecture reste à faire (voir « À vérifier »).
- **Date :** 2026-09-15
- **Portée :** le lecteur mpv sous Windows (`packages/media_kit_libs_windows_video`, décodeur
  matériel dans `hardware_decoding.dart`). La texture Flutter de media_kit ne change pas, ni le
  reste de la chaîne.

## Contexte

Sous Windows, media_kit fait dessiner mpv en OpenGL ES dans une texture Flutter, par ANGLE. Le
décodeur matériel choisi était toujours `d3d11va-copy` : le GPU décode l'image, elle est recopiée
en mémoire vive, puis renvoyée au GPU pour être dessinée. En 4K HDR (P010, ~24 Mo par image), cette
recopie coûte de l'ordre d'un tiers de cœur sur un Ryzen 7 3700X, en permanence — et c'est ce qui
manque à une petite machine pour tenir la cadence. macOS (ADR-0015) et Android (ADR-0009) n'ont
pas cette étape.

Rendre la texture plus petite ne change rien : mesuré à 3840x2080, 1920x1040 et 1280x694, la charge
reste la même (35 à 38 % d'un cœur, ~11 % du GPU). Le coût est la recopie, pas le dessin.

mpv sait éviter cette recopie dans ce montage : son interop `d3d11-egl` fait passer la texture du
décodeur à ANGLE par un flux EGL, sans quitter le GPU. Elle ne se chargeait jamais (« Loading
failed. » dans le journal de mpv, sans autre message). Un programme de test sur l'ANGLE livré
avec media_kit (2.1.18844) montre pourquoi :

| Ce que l'interop exige | ANGLE |
|---|---|
| `EGL_ANGLE_d3d_share_handle_client_buffer` (affichage) | oui |
| `EGL_ANGLE_stream_producer_d3d_texture` (affichage) | oui |
| `EGL_EXT_device_query` **dans les extensions d'affichage** | **non** |
| `EGL_EXT_device_query` dans les extensions client | oui |
| `eglQueryDisplayAttribEXT(EGL_DEVICE_EXT)` → périphérique D3D11 | fonctionne |
| Décodage vidéo sur ce périphérique, HEVC Main10 compris | oui |

ANGLE déclare `EGL_EXT_device_query` comme extension client, et mpv la cherche parmi celles de
l'affichage. Cette seule vérification désactive l'interop. Elle est écrite de la même façon dans
mpv 0.41.

Une DLL `libEGL.dll` intermédiaire, qui aurait ajouté l'extension à la liste, a été essayée : le
lecteur se bloquait avant même le premier appel. Abandonnée.

## Décision

### 1. Le libmpv livré est corrigé au build

`windows/patch_libmpv.ps1` remplace, dans `libmpv-2.dll`, le nom exigé par `EGL_KHR_stream` :
une extension d'affichage qu'ANGLE déclare, et dont l'interop se sert de toute façon. La chaîne
n'apparaît qu'une fois dans la DLL, sa longueur est gardée et le reste est complété par des zéros.
Le script refuse toute DLL dont le MD5 n'est pas celui de l'archive épinglée, et vérifie le MD5 du
résultat. Si l'interrogation du périphérique échouait malgré tout, mpv le signale et reprend la
copie, comme avant.

Corriger le binaire plutôt que recompiler mpv : le changement tient en une vérification, et un
build Windows complet de mpv et de ses dépendances (chaîne MinGW, FFmpeg, libplacebo…) se compte
en heures et devient une chaîne de plus à maintenir. Si mpv corrige la vérification, le script
s'arrête de lui-même au prochain changement d'archive (la chaîne ne sera plus trouvée) et se
supprime.

### 2. L'archive est réextraite quand elle change

L'extraction ne se faisait que dans un dossier vide. Un build existant gardait donc la DLL de
l'archive précédente : le passage au build shinchiro (FFmpeg complet, pour le TrueHD) n'avait
jamais atteint les builds locaux, qui lisaient encore mpv 0.36 de 2023. L'extraction a lieu
maintenant à la configuration, et recommence dès que le fichier témoin
(`build/…/libmpv/onyx-libmpv.stamp`) ne nomme plus l'archive et le MD5 corrigé attendus.

### 3. `auto-safe` choisit, l'app rattrape l'échec

Rien ne change dans ce que l'app demande : `hwdec=auto-safe`, dont la liste blanche essaie `d3d11va`
sans copie avant `d3d11va-copy`. Quand l'interop ne se charge pas, mpv prend la copie.

Le cas à rattraper est une interop chargée qui échoue ensuite (un pilote qui refuse le flux EGL) :
mpv tombe alors sur le décodage logiciel, pas sur la copie — le même piège qu'avec MediaCodec sur
Android. La vérification qu'Android faisait après la première image couvre donc aussi Windows : une
image de 1440 lignes ou plus décodée en logiciel alors que la préférence est « auto » fait passer la
lecture, et le reste de la session, sur `d3d11va-copy`.

## À vérifier

- Sur une vraie lecture 4K HDR : `hwdec-current` vaut `d3d11va`, la charge processeur baisse
  nettement par rapport à `d3d11va-copy`, l'image et les couleurs sont justes.
- Sur un GPU Intel et un GPU NVIDIA : l'interop se charge, ou la lecture retombe proprement sur la
  copie.
- Le bascule logiciel → copie sur un pilote qui refuse le flux.

## Conséquences

- Le correctif est lié à une archive précise. Changer `LIBMPV` impose de refaire le correctif ou de
  mettre à jour les deux MD5 — le build échoue sinon, ce qui est voulu.
- Les builds locaux passent de mpv 0.36 au build épinglé (août 2026) : ce que la CI livrait déjà.
- La texture Flutter reste le chemin de Windows : ni Dolby Vision (voir ADR-0015), ni sortie HDR.
  Ces deux-là demandent que mpv dessine lui-même, ce que Flutter ne permet pas encore sous Windows.
