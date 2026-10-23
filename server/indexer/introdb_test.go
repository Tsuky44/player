package indexer

import (
	"encoding/json"
	"testing"
)

// --- TheIntroDB markers -------------------------------------------------------

func seg(startSec, endSec int) IntroDBSegment {
	s := IntroDBSegment{}
	if startSec >= 0 {
		v := startSec * 1000
		s.StartMs = &v
	}
	if endSec >= 0 {
		v := endSec * 1000
		s.EndMs = &v
	}
	return s
}

func TestPickMarkers_IntroAloneWithNullStartIsFromTheBeginning(t *testing.T) {
	m := PickMarkers(&IntroDBResponse{Intro: []IntroDBSegment{seg(-1, 90)}}, 1400)
	if m.IntroStart != 0 || m.IntroEnd != 90 {
		t.Fatalf("intro = [%d-%d], want [0-90]", m.IntroStart, m.IntroEnd)
	}
}

func TestPickMarkers_AdjacentRecapAndIntroFormOneWindow(t *testing.T) {
	m := PickMarkers(&IntroDBResponse{
		Recap: []IntroDBSegment{seg(0, 60)},
		Intro: []IntroDBSegment{seg(62, 150)},
	}, 1400)
	if m.IntroStart != 0 || m.IntroEnd != 150 {
		t.Fatalf("window = [%d-%d], want [0-150]", m.IntroStart, m.IntroEnd)
	}
}

func TestPickMarkers_RecapFarBeforeTheIntroIsNotMerged(t *testing.T) {
	// Récap en pré-générique, intro à 5 minutes : fusionner ferait sauter
	// 5 minutes d'épisode.
	m := PickMarkers(&IntroDBResponse{
		Recap: []IntroDBSegment{seg(0, 60)},
		Intro: []IntroDBSegment{seg(300, 390)},
	}, 1400)
	if m.IntroStart != 300 || m.IntroEnd != 390 {
		t.Fatalf("intro = [%d-%d], want [300-390]", m.IntroStart, m.IntroEnd)
	}
}

func TestPickMarkers_ImplausibleIntroGivesWayToAGoodOne(t *testing.T) {
	m := PickMarkers(&IntroDBResponse{Intro: []IntroDBSegment{seg(0, 900), seg(40, 120)}}, 1400)
	if m.IntroStart != 40 || m.IntroEnd != 120 {
		t.Fatalf("intro = [%d-%d], want [40-120]", m.IntroStart, m.IntroEnd)
	}
}

func TestPickMarkers_CreditsTakeTheEarliestInTheSecondHalf(t *testing.T) {
	m := PickMarkers(&IntroDBResponse{Credits: []IntroDBSegment{
		seg(600, 700), // au milieu : ni un générique de fin, ni à garder
		seg(1300, 1370),
		seg(1390, -1), // scène post-générique
	}}, 1420)
	if m.OutroStart != 1300 || m.OutroEnd != 1370 {
		t.Fatalf("outro = [%d-%d], want [1300-1370]", m.OutroStart, m.OutroEnd)
	}
}

func TestPickMarkers_CreditsWithoutEndRunToTheEndOfTheFile(t *testing.T) {
	m := PickMarkers(&IntroDBResponse{Credits: []IntroDBSegment{seg(3431, -1)}}, 3500)
	if m.OutroStart != 3431 || m.OutroEnd != 3500 {
		t.Fatalf("outro = [%d-%d], want [3431-3500]", m.OutroStart, m.OutroEnd)
	}
}

func TestPickMarkers_NothingUsableGivesNothing(t *testing.T) {
	if m := PickMarkers(nil, 1400); m.hasIntro() || m.hasOutro() {
		t.Fatalf("nil response gave %+v", m)
	}
	m := PickMarkers(&IntroDBResponse{Intro: []IntroDBSegment{seg(10, -1)}}, 1400)
	if m.hasIntro() {
		t.Fatalf("an intro without an end gave %+v", m)
	}
}

func TestFillMissingMarkers_NeverOverwritesWhatIsKnown(t *testing.T) {
	current := EpisodeMarkers{OutroStart: 1300, OutroEnd: 1400}
	got := FillMissingMarkers(current, EpisodeMarkers{IntroStart: 30, IntroEnd: 100, OutroStart: 1200, OutroEnd: 1400})
	want := EpisodeMarkers{IntroStart: 30, IntroEnd: 100, OutroStart: 1300, OutroEnd: 1400}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestFetchSegmentsFromIntroDB_ReadsTheV4Shape(t *testing.T) {
	var body IntroDBResponse
	raw := `{"tvdb_id":71663,"type":"tv","intro":[{"start_ms":null,"end_ms":23000}],"credits":[{"start_ms":5801777,"end_ms":null}]}`
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatal(err)
	}
	m := PickMarkers(&body, 6000)
	if m.IntroStart != 0 || m.IntroEnd != 23 || m.OutroStart != 5801 || m.OutroEnd != 6000 {
		t.Fatalf("markers = %+v", m)
	}
}
