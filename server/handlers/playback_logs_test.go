package handlers

import (
	"strings"
	"testing"
	"time"
)

func logLines(n int, level string) []PlaybackLogLine {
	out := make([]PlaybackLogLine, n)
	for i := range out {
		out[i] = PlaybackLogLine{
			At:      time.Date(2026, 9, 18, 12, 0, i%60, 0, time.UTC),
			Level:   level,
			Message: "ligne " + strings.Repeat("x", 4),
		}
	}
	return out
}

func TestNormalizePlaybackLogsKeepsTheEnd(t *testing.T) {
	in := logLines(playbackLogMaxLines+40, "info")
	// Marque la toute dernière : c'est celle qui doit survivre.
	in[len(in)-1].Message = "la dernière"

	out, hasError := normalizePlaybackLogLines(in)

	if len(out) != playbackLogMaxLines {
		t.Fatalf("gardé %d lignes, attendu %d", len(out), playbackLogMaxLines)
	}
	if out[len(out)-1].Message != "la dernière" {
		t.Errorf("la dernière ligne a été écartée : %q", out[len(out)-1].Message)
	}
	if hasError {
		t.Error("aucune ligne n'était une erreur")
	}
}

func TestNormalizePlaybackLogsReadsTheErrorFromTheLines(t *testing.T) {
	in := logLines(3, "info")
	in[1].Level = "error"

	out, hasError := normalizePlaybackLogLines(in)

	if !hasError {
		t.Fatal("une ligne d'erreur devait être vue")
	}
	if out[1].Level != "error" || out[0].Level != "info" {
		t.Errorf("les niveaux ont bougé : %q puis %q", out[0].Level, out[1].Level)
	}
}

func TestNormalizePlaybackLogsNormalisesUnknownLevels(t *testing.T) {
	// Un client qui inventerait un niveau ne doit pas pouvoir écrire dans la
	// base une valeur que l'interface ne sait pas rendre.
	out, hasError := normalizePlaybackLogLines([]PlaybackLogLine{
		{Level: "ERROR", Message: "criant"},
		{Level: "warn", Message: "tiède"},
	})

	if hasError {
		t.Error("« ERROR » n'est pas « error » : rien ne doit être promu")
	}
	for _, line := range out {
		if line.Level != "info" {
			t.Errorf("niveau %q laissé passer", line.Level)
		}
	}
}

func TestNormalizePlaybackLogsDropsBlankLines(t *testing.T) {
	out, _ := normalizePlaybackLogLines([]PlaybackLogLine{
		{Level: "info", Message: "   "},
		{Level: "info", Message: "  utile  "},
		{Level: "info", Message: ""},
	})

	if len(out) != 1 || out[0].Message != "utile" {
		t.Fatalf("attendu une seule ligne rognée, reçu %#v", out)
	}
}

func TestNormalizePlaybackLogsCutsOnCharacterBoundaries(t *testing.T) {
	// Des caractères de plusieurs octets, en nombre suffisant pour dépasser le
	// plafond : couper sur un octet produirait de l'UTF-8 invalide.
	long := strings.Repeat("é", playbackLogMaxLineLength+50)

	out, _ := normalizePlaybackLogLines([]PlaybackLogLine{{Message: long}})

	if len(out) != 1 {
		t.Fatalf("attendu une ligne, reçu %d", len(out))
	}
	got := out[0].Message
	if !strings.HasSuffix(got, "…") {
		t.Error("la troncature n'est pas marquée")
	}
	if n := len([]rune(strings.TrimSuffix(got, "…"))); n != playbackLogMaxLineLength {
		t.Errorf("tronqué à %d caractères, attendu %d", n, playbackLogMaxLineLength)
	}
	if !isValidUTF8(got) {
		t.Error("la coupe a cassé un caractère")
	}
}

func TestNormalizePlaybackLogsHoldsTheByteCeiling(t *testing.T) {
	// Des lignes longues mais moins nombreuses que le plafond de lignes : c'est
	// le plafond d'octets qui doit mordre.
	fat := PlaybackLogLine{Message: strings.Repeat("x", playbackLogMaxLineLength)}
	in := make([]PlaybackLogLine, 200)
	for i := range in {
		in[i] = fat
	}

	out, _ := normalizePlaybackLogLines(in)

	if len(out) >= 200 {
		t.Fatalf("le plafond d'octets n'a pas mordu : %d lignes gardées", len(out))
	}
	size := 0
	for _, line := range out {
		size += len(line.Message) + 64
	}
	if size > playbackLogMaxBytes {
		t.Errorf("stocké %d octets, plafond %d", size, playbackLogMaxBytes)
	}
}

func isValidUTF8(s string) bool {
	for _, r := range s {
		if r == '\uFFFD' {
			return false
		}
	}
	return true
}
