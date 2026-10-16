package streaming

import (
	"math"
	"testing"
)

func TestParseCropdetectKeepsTheLastCumulativeLine(t *testing.T) {
	stderr := []byte(`Input #0, matroska,webm, from 'film.mkv':
[Parsed_cropdetect_0 @ 0x55d0] x1:0 x2:1919 y1:200 y2:879 w:1920 h:672 x:0 y:204 pts:0 t:0.000000 limit:0.100000 crop=1920:672:0:204
[Parsed_cropdetect_0 @ 0x55d0] x1:0 x2:1919 y1:138 y2:941 w:1920 h:800 x:0 y:140 pts:24 t:1.001000 limit:0.100000 crop=1920:800:0:140
`)
	got, ok := parseCropdetect(stderr)
	if !ok {
		t.Fatal("parseCropdetect: aucune mesure lue")
	}
	want := cropBounds{x1: 0, x2: 1919, y1: 138, y2: 941}
	if got != want {
		t.Fatalf("parseCropdetect = %+v, want %+v", got, want)
	}
}

func TestParseCropdetectRejectsAnAllBlackFrame(t *testing.T) {
	// Une image entièrement noire laisse les bornes à leur valeur de départ,
	// inversées : ce n'est pas une mesure.
	stderr := []byte(`[Parsed_cropdetect_0 @ 0x1] x1:1919 x2:0 y1:1079 y2:0 w:-1904 h:-1072 x:1912 y:1076 pts:0 t:0.000000 crop=-1904:-1072:1912:1076`)
	if _, ok := parseCropdetect(stderr); ok {
		t.Fatal("une image noire ne doit pas donner de zone utile")
	}
	if _, ok := parseCropdetect([]byte("no crop line")); ok {
		t.Fatal("une sortie sans mesure ne doit pas donner de zone utile")
	}
}

func TestActiveAreaFrom(t *testing.T) {
	scope := cropBounds{x1: 0, x2: 1919, y1: 138, y2: 941}
	tests := []struct {
		name    string
		samples []cropBounds
		want    *ActiveArea
	}{
		{
			name:    "film 2.39 incrusté dans un cadre 16:9",
			samples: []cropBounds{scope, scope, scope},
			want:    &ActiveArea{X: 0, Y: 138.0 / 1080, Width: 1, Height: 804.0 / 1080},
		},
		{
			// Une scène sombre ne voit pas les bords : l'union garde ceux des
			// scènes claires, sans rogner l'image.
			name: "une scène sombre ne réduit pas la zone",
			samples: []cropBounds{
				scope,
				{x1: 300, x2: 1600, y1: 400, y2: 700},
				scope,
			},
			want: &ActiveArea{X: 0, Y: 138.0 / 1080, Width: 1, Height: 804.0 / 1080},
		},
		{
			name: "un 4:3 incrusté entre deux bandes verticales",
			samples: []cropBounds{
				{x1: 240, x2: 1679, y1: 0, y2: 1079},
				{x1: 240, x2: 1679, y1: 0, y2: 1079},
				{x1: 240, x2: 1679, y1: 0, y2: 1079},
			},
			want: &ActiveArea{X: 240.0 / 1920, Y: 0, Width: 1440.0 / 1920, Height: 1},
		},
		{
			name:    "le cadre entier est l'image",
			samples: []cropBounds{{0, 1919, 0, 1079}, {0, 1919, 0, 1079}, {0, 1919, 0, 1079}},
			want:    nil,
		},
		{
			// 1080 lignes dans un cadre qui en porte quelques-unes de plus, ou
			// une ombre au bord : pas une bande.
			name:    "des bandes trop fines ne comptent pas",
			samples: []cropBounds{{2, 1917, 4, 1075}, {2, 1917, 4, 1075}, {2, 1917, 4, 1075}},
			want:    nil,
		},
		{
			name:    "trop peu d'instants lisibles",
			samples: []cropBounds{scope, scope},
			want:    nil,
		},
		{
			name:    "une zone minuscule est une erreur de mesure",
			samples: []cropBounds{{0, 1919, 500, 600}, {0, 1919, 500, 600}, {0, 1919, 500, 600}},
			want:    nil,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := activeAreaFrom(tt.samples, 1920, 1080)
			if (got == nil) != (tt.want == nil) {
				t.Fatalf("activeAreaFrom = %+v, want %+v", got, tt.want)
			}
			if got == nil {
				return
			}
			for _, pair := range [][2]float64{
				{got.X, tt.want.X}, {got.Y, tt.want.Y},
				{got.Width, tt.want.Width}, {got.Height, tt.want.Height},
			} {
				if math.Abs(pair[0]-pair[1]) > 1e-9 {
					t.Fatalf("activeAreaFrom = %+v, want %+v", got, tt.want)
				}
			}
		})
	}
}
