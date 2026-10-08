package handlers

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"project-player/server/models"
)

// Le contrat entre le serveur et l'app.
//
// Le modèle Go et le modèle Dart d'une même réponse sont écrits à la main, de
// chaque côté. Rien ne les tenait ensemble : renommer une clé ici passait tous
// les tests du serveur, et l'app lisait `null` en silence.
//
// Chaque réponse ci-dessous est écrite, tous champs remplis, dans un fichier de
// `contract/` à la racine du dépôt. Ce test échoue dès que ce que le serveur
// écrirait s'écarte du fichier ; `app/test/api_contract_test.dart` relit les
// mêmes fichiers avec les `fromJson` de l'app. Changer une réponse demande donc
// de régénérer le fichier (ONYX_UPDATE_CONTRACT=1 go test ./handlers -run
// TestAPIContract), et le test Dart dit alors si l'app suit.

const contractDir = "../../contract"

// contractValues fixe les champs qu'un texte quelconque ne peut pas remplir :
// l'app y lit une énumération ou une date.
var contractValues = map[string]string{
	"type":           "episode",
	"media_type":     "episode",
	"release_date":   "2020-01-02",
	"air_date":       "2020-01-02",
	"request_status": "unknown",
	"status":         "Returning Series",
}

var contractTime = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

// fillContract donne à chaque champ une valeur non nulle et stable, pour
// qu'aucun `omitempty` ne cache une clé et qu'un champ ajouté apparaisse de
// lui-même dans le fichier.
//
// Une fiche porte ses versions, qui sont elles-mêmes des fiches : la descente
// s'arrête aux versions d'une version.
func fillContract(v reflect.Value, key string, depth int, counter *int) {
	if depth > 12 {
		return
	}
	if key == "versions" && v.Kind() == reflect.Slice {
		if depth > 6 {
			return
		}
		depth = 7
	}
	switch v.Kind() {
	case reflect.Pointer:
		v.Set(reflect.New(v.Type().Elem()))
		fillContract(v.Elem(), key, depth, counter)
	case reflect.Struct:
		if v.Type() == reflect.TypeOf(time.Time{}) {
			v.Set(reflect.ValueOf(contractTime))
			return
		}
		for i := 0; i < v.NumField(); i++ {
			field := v.Type().Field(i)
			if !field.IsExported() {
				continue
			}
			name, _, _ := strings.Cut(field.Tag.Get("json"), ",")
			if name == "-" {
				continue
			}
			if name == "" {
				name = field.Name
			}
			fillContract(v.Field(i), name, depth+1, counter)
		}
	case reflect.Slice:
		if v.Type().Elem().Kind() == reflect.Interface {
			return
		}
		v.Set(reflect.MakeSlice(v.Type(), 1, 1))
		fillContract(v.Index(0), key, depth+1, counter)
	case reflect.Map:
		v.Set(reflect.MakeMap(v.Type()))
		if v.Type().Key().Kind() == reflect.String {
			element := reflect.New(v.Type().Elem()).Elem()
			fillContract(element, key, depth+1, counter)
			v.SetMapIndex(reflect.ValueOf("key").Convert(v.Type().Key()), element)
		}
	case reflect.String:
		if fixed, ok := contractValues[key]; ok {
			v.SetString(fixed)
		} else {
			v.SetString(key + "-value")
		}
	case reflect.Bool:
		v.SetBool(true)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		*counter++
		v.SetInt(int64(*counter))
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		*counter++
		v.SetUint(uint64(*counter))
	case reflect.Float32, reflect.Float64:
		*counter++
		v.SetFloat(float64(*counter) + 0.5)
	}
}

func filled[T any]() T {
	var value T
	counter := 0
	fillContract(reflect.ValueOf(&value).Elem(), "", 0, &counter)
	return value
}

func TestAPIContract(t *testing.T) {
	tracks := filled[mediaTracksResponse]()
	tracks.Subtitles = []interface{}{map[string]interface{}{
		"index": 2, "codec": "subrip", "language": "fre", "title": "Français", "forced": false,
	}}

	contract := map[string]interface{}{
		"home":               filled[models.HomeResponse](),
		"media_details":      filled[models.MediaDetails](),
		"next_episode":       filled[nextEpisodeResponse](),
		"next_episode_none":  nextEpisodeResponse{},
		"show_resume":        filled[resumeEpisodeResponse](),
		"show_resume_none":   resumeEpisodeResponse{},
		"episode_timestamps": filled[episodeTimestampsResponse](),
		"media_tracks":       tracks,
		"progress":           filled[progressResponse](),
		"progress_revision":  filled[models.ProgressRevision](),
		"scan_status":        filled[scanStatusResponse](),
		"ping":               pingPayload(),
	}

	update := os.Getenv("ONYX_UPDATE_CONTRACT") != ""
	for name, value := range contract {
		var out bytes.Buffer
		encoder := json.NewEncoder(&out)
		encoder.SetEscapeHTML(false)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(value); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		path := filepath.Join(contractDir, name+".json")
		if update {
			if err := os.MkdirAll(contractDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, out.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("%s: %v — générer avec ONYX_UPDATE_CONTRACT=1", name, err)
			continue
		}
		// Un poste Windows peut avoir réécrit les fins de ligne du fichier.
		if got := out.String(); got != strings.ReplaceAll(string(want), "\r\n", "\n") {
			t.Errorf("la réponse %q ne correspond plus à contract/%s.json : l'app lit ce fichier-là.\n"+
				"Si le changement est voulu, régénérer (ONYX_UPDATE_CONTRACT=1 go test ./handlers -run TestAPIContract) "+
				"puis faire passer app/test/api_contract_test.dart.\nObtenu :\n%s", name, name, got)
		}
	}
}

// Garde : une réponse JSON est une struct, pas une map écrite sur place. Une
// map ne dit pas quelles clés la route renvoie, laisse passer une faute de
// frappe dans une clé, et n'a pas sa place dans le contrat ci-dessus.
func TestNoUntypedJSONResponses(t *testing.T) {
	// Des maps qui ne sont pas des réponses : elles lisent ou écrivent le JSON
	// d'un autre programme, dont la forme n'est pas à nous.
	allowed := map[string]string{
		"emby_reconcile.go": "corps d'une requête envoyée à Emby, dans son format",
		"playback_logs.go":  "sortie de ffprobe relue pour le journal, de forme libre",
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		if _, ok := allowed[file]; ok {
			continue
		}
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(data), "\n") {
			code, _, _ := strings.Cut(line, "//")
			if strings.Contains(code, "map[string]interface{}") || strings.Contains(code, "map[string]any") {
				t.Errorf("%s:%d écrit du JSON avec une map — déclarer une struct (voir responses.go)", file, i+1)
			}
		}
	}
}
