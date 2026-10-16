package streaming

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"time"
)

// ActiveArea est la part de l'image qui n'est pas une bande noire incrustée
// dans le fichier, en fractions du cadre décodé (0 à 1).
//
// Un film 2.39 encodé en 1920×1080 porte ses bandes dans ses pixels : pour un
// lecteur, elles font partie de l'image, et aucun zoom ne les voit. Les
// fractions survivent au transcodage, qui met le cadre à l'échelle sans le
// recadrer, et au rapport des pixels, qui étire le cadre sans le déplacer.
// Voir ADR-0067.
type ActiveArea struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// activeAreaSamples sont les instants analysés, en fraction de la durée. Ni le
// début ni la fin : un générique sur fond noir, ou un logo de studio, n'a pas
// de bord et ferait croire à des bandes partout.
var activeAreaSamples = []float64{0.15, 0.3, 0.45, 0.6, 0.75}

const (
	// activeAreaKeyframes par instant : seules les images clés sont décodées
	// (`-skip_frame nokey`), ce qui garde l'analyse d'un film 4K en secondes et
	// la répartit sur une minute de film plutôt que sur une seconde.
	activeAreaKeyframes = 6
	activeAreaTimeout   = 30 * time.Second

	// En dessous, une « bande » n'est que le remplissage d'un encodeur
	// (1080 lignes dans un cadre de 1088) ou une ombre de bord.
	activeAreaMinBand = 0.01
	// Au-dessus, ce n'est plus une bande mais une erreur de mesure : aucun
	// film ne tient dans moins d'un tiers de son cadre.
	activeAreaMinSide = 0.33
	// Il faut au moins ce nombre d'instants lisibles pour conclure : un film
	// presque entièrement sombre ne dit rien de ses bords.
	activeAreaMinSamples = 3
)

// cropBounds est la zone non noire d'un instant, en pixels, bornes incluses.
type cropBounds struct{ x1, x2, y1, y2 int }

var cropdetectLine = regexp.MustCompile(`x1:(-?\d+) x2:(-?\d+) y1:(-?\d+) y2:(-?\d+)`)

// parseCropdetect lit la dernière mesure d'un passage de cropdetect. Avec
// `reset=0`, chaque ligne cumule les précédentes : la dernière est la zone
// utile de toutes les images vues. Faux quand rien n'était lisible — une image
// entièrement noire donne des bornes inversées.
func parseCropdetect(stderr []byte) (cropBounds, bool) {
	matches := cropdetectLine.FindAllSubmatch(stderr, -1)
	if len(matches) == 0 {
		return cropBounds{}, false
	}
	last := matches[len(matches)-1]
	values := make([]int, 4)
	for i := range values {
		n, err := strconv.Atoi(string(last[i+1]))
		if err != nil {
			return cropBounds{}, false
		}
		values[i] = n
	}
	b := cropBounds{x1: values[0], x2: values[1], y1: values[2], y2: values[3]}
	if b.x2 < b.x1 || b.y2 < b.y1 {
		return cropBounds{}, false
	}
	return b, true
}

// activeAreaFrom réunit les mesures des instants et les ramène en fractions.
//
// L'union, pas l'intersection : une scène sombre ne voit pas les bords de son
// image, et rogner d'après elle couperait l'image des scènes claires. Nil
// quand le cadre entier est utile — pas de bandes — ou que la mesure n'est pas
// crédible.
func activeAreaFrom(samples []cropBounds, width, height int) *ActiveArea {
	if len(samples) < activeAreaMinSamples || width <= 0 || height <= 0 {
		return nil
	}
	union := samples[0]
	for _, s := range samples[1:] {
		union.x1 = min(union.x1, s.x1)
		union.x2 = max(union.x2, s.x2)
		union.y1 = min(union.y1, s.y1)
		union.y2 = max(union.y2, s.y2)
	}
	x, w := snapBand(union.x1, union.x2, width)
	y, h := snapBand(union.y1, union.y2, height)
	if w < activeAreaMinSide || h < activeAreaMinSide {
		return nil
	}
	if x == 0 && y == 0 && w == 1 && h == 1 {
		return nil
	}
	return &ActiveArea{X: x, Y: y, Width: w, Height: h}
}

// snapBand ramène une étendue en pixels [lo, hi] en fractions, en effaçant
// les bandes trop fines pour en être.
func snapBand(lo, hi, size int) (start, extent float64) {
	lo = max(lo, 0)
	hi = min(hi, size-1)
	start = float64(lo) / float64(size)
	end := float64(hi+1) / float64(size)
	if start < activeAreaMinBand {
		start = 0
	}
	if 1-end < activeAreaMinBand {
		end = 1
	}
	return start, end - start
}

// DetectActiveArea mesure les bandes noires incrustées d'un fichier. Nil sans
// erreur : le cadre entier est l'image.
//
// ffmpeg tourne en priorité basse : c'est une tâche de fond, et la lecture de
// quelqu'un passe avant.
func DetectActiveArea(ctx context.Context, path string, duration float64, width, height int) (*ActiveArea, error) {
	if duration <= 0 || width <= 0 || height <= 0 {
		return nil, nil
	}
	var samples []cropBounds
	var lastErr error
	for _, at := range activeAreaSamples {
		bounds, err := cropdetectAt(ctx, path, duration*at)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			lastErr = err
			continue
		}
		if bounds != nil {
			samples = append(samples, *bounds)
		}
	}
	if len(samples) == 0 && lastErr != nil {
		return nil, lastErr
	}
	return activeAreaFrom(samples, width, height), nil
}

func cropdetectAt(ctx context.Context, path string, seconds float64) (*cropBounds, error) {
	ctx, cancel := context.WithTimeout(ctx, activeAreaTimeout)
	defer cancel()
	args := []string{
		"-hide_banner", "-nostats",
		"-skip_frame", "nokey",
		"-ss", strconv.FormatFloat(seconds, 'f', 2, 64),
		"-i", path,
		"-map", "0:v:0",
		"-an", "-sn", "-dn",
		"-threads", "2",
		// limit en fraction : l'échelle suit la profondeur, et le noir d'un
		// HDR 10 bits en plage limitée (64/1023) reste sous le seuil.
		"-vf", "cropdetect=limit=0.1:round=2:reset=0:skip=0",
		"-frames:v", strconv.Itoa(activeAreaKeyframes),
		"-f", "null", "-",
	}
	cmd := exec.CommandContext(ctx, "ffmpeg", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("cropdetect: start: %w", err)
	}
	lowerProcessPriority(cmd.Process.Pid)
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("cropdetect at %.0fs: %w", seconds, err)
	}
	bounds, ok := parseCropdetect(stderr.Bytes())
	if !ok {
		return nil, nil
	}
	return &bounds, nil
}
