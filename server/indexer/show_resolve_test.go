package indexer

import "testing"

func TestResolveShowTitleFromPath_PerEpisodeFolders(t *testing.T) {
	tests := []struct {
		name     string
		parts    []string
		fileName string
		want     string
	}{
		{
			name:     "stable parent folder",
			parts:    []string{"Mercredi", "Mercredi S01E01", "Mercredi S01E01.mkv"},
			fileName: "Mercredi S01E01.mkv",
			want:     "Mercredi",
		},
		{
			name:     "only per-episode folder",
			parts:    []string{"Mercredi S01E01", "Mercredi S01E01.mkv"},
			fileName: "Mercredi S01E01.mkv",
			want:     "Mercredi",
		},
		{
			name:     "english folder name",
			parts:    []string{"Wednesday S01E02", "Wednesday S01E02.mkv"},
			fileName: "Wednesday S01E02.mkv",
			want:     "Wednesday",
		},
		{
			name:     "release folder with dots",
			parts:    []string{"Mercredi.S01E03.1080p.WEB-DL", "Mercredi.S01E03.1080p.WEB-DL.mkv"},
			fileName: "Mercredi.S01E03.1080p.WEB-DL.mkv",
			want:     "Mercredi",
		},
		{
			name:     "classic season layout",
			parts:    []string{"Breaking Bad", "Season 1", "S01E01.mkv"},
			fileName: "S01E01.mkv",
			want:     "Breaking Bad",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolveShowTitleFromPath(tt.parts, tt.fileName)
			if got != tt.want {
				t.Fatalf("resolveShowTitleFromPath() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestResolveShowTMDBSearchKeyFromPath_PreservesYear(t *testing.T) {
	key := resolveShowTMDBSearchKeyFromPath(
		[]string{"Mercredi.2022", "Saison 1", "Mercredi.2022.S01E01.mkv"},
		"Mercredi.2022.S01E01.mkv",
	)
	if key != "Mercredi.2022" {
		t.Fatalf("search key = %q, want %q", key, "Mercredi.2022")
	}
}

func TestLooksLikeEpisodeReleaseFolder(t *testing.T) {
	if !looksLikeEpisodeReleaseFolder("Mercredi S01E01") {
		t.Fatal("expected episode folder detection")
	}
	if looksLikeEpisodeReleaseFolder("Mercredi") {
		t.Fatal("did not expect plain show folder to match")
	}
}
