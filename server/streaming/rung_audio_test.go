package streaming

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// L'étiquette d'un barreau compte le son au débit du préréglage. Mesuré sur un
// film en E-AC-3 7.1 à 1 Mbit/s, recopié à chaque barreau : « 360p ·
// 420 kbit/s » en envoyait 1,4, et la qualité automatique descendait jusqu'en
// bas d'une ligne à 5 Mbit/s (ADR-0056).
func TestPlanAudio_ARungNeverCarriesASoundHeavierThanItPromises(t *testing.T) {
	heavy := AudioStreamInfo{Codec: "eac3", Channels: 8, BitRate: 1_024_000}
	probe := probeWith(3840, 2160, 24, heavy)
	encoded := VideoPlan{}

	plan := func(quality string) AudioPlan {
		return PlanAudioWithin(probe, 0, surroundCaps(), presetFor(quality), AudioBudget(quality, encoded))
	}

	if p := plan("360p-420k"); p.Copy || p.Channels != 2 || p.Bitrate != "64k" {
		t.Errorf("360p-420k : attendu une stéréo à 64k, obtenu %+v", p)
	}
	if p := plan("1080p-2m"); p.Copy || p.Channels != 2 {
		t.Errorf("1080p-2m : 1 Mbit/s de son en ferait un barreau à 3, obtenu %+v", p)
	}
	// Là où un 5.1 réencodé tient dans le barreau, il est gardé.
	if p := plan("720p"); p.Copy || p.Codec != "eac3" || p.Channels != 6 {
		t.Errorf("720p : attendu un E-AC-3 5.1 réencodé, obtenu %+v", p)
	}
	// Et là où la piste ne change rien au débit, elle passe telle quelle.
	if p := plan("1080p-10m"); !p.Copy {
		t.Errorf("1080p-10m : 1 Mbit/s sur 10 se recopie, obtenu %+v", p)
	}
}

func TestAudioBudget_OnlyBoundsAnEncodedPicture(t *testing.T) {
	if got := AudioBudget("1080p", VideoPlan{Copy: true}); got != 0 {
		t.Errorf("image recopiée : la session envoie le fichier, son compris ; budget %d", got)
	}
	// 128k de préréglage, plus un dixième de 2,128 Mbit/s.
	if got := AudioBudget("1080p-2m", VideoPlan{}); got != 340_800 {
		t.Errorf("1080p-2m : budget %d, attendu 340800", got)
	}
}

// Matroska n'annonce presque jamais le débit d'une piste : le codec en tient
// lieu, et ce qui ne compresse pas ne passe jamais pour léger.
func TestAudioWeight_GuessesWhatTheContainerDoesNotSay(t *testing.T) {
	budget := AudioBudget("1080p-4m", VideoPlan{})
	for _, c := range []struct {
		track AudioStreamInfo
		copy  bool
	}{
		{AudioStreamInfo{Codec: "aac", Channels: 2}, true},
		{AudioStreamInfo{Codec: "eac3", Channels: 8}, false},
		{AudioStreamInfo{Codec: "truehd", Channels: 8}, false},
		{AudioStreamInfo{Codec: "eac3", Channels: 6, BitRate: 384_000}, true},
	} {
		caps := surroundCaps()
		caps.AudioCodecs["truehd"] = true
		got := PlanAudioWithin(probeWith(1920, 1080, 24, c.track), 0, caps, presetFor("1080p-4m"), budget)
		if got.Copy != c.copy {
			t.Errorf("%s %d canaux à %d bit/s : copie=%v, attendu %v",
				c.track.Codec, c.track.Channels, c.track.BitRate, got.Copy, c.copy)
		}
	}
}

func healthSession(t *testing.T, produced int) *TranscodeSession {
	t.Helper()
	dir := t.TempDir()
	for i := 0; i < produced; i++ {
		name := filepath.Join(dir, fmt.Sprintf("stream_0_%03d.m4s", i))
		if err := os.WriteFile(name, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return &TranscodeSession{ID: "s", TmpDir: dir, SegmentExt: ".m4s"}
}

// Un tampon qui fond accuse la ligne ou l'encodeur. Ce qui les distingue :
// quand la ligne est en cause, l'encodeur a de l'avance sur le lecteur.
func TestHealth_TellsAnEncoderThatKeepsUpFromOneThatIsWaitedOn(t *testing.T) {
	start := time.Now()

	ahead := healthSession(t, 20)
	ahead.startedAt = start
	ahead.NoteSegment(3)
	got := ahead.Health(start.Add(10 * time.Second))
	if got.AheadSeconds != 32 {
		t.Errorf("16 segments d'avance : %d s, attendu 32", got.AheadSeconds)
	}
	if got.Speed != 4 {
		t.Errorf("40 s produites en 10 s : vitesse %.2f, attendu 4", got.Speed)
	}

	behind := healthSession(t, 6)
	behind.startedAt = start
	behind.NoteSegment(6)
	got = behind.Health(start.Add(20 * time.Second))
	if got.AheadSeconds != 0 {
		t.Errorf("le lecteur attend le segment suivant : avance %d, attendu 0", got.AheadSeconds)
	}
	if got.Speed >= 1 {
		t.Errorf("12 s produites en 20 s : vitesse %.2f, attendu sous 1", got.Speed)
	}
}

// Le bridage arrête l'encodeur dès qu'il a assez d'avance : après, il ne
// tourne plus que par à-coups, et sa vitesse est celle qu'il avait jusque-là.
func TestHealth_KeepsTheSpeedTheEncoderHadBeforeTheThrottleHeldIt(t *testing.T) {
	start := time.Now()
	s := healthSession(t, 20)
	s.startedAt = start
	s.burstSpeed = 4

	if got := s.Health(start.Add(100 * time.Second)).Speed; got != 4 {
		t.Errorf("vitesse %.2f cent secondes plus tard, attendu les 4 du départ", got)
	}
	// Trop tôt pour dire quoi que ce soit.
	fresh := healthSession(t, 1)
	fresh.startedAt = start
	if got := fresh.Health(start.Add(time.Second)).Speed; got != 0 {
		t.Errorf("une seconde de marche ne mesure rien : vitesse %.2f", got)
	}
}
