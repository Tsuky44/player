package mediahub

import (
	"sort"
	"strings"
)

// Lot est une demande telle que l'app la montre : un film, ou les saisons
// d'une série demandées par un même compte. MediaHub écrit une ligne par
// saison ; huit lignes pour une série feraient huit cartes dans « Mes
// demandes ». Le format est celui d'Onyx, épinglé par contract/requests_mine.json.
type Lot struct {
	// RequestIDs sont les lignes MediaHub du lot, à modérer ensemble. Vide
	// avec OnyxHub, qui n'expose pas ses identifiants.
	RequestIDs     []int          `json:"requestIds"`
	MediaType      string         `json:"mediaType"`
	TMDBID         int            `json:"tmdbId"`
	Title          string         `json:"title"`
	PosterPath     *string        `json:"posterPath"`
	Seasons        []int          `json:"seasons"`
	Status         string         `json:"status"`
	SeasonStatuses []SeasonStatus `json:"seasonStatuses"`
	RequestedAt    string         `json:"requestedAt"`
	UpdatedAt      string         `json:"updatedAt,omitempty"`
	// Progress : 0 à 100 pendant un téléchargement. MediaHub v1 ne le donne
	// pas encore (toujours null), OnyxHub le donnait.
	Progress *float64 `json:"progress"`
	Waiting  *Waiting `json:"waiting,omitempty"`
	// Note est le motif d'un refus.
	Note      *string `json:"note,omitempty"`
	Requester string  `json:"requester,omitempty"`
}

// SeasonStatus est l'état de la demande d'une saison.
type SeasonStatus struct {
	SeasonNumber int    `json:"seasonNumber"`
	Status       string `json:"status"`
}

// statusRank ordonne l'avancement d'une demande. declined est à part.
var statusRank = map[string]int{
	"pending":    1,
	"approved":   2,
	"processing": 3,
	"partial":    4,
	"available":  5,
}

// lotStatus résume les statuts des lignes d'un lot :
//   - tout disponible : available ; quelque chose de disponible : partial ;
//   - sinon le moins avancé des statuts non refusés, car le lot n'avance pas
//     plus vite que sa saison la plus en retard ;
//   - tout refusé : declined.
func lotStatus(statuses []string) string {
	available, partial, lowest := 0, false, ""
	for _, status := range statuses {
		switch status {
		case "available":
			available++
		case "partial":
			partial = true
		case "declined":
			continue
		}
		if rank, ok := statusRank[status]; ok && (lowest == "" || rank < statusRank[lowest]) {
			lowest = status
		}
	}
	switch {
	case len(statuses) > 0 && available == len(statuses):
		return "available"
	case available > 0 || partial:
		return "partial"
	case lowest != "":
		return lowest
	case len(statuses) > 0:
		return "declined"
	default:
		return "pending"
	}
}

// GroupLots regroupe les lignes en lots, dans l'ordre des lignes (les plus
// récentes d'abord) : une série demandée saison par saison, par un même
// compte, ne fait qu'un lot.
func GroupLots(rows []Request) []Lot {
	type pending struct {
		lot      Lot
		statuses []string
	}
	var order []string
	byKey := map[string]*pending{}
	for _, row := range rows {
		key := AvailabilityKey(row.MediaType, row.TMDBID) + ":" + strings.ToLower(row.Requester)
		group, ok := byKey[key]
		if !ok {
			group = &pending{lot: Lot{
				RequestIDs:     []int{},
				MediaType:      row.MediaType,
				TMDBID:         row.TMDBID,
				Title:          row.Title,
				PosterPath:     row.PosterPath,
				Seasons:        []int{},
				SeasonStatuses: []SeasonStatus{},
				RequestedAt:    row.RequestedAt,
				UpdatedAt:      row.UpdatedAt,
				Requester:      row.Requester,
			}}
			byKey[key] = group
			order = append(order, key)
		}
		lot := &group.lot
		lot.RequestIDs = append(lot.RequestIDs, row.ID)
		group.statuses = append(group.statuses, row.Status)
		if row.UpdatedAt > lot.UpdatedAt {
			lot.UpdatedAt = row.UpdatedAt
		}
		if lot.PosterPath == nil {
			lot.PosterPath = row.PosterPath
		}
		if lot.Progress == nil {
			lot.Progress = row.Progress
		}
		if lot.Waiting == nil {
			lot.Waiting = row.Waiting
		}
		if lot.Note == nil && row.Status == "declined" {
			lot.Note = row.Note
		}
		for _, season := range row.Seasons {
			lot.Seasons = append(lot.Seasons, season)
			lot.SeasonStatuses = append(lot.SeasonStatuses, SeasonStatus{SeasonNumber: season, Status: row.Status})
		}
	}

	lots := make([]Lot, 0, len(order))
	for _, key := range order {
		group := byKey[key]
		lot := group.lot
		lot.Status = lotStatus(group.statuses)
		sort.Ints(lot.Seasons)
		sort.Slice(lot.SeasonStatuses, func(i, j int) bool {
			return lot.SeasonStatuses[i].SeasonNumber < lot.SeasonStatuses[j].SeasonNumber
		})
		// Un lot disponible n'attend plus rien : une raison d'attente d'une
		// ligne plus ancienne ne doit pas s'afficher sous « Disponible ».
		if lot.Status == "available" || lot.Status == "partial" {
			lot.Waiting = nil
		}
		lots = append(lots, lot)
	}
	return lots
}

// normalizeLegacyLots complète les lots lus chez OnyxHub, qui en écrivait
// déjà un par demande, pour qu'ils aient la forme d'Onyx.
func normalizeLegacyLots(lots []Lot) []Lot {
	for i := range lots {
		if lots[i].RequestIDs == nil {
			lots[i].RequestIDs = []int{}
		}
		if lots[i].Seasons == nil {
			lots[i].Seasons = []int{}
		}
		if lots[i].SeasonStatuses == nil {
			lots[i].SeasonStatuses = []SeasonStatus{}
		}
		if lots[i].Status == "" {
			lots[i].Status = "pending"
		}
	}
	return lots
}
