package handlers

import (
	"log"
	"net/http"

	"project-player/server/medialang"
	"project-player/server/models"
)

// mediaLanguage est la langue dans laquelle une requête veut ses fiches
// (ADR-0049). Les requêtes SQL continuent de lire medias, dans la langue de
// base ; un handler passe ensuite ce qu'il va répondre par media ou items, qui
// posent par-dessus le titre et le synopsis de la langue demandée.
//
// Poser la traduction après coup, et non dans le SQL, garde intact tout ce qui
// lit le titre de base en chemin : numéro d'épisode retrouvé dans le titre,
// regroupement des doublons d'une série.
type mediaLanguage struct {
	code string
}

func languageOf(r *http.Request) mediaLanguage {
	return mediaLanguage{code: medialang.FromRequest(r)}
}

// baseMediaLanguage sert les appels qui ne lisent de TMDB que des numéros.
func baseMediaLanguage() mediaLanguage {
	return mediaLanguage{code: medialang.Base()}
}

// tmdbLocale est le paramètre `language` des appels TMDB faits pour cette
// requête.
func (l mediaLanguage) tmdbLocale() string {
	return medialang.TMDBLocale(l.code)
}

func (l mediaLanguage) texts(ids []int) map[int]medialang.Text {
	if l.code == medialang.Base() || len(ids) == 0 {
		return nil
	}
	texts, err := medialang.Texts(l.code, ids)
	if err != nil {
		// Sans traduction la fiche reste lisible, dans la langue de base.
		log.Printf("mediaLanguage: %v", err)
		return nil
	}
	return texts
}

func applyMediaText(m *models.Media, texts map[int]medialang.Text) {
	text, ok := texts[m.ID]
	if !ok {
		return
	}
	if text.Title != "" {
		m.Title = text.Title
	}
	if text.Overview != "" {
		m.Overview = text.Overview
	}
}

// media traduit des fiches et leurs versions.
func (l mediaLanguage) media(medias ...*models.Media) {
	var ids []int
	for _, m := range medias {
		ids = append(ids, m.ID)
		for i := range m.Versions {
			ids = append(ids, m.Versions[i].ID)
		}
	}
	texts := l.texts(ids)
	if texts == nil {
		return
	}
	for _, m := range medias {
		applyMediaText(m, texts)
		for i := range m.Versions {
			applyMediaText(&m.Versions[i].Media, texts)
		}
	}
}

// items traduit des éléments de bibliothèque : la fiche, ses versions, et le
// titre de la série qu'un épisode porte avec lui.
func (l mediaLanguage) items(items ...*models.HomeMediaItem) {
	var ids []int
	for _, item := range items {
		ids = append(ids, item.ID)
		if item.ShowID > 0 {
			ids = append(ids, item.ShowID)
		}
		for i := range item.Versions {
			ids = append(ids, item.Versions[i].ID)
		}
	}
	texts := l.texts(ids)
	if texts == nil {
		return
	}
	for _, item := range items {
		// episode_title répète le titre de l'épisode : il suit sa traduction.
		repeatsTitle := item.EpisodeTitle != "" && item.EpisodeTitle == item.Title
		applyMediaText(&item.Media, texts)
		if repeatsTitle {
			item.EpisodeTitle = item.Title
		}
		if show, ok := texts[item.ShowID]; ok && show.Title != "" && item.ShowTitle != "" {
			item.ShowTitle = show.Title
		}
		for i := range item.Versions {
			applyMediaText(&item.Versions[i].Media, texts)
		}
	}
}

// itemList traduit une liste d'éléments de bibliothèque.
func (l mediaLanguage) itemList(items []models.HomeMediaItem) {
	refs := make([]*models.HomeMediaItem, len(items))
	for i := range items {
		refs[i] = &items[i]
	}
	l.items(refs...)
}

// details traduit le socle local d'une fiche détaillée : ce qui reste affiché
// quand TMDB ne répond pas.
func (l mediaLanguage) details(d *models.MediaDetails) {
	ids := []int{d.ID}
	for i := range d.Versions {
		ids = append(ids, d.Versions[i].ID)
	}
	texts := l.texts(ids)
	if texts == nil {
		return
	}
	if text, ok := texts[d.ID]; ok {
		if text.Title != "" {
			d.Title = text.Title
		}
		if text.Overview != "" {
			d.Overview = text.Overview
		}
	}
	for i := range d.Versions {
		applyMediaText(&d.Versions[i].Media, texts)
	}
}

// showTitle traduit le titre d'une série lu à part.
func (l mediaLanguage) showTitle(showID int, base string) string {
	if text, ok := l.texts([]int{showID})[showID]; ok && text.Title != "" {
		return text.Title
	}
	return base
}

// seasonLabel nomme une saison sans nom propre dans la langue demandée.
func (l mediaLanguage) seasonLabel(number int) string {
	return medialang.SeasonLabel(l.code, number)
}
