package streaming

import (
	"context"
	"log"
	"os/exec"
	"sync"
	"time"
)

// ToneMapper est la chaîne de filtres qui ramène une source HDR en SDR, et ce
// qu'elle demande à la ligne de commande FFmpeg. Voir ADR-0060.
type ToneMapper struct {
	// Filter est la chaîne à placer après la mise à l'échelle, ou "" quand ce
	// FFmpeg ne sait pas en faire une.
	Filter string
	// Vulkan dit que la chaîne passe par libplacebo : la commande doit ouvrir
	// un périphérique Vulkan (`-init_hw_device vulkan`). Sans lui, le filtre
	// n'accepte pas le rendu logiciel et meurt à l'initialisation.
	Vulkan bool
}

// toneMapperFor choisit la chaîne pour cette source.
//
// Un Dolby Vision profil 5 n'est pas du HDR10 : sa couche de base est en
// IPTPQc2, et seule la couche RPU dit comment en revenir. zscale ne la lit pas
// et prend ces valeurs pour du YCbCr BT.2020 — les visages sortent roses et
// verts, tone mapping compris. libplacebo est le seul filtre de FFmpeg qui
// applique la RPU (`apply_dolbyvision`, actif par défaut).
//
// Sans libplacebo utilisable, le profil 5 retombe sur zscale : une image aux
// couleurs fausses vaut mieux qu'une session qui ne démarre pas, et le journal
// dit une fois ce qui manque.
func toneMapperFor(v *VideoStreamInfo) ToneMapper {
	if v != nil && needsDolbyVisionDecoder(v) {
		if libplaceboUsable() {
			return ToneMapper{Filter: doviToSDRFilter, Vulkan: true}
		}
		warnNoDoviTonemapOnce.Do(func() {
			log.Printf("streaming: this FFmpeg cannot run the libplacebo filter (no " +
				"Vulkan device) — Dolby Vision profile 5 sources that have to be " +
				"re-encoded will come out pink and green. Install a Vulkan driver " +
				"(mesa-vulkan-swrast for a CPU-only host) to fix it.")
		})
	}
	return ToneMapper{Filter: hdrToSDRFilter()}
}

// doviToSDRFilter applique la RPU puis fait le même trajet que
// hdrToSDRFilter : Hable, retour en BT.709, 8 bits 4:2:0.
//
// Tout ce qui suit `format` coupe ce que libplacebo fait par défaut pour un
// écran et qu'un rendu Vulkan logiciel (lavapipe) ne tient pas en temps réel.
// Mesuré sur 16 threads, 4K HEVC vers 1080p x264 : 12 images/s avec les
// défauts, 30 avec ces réglages. La détection de crête et le gamut perceptuel
// coûtent le plus ; `disable_linear` et `skip_aa` ne changent rien à l'image,
// la mise à l'échelle étant faite avant le filtre.
const doviToSDRFilter = "libplacebo=tonemapping=hable" +
	":colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" +
	":format=yuv420p" +
	":peak_detect=false:gamut_mode=clip:contrast_recovery=0:dithering=none" +
	":disable_linear=true:skip_aa=true"

var (
	libplaceboOnce        sync.Once
	libplaceboOK          bool
	warnNoDoviTonemapOnce sync.Once
)

// setLibplaceboForTest fige la réponse de libplaceboUsable, pour qu'un test
// exerce les deux côtés du choix quel que soit le FFmpeg de la machine.
func setLibplaceboForTest(usable bool) {
	libplaceboOnce.Do(func() {}) // consomme le once : aucune sonde n'écrasera
	libplaceboOK = usable
}

// libplaceboUsable dit si ce FFmpeg peut réellement exécuter libplacebo.
//
// La liste des filtres ne suffit pas : le filtre est compilé dans le FFmpeg
// d'Alpine, mais il lui faut un périphérique Vulkan à l'exécution, et une image
// sans pilote n'en a aucun. La seule réponse fiable est de filtrer une image.
// Demandé une fois par processus : c'est un fork et une seconde.
func libplaceboUsable() bool {
	libplaceboOnce.Do(func() {
		if !ffmpegHasFilter("libplacebo") {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		err := exec.CommandContext(ctx, "ffmpeg",
			"-hide_banner", "-loglevel", "quiet", "-nostdin",
			"-init_hw_device", "vulkan",
			"-f", "lavfi", "-i", "color=c=black:s=64x64",
			"-frames:v", "1",
			"-vf", "libplacebo=format=yuv420p",
			"-f", "null", "-",
		).Run()
		libplaceboOK = err == nil
	})
	return libplaceboOK
}
