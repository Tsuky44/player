package streaming

import "testing"

// Un barreau de l'échelle est une promesse de débit (ADR-0022). Mesuré sur un
// fichier H.264 à 10 Mbit/s : « 1080p · 4 Mbit/s » recopiait le fichier et en
// envoyait 10, si bien que descendre d'un barreau ne soulageait pas la ligne
// (ADR-0056).
func TestPlanVideo_ARungNeverCopiesAFileHeavierThanItself(t *testing.T) {
	probe := &ProbeResult{Video: &VideoStreamInfo{
		Width: 1920, Height: 1080, Codec: "h264", PixFmt: "yuv420p",
	}}
	const ceiling = 12_000_000
	caps := LegacyCapabilities()

	for _, quality := range []string{"1080p-4m", "1080p-2m"} {
		plan := PlanVideo(probe, quality, false, 10_000_000, ceiling, caps)
		if plan.Copy {
			t.Errorf("%s : un fichier à 10 Mbit/s recopié envoie 10 Mbit/s, pas le débit du barreau", quality)
		}
		if plan.Reason == "" {
			t.Errorf("%s : un refus de recopie doit dire pourquoi", quality)
		}
	}

	// Un fichier plus léger que le barreau tient sa promesse tel quel.
	if !PlanVideo(probe, "1080p-10m", false, 8_000_000, ceiling, caps).Copy {
		t.Error("1080p-10m : un fichier à 8 Mbit/s est sous le barreau, il se recopie")
	}
	// Un débit inconnu ne prouve rien : comme avant, la recopie reste permise.
	if !PlanVideo(probe, "1080p-4m", false, 0, ceiling, caps).Copy {
		t.Error("sans débit connu, le barreau ne peut pas refuser la recopie")
	}
}

// Le barreau d'origine de la résolution du fichier est celui que le web et les
// replis demandent pour obtenir la recopie : il ne promet pas un débit.
func TestPlanVideo_TheNativeRungStillCopiesUpToTheCeiling(t *testing.T) {
	caps := LegacyCapabilities()
	for _, source := range []struct {
		name          string
		width, height int
		quality       string
	}{
		{"1080p", 1920, 1080, "1080p"},
		{"un film en scope, 1920×804", 1920, 804, "1080p"},
		{"720p", 1280, 720, "720p"},
	} {
		probe := &ProbeResult{Video: &VideoStreamInfo{
			Width: source.width, Height: source.height, Codec: "h264", PixFmt: "yuv420p",
		}}
		if !PlanVideo(probe, source.quality, false, 10_000_000, 12_000_000, caps).Copy {
			t.Errorf("%s : le barreau natif recopie un fichier sous le plafond de recopie", source.name)
		}
		if PlanVideo(probe, source.quality, false, 20_000_000, 12_000_000, caps).Copy {
			t.Errorf("%s : le plafond de recopie vaut toujours", source.name)
		}
	}
}

func TestIsNativeTier(t *testing.T) {
	for _, c := range []struct {
		quality string
		height  int
		want    bool
	}{
		{"1080p", 1080, true},
		{"1080p", 804, true},
		{"1080p-4m", 1080, false},
		{"720p", 1080, false},
		{"2160p", 2160, true},
		{"2160p-20m", 2160, false},
		{"inconnu", 1080, false},
	} {
		if got := isNativeTier(c.quality, c.height); got != c.want {
			t.Errorf("isNativeTier(%q, %d) = %v, attendu %v", c.quality, c.height, got, c.want)
		}
	}
}

// Une piste audio recopiée part du point-clé où FFmpeg a cherché, avant la
// seconde demandée, et le multiplexeur décale toute la session d'autant.
// Mesuré (ADR-0056) : session demandée à 57 s, points-clés pairs, une seconde
// de son rejouée et une position affichée une seconde trop loin.
func TestBuildFFmpegArgs_CopiedAudioStartsAtTheRequestedSecond(t *testing.T) {
	build := func(start int, videoCopy bool) []string {
		return BuildFFmpegArgs(TranscodeOptions{
			InputPath: "/x.mkv", Quality: "720p", TmpDir: "/tmp/x", SegmentDuration: 2,
			StartSeconds:      start,
			Probe:             probeWith(1920, 1080, 24, AudioStreamInfo{Codec: "aac", Channels: 2}),
			AudioTypedIndexes: []int{0},
			Video:             VideoPlan{Copy: videoCopy},
			Caps:              surroundCaps(),
		})
	}

	if got, ok := argValue(build(57, false), "-copypriorss:a:0"); !ok || got != "0" {
		t.Errorf("image encodée, son recopié : -copypriorss:a:0 = %q, attendu 0", got)
	}
	// Recopiée, l'image part du point-clé : le son doit l'accompagner.
	if _, ok := argValue(build(57, true), "-copypriorss:a:0"); ok {
		t.Error("image recopiée : le son part du même point-clé qu'elle")
	}
	// Depuis le début, il n'y a rien avant.
	if _, ok := argValue(build(0, false), "-copypriorss:a:0"); ok {
		t.Error("une session ouverte au début n'a pas de recherche à corriger")
	}
}
