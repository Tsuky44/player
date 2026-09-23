package streaming

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
)

// Les sous-titres texte d'une session HLS, écrits par le transcodeur lui-même.
//
// Ils étaient extraits à part : un second FFmpeg relisait le fichier entier —
// en deux passes au-delà de 6 Go — pendant que la session lisait déjà le même
// fichier, et le client interrogeait le serveur toutes les cinq secondes en
// attendant qu'ils soient prêts. Or le transcodeur démultiplexe déjà chaque
// paquet du conteneur, sous-titres compris : il suffit de lui demander d'en
// écrire le texte. Aucune lecture de plus, des répliques disponibles dès le
// point de reprise, et une horloge qui est déjà celle de la session — l'entrée
// est cherchée avec -ss, donc les temps repartent de zéro comme ceux des
// segments. Voir ADR-0031.

// maxLiveSubtitles borne le nombre de pistes qu'une session écrit. Du texte ne
// coûte presque rien, mais un remux d'anime en porte parfois une vingtaine, et
// chacune est une sortie de plus à ouvrir pour FFmpeg.
const maxLiveSubtitles = 16

// LiveSubtitleTracks liste les pistes texte (le N de 0:s:N) qu'une session
// écrit en WebVTT, dans l'ordre du conteneur.
//
// Seuls les codecs dont la conversion en WebVTT est sûre sont retenus : une
// sortie que FFmpeg refuse d'ouvrir ferait échouer la session entière, image
// comprise. Les sous-titres image restent le domaine de l'incrustation.
func LiveSubtitleTracks(probe *ProbeResult) []int {
	if probe == nil {
		return nil
	}
	var tracks []int
	for _, s := range probe.Subtitles {
		if s.Image || !isTextSubtitle(s.Codec) {
			continue
		}
		tracks = append(tracks, s.TypedIndex)
		if len(tracks) == maxLiveSubtitles {
			break
		}
	}
	return tracks
}

// LiveSubtitleFileName est le nom, dans le dossier de la session, du WebVTT
// de la piste 0:s:typedIndex.
func LiveSubtitleFileName(typedIndex int) string {
	return fmt.Sprintf("sub_%d.vtt", typedIndex)
}

// isLiveSubtitleFile reconnaît un nom produit par LiveSubtitleFileName.
func isLiveSubtitleFile(name string) bool {
	if !strings.HasPrefix(name, "sub_") || !strings.HasSuffix(name, ".vtt") {
		return false
	}
	_, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(name, "sub_"), ".vtt"))
	return err == nil
}

// liveSubtitleOutputArgs ajoute une sortie WebVTT par piste, après la sortie
// HLS.
//
// -flush_packets 1 est ce qui rend le fichier lisible au fil de l'eau : sans
// lui, le muxer garde ses répliques dans un tampon de 32 Kio, soit une bonne
// partie d'un film, et le client ne verrait rien arriver. Une réplique peut
// encore être à moitié écrite au moment d'une lecture : c'est au client de ne
// garder que les blocs complets.
func liveSubtitleOutputArgs(tmpDir string, tracks []int) []string {
	var args []string
	for _, typedIndex := range tracks {
		args = append(args,
			"-map", fmt.Sprintf("0:s:%d", typedIndex),
			"-c:s", "webvtt",
			"-flush_packets", "1",
			"-f", "webvtt",
			filepath.Join(tmpDir, LiveSubtitleFileName(typedIndex)),
		)
	}
	return args
}
