# ADR-0031 — Les sous-titres texte d'une session HLS sont écrits par la session elle-même

- **Statut :** accepté. Le serveur et le client sont en place et testés, contre un vrai FFmpeg
  côté serveur. Reste à valider sur un long remux en production, sur Android TV et sur Apple TV.
- **Date :** 2026-09-23
- **Portée :** les sous-titres texte pendant un transcodage ou une recopie HLS
  (`server/streaming/live_subtitles.go`, `server/streaming/handler.go`,
  `app/lib/screens/player/playback/live_subtitles.dart`, le contrôleur du lecteur). Le Direct Play
  ne change pas : le moteur y lit les pistes du fichier lui-même. Les sous-titres image (PGS,
  VOBSUB) restent incrustés dans l'image par la session.
- **Contredit l'ADR-0009 (§6)**, qui faisait passer les sous-titres d'ExoPlayer par les `.vtt`
  extraits et rebasés par le backend, **et l'ADR-0028**, qui faisait de même pour AVPlayer.

## Contexte

Un sous-titre texte n'a besoin du serveur qu'en HLS : le web et l'Apple TV, qui ne lisent que du
HLS, et toute session transcodée ou recopiée ailleurs. Jusqu'ici, le serveur l'extrayait à part :

- **un second FFmpeg relisait le fichier entier**, en deux passes au-delà de 6 Go (quinze minutes
  d'abord, puis le reste), pendant que la session lisait déjà le même fichier sur le même disque ;
- **le client interrogeait le serveur toutes les cinq secondes** en attendant que la piste soit
  « prête », puis téléchargeait le `.vtt`, que le serveur décalait (`ShiftVTT`) pour l'aligner sur
  une session commencée en cours de film ;
- **le fichier était injecté dans le moteur** : `sub-add` pour mpv, peu fiable pendant un flux
  HLS ; un sous-titre externe pour ExoPlayer, qui rouvre alors le média ;
- **la route qui déclenchait l'extraction exigeait `manage_library`**, alors que le lecteur
  l'appelait pour tout le monde : un compte ordinaire n'obtenait jamais ses sous-titres en HLS
  sur une piste qu'aucun administrateur n'avait lue avant lui.

## Décision

**Le FFmpeg de la session écrit lui-même chaque piste texte**, en WebVTT, à côté de ses segments
(`sub_<N>.vtt`, N étant la place de la piste parmi les sous-titres du conteneur). C'est une sortie
de plus sur la même commande : le transcodeur démultiplexe déjà chaque paquet du fichier, et du
texte ne coûte presque rien à encoder.

- **Aucune lecture en plus.** La session lit le fichier une fois, pour l'image, le son et le texte.
- **L'horloge est déjà la bonne.** L'entrée est cherchée avec `-ss`, donc les temps des répliques
  repartent de zéro au point de reprise, comme ceux des segments et comme la position du moteur.
  `ShiftVTT` n'a plus lieu d'être.
- **Les répliques arrivent avec la session**, une trentaine de secondes devant la tête de
  lecture : c'est l'avance que garde le transcodeur avant de se mettre en pause (le JIT de
  `session.go`). Toutes les pistes texte sont écrites, jusqu'à seize, donc changer de langue ne
  coûte rien.
- **`-flush_packets 1`** rend le fichier lisible au fil de l'eau. Sans lui, le muxer garde 32 Kio
  de répliques en tampon, soit une bonne partie d'un film.
- **`/start` annonce les pistes** avec l'adresse où chacune grandit (`subtitles` : `typed_index`,
  `url`). L'adresse porte le ticket de la session. Une piste sans réplique pour l'instant répond
  204 ; une lecture sans rien de neuf répond 416. Ces relevés ne gardent pas une session en vie :
  seul le moteur le fait, en tirant ses segments.
- **Le client relit la suite du fichier toutes les quatre secondes** (`Range: bytes=N-`), ne garde
  que les blocs terminés par une ligne vide (une lecture peut tomber au milieu d'une réplique, ou
  d'un caractère UTF-8), et **peint les lignes avec Flutter** (`LiveSubtitleLayer`, habillage de
  `SubtitleOverlay`), pour tous les moteurs et sur toutes les plateformes, web compris. Le moteur,
  lui, reste sans sous-titre.
- **Les pistes que la session écrit sont marquées prêtes** dans le catalogue du lecteur. Toute la
  mécanique d'extraction (bouton, attente, relevés) s'éteint alors pour elles, sans être retirée.

## Conséquences

- Le bug du 403 disparaît pour ce client : il ne demande plus d'extraction.
- **Un serveur plus ancien n'annonce pas `subtitles`** : le client retombe alors sur l'extraction
  d'avant, inchangée. À l'inverse, **un client plus ancien face à ce serveur** continue d'utiliser
  la route d'extraction, qui reste en place. On pourra la retirer (extracteur, table `subtitles`,
  bouton d'extraction, `ShiftVTT`) quand les applications installées auront toutes été mises à
  jour.
- Une réplique déjà à l'écran pile au point de reprise manque : ce qui commence avant `-ss` n'est
  pas écrit. Elle réapparaît à la réplique suivante.
- Le style ASS est perdu, comme il l'était déjà avec les `.vtt` extraits.
- Sur le web, les sous-titres sont peints par Flutter au-dessus du `<video>`, plus par une piste
  `<track>` du navigateur. Ils ne suivent donc pas le plein écran natif de la balise vidéo, seulement
  celui de l'app.
- Une piste qu'on ne sait pas convertir sûrement en WebVTT n'est pas écrite : une sortie que FFmpeg
  refuse d'ouvrir ferait échouer toute la session. Seuls `subrip`, `ass`, `ssa`, `mov_text`,
  `webvtt` et `text` sont retenus.

## Alternatives écartées

- **Les sous-titres HLS standard** (`EXT-X-MEDIA TYPE=SUBTITLES`, segmentés par le muxer HLS).
  hls.js, AVPlayer et ExoPlayer les gèrent, mais le démultiplexeur HLS de FFmpeg, donc mpv, ne le
  fait pas de façon fiable. Le rendu différerait d'une plateforme à l'autre. À reconsidérer pour
  l'Apple TV seule, si le style natif y devenait un besoin.
- **Un extracteur Matroska en Go**, qui ne lirait que les blocs de sous-titres en sautant le reste
  à l'aide de l'index. Le gain sur un disque réseau est incertain (la lecture anticipée ramène de
  toute façon les blocs voisins), pour un analyseur de conteneur de plus à maintenir.
- **Garder l'extraction préalable, en ouvrant simplement la route aux comptes connectés.** Corrige
  le 403 mais laisse la double lecture du fichier, l'attente et l'injection dans le moteur.
