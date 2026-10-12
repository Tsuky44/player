package indexer

import (
	"path/filepath"
	"reflect"
	"testing"

	"project-player/server/database"
	"project-player/server/streaming"
)

// Les mêmes cas que PlaybackPreferencesStorage.normalizeLangCode côté app
// (app/test/audio_language_gap_test.dart) : le code qu'un compte retient pour
// une série doit retrouver les langues que le serveur inscrit (ADR-0057).
func TestAudioLangCodeMatchesTheAppRule(t *testing.T) {
	cases := map[string]string{
		"fre": "fr", "fra": "fr", "FR": "fr", "French": "fr", "fr-FR": "fr",
		"jpn": "ja", "ja": "ja", "eng": "en", "ger": "de", "deu": "de",
		"chi": "zh", "zho": "zh", "kor": "ko", "pol": "po",
		"": "", "und": "", " ": "", "auto": "", "no": "",
	}
	for tag, want := range cases {
		if got := AudioLangCode(tag); got != want {
			t.Errorf("AudioLangCode(%q) = %q, attendu %q", tag, got, want)
		}
	}
}

func TestAudioLanguagesPutTheDefaultTrackFirst(t *testing.T) {
	probe := &streaming.ProbeResult{Audio: []streaming.AudioStreamInfo{
		{Language: "jpn"},
		{Language: "fre", Default: true},
		{Language: "fra"},
		{Language: ""},
	}}
	if got, want := audioLanguagesOf(probe), []string{"fr", "ja"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("audioLanguagesOf = %v, attendu %v", got, want)
	}
}

func setupAudioLangDB(t *testing.T) {
	t.Helper()
	if _, err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { database.DB.Close() })
}

func insertProbedEpisode(t *testing.T, title string, probe *streaming.ProbeResult) int {
	t.Helper()
	tracks := ""
	if probe != nil {
		var err error
		if tracks, err = streaming.MarshalProbeResult(probe); err != nil {
			t.Fatalf("marshal probe: %v", err)
		}
	}
	res, err := database.DB.Exec(`
		INSERT INTO medias (type, title, file_path, tracks_json, created_at)
		VALUES ('episode', ?, ?, ?, '2020-03-04 05:06:07')`, title, "/"+title+".mkv", tracks)
	if err != nil {
		t.Fatalf("insert episode %q: %v", title, err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func audioLangRows(t *testing.T, mediaID int) map[string]string {
	t.Helper()
	rows, err := database.DB.Query(
		`SELECT lang, CAST(first_seen_at AS TEXT) FROM media_audio_langs WHERE media_id = ?`, mediaID)
	if err != nil {
		t.Fatalf("read audio langs: %v", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var lang, seenAt string
		if err := rows.Scan(&lang, &seenAt); err != nil {
			t.Fatalf("scan audio lang: %v", err)
		}
		out[lang] = seenAt
	}
	return out
}

func probeSpeaking(langs ...string) *streaming.ProbeResult {
	probe := &streaming.ProbeResult{}
	for _, lang := range langs {
		probe.Audio = append(probe.Audio, streaming.AudioStreamInfo{Language: lang})
	}
	return probe
}

// Une langue déjà connue garde sa date ; celle qui apparaît est datée du
// sondage qui la découvre ; celle qui a quitté le fichier est retirée.
func TestRecordAudioLanguagesDatesOnlyWhatAppears(t *testing.T) {
	setupAudioLangDB(t)
	id := insertProbedEpisode(t, "ep", nil)

	if err := recordAudioLanguages(id, probeSpeaking("jpn", "eng"), true); err != nil {
		t.Fatalf("record: %v", err)
	}
	before := audioLangRows(t, id)
	if len(before) != 2 || before["ja"] == "" || before["en"] == "" {
		t.Fatalf("premier sondage : %v", before)
	}

	if err := recordAudioLanguages(id, probeSpeaking("jpn", "fre"), false); err != nil {
		t.Fatalf("record: %v", err)
	}
	after := audioLangRows(t, id)
	if _, gone := after["en"]; gone || len(after) != 2 {
		t.Fatalf("la langue disparue doit être retirée : %v", after)
	}
	if after["ja"] != before["ja"] {
		t.Fatalf("la langue déjà connue a changé de date : %q puis %q", before["ja"], after["ja"])
	}
	if after["fr"] == before["ja"] {
		t.Fatalf("la langue apparue doit être datée du nouveau sondage : %v", after)
	}
}

// Ce que la bibliothèque portait avant le registre est daté de l'arrivée du
// fichier — pas d'aujourd'hui, sinon tout serait une nouveauté — et le
// rattrapage ne trouve plus rien à faire une fois passé.
func TestBackfillAudioLanguagesDatesFromTheLibrary(t *testing.T) {
	setupAudioLangDB(t)
	dubbed := insertProbedEpisode(t, "dubbed", probeSpeaking("jpn", "fre"))
	untagged := insertProbedEpisode(t, "untagged", probeSpeaking(""))
	unprobed := insertProbedEpisode(t, "unprobed", nil)

	done, err := backfillAudioLanguages()
	if err != nil || done != 2 {
		t.Fatalf("backfill : %d média(s), err %v ; attendu 2", done, err)
	}

	rows := audioLangRows(t, dubbed)
	if len(rows) != 2 {
		t.Fatalf("langues de l'épisode doublé : %v", rows)
	}
	for lang, seenAt := range rows {
		if seenAt[:10] != "2020-03-04" {
			t.Fatalf("%s daté de %q, attendu l'arrivée du fichier", lang, seenAt)
		}
	}
	if got := audioLangRows(t, untagged); len(got) != 1 || got[UndeterminedAudioLang] == "" {
		t.Fatalf("un fichier sans langue déclarée garde une ligne « %s » : %v", UndeterminedAudioLang, got)
	}
	if got := audioLangRows(t, unprobed); len(got) != 0 {
		t.Fatalf("un fichier jamais sondé n'a rien à inscrire : %v", got)
	}

	if again, err := backfillAudioLanguages(); err != nil || again != 0 {
		t.Fatalf("second passage : %d média(s), err %v ; attendu 0", again, err)
	}
}
