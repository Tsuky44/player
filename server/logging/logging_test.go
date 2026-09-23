package logging

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
)

func TestJSONFormatWritesOneObjectPerEntry(t *testing.T) {
	var out bytes.Buffer
	slog.New(newHandler(&out, "json", "")).Info("serveur prêt", "port", 8080)

	var entry map[string]any
	if err := json.Unmarshal(out.Bytes(), &entry); err != nil {
		t.Fatalf("not a JSON line: %q", out.String())
	}
	if entry["msg"] != "serveur prêt" || entry["port"] != float64(8080) {
		t.Errorf("entry %v", entry)
	}
}

func TestLevelFiltersWhatIsWritten(t *testing.T) {
	var out bytes.Buffer
	logger := slog.New(newHandler(&out, "", "warn"))
	logger.Info("bavard")
	logger.Warn("important")
	if strings.Contains(out.String(), "bavard") || !strings.Contains(out.String(), "important") {
		t.Errorf("LOG_LEVEL=warn wrote %q", out.String())
	}
}
