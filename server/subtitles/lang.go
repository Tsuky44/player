package subtitles

import "strings"

// LanguageLabel maps an ISO-639 code (2 or 3 letters) to a readable French name.
func LanguageLabel(code string) string {
	c := strings.ToLower(strings.TrimSpace(code))
	if c == "" || c == "und" {
		return "Indéterminé"
	}
	names := map[string]string{
		"fr": "Français", "fra": "Français", "fre": "Français",
		"en": "Anglais", "eng": "Anglais",
		"es": "Espagnol", "spa": "Espagnol",
		"de": "Allemand", "ger": "Allemand", "deu": "Allemand",
		"it": "Italien", "ita": "Italien",
		"pt": "Portugais", "por": "Portugais",
		"ja": "Japonais", "jpn": "Japonais",
		"ko": "Coréen", "kor": "Coréen",
		"zh": "Chinois", "chi": "Chinois", "zho": "Chinois",
		"ru": "Russe", "rus": "Russe",
		"ar": "Arabe", "ara": "Arabe",
		"nl": "Néerlandais", "dut": "Néerlandais", "nld": "Néerlandais",
		"pl": "Polonais", "pol": "Polonais",
		"tr": "Turc", "tur": "Turc",
		"hi": "Hindi", "hin": "Hindi",
		"sv": "Suédois", "swe": "Suédois",
		"da": "Danois", "dan": "Danois",
		"fi": "Finnois", "fin": "Finnois",
		"no": "Norvégien", "nor": "Norvégien",
		"cs": "Tchèque", "ces": "Tchèque", "cze": "Tchèque",
	}
	if n, ok := names[c]; ok {
		return n
	}
	return strings.ToUpper(c)
}

// normalizeLang reduces an ffprobe language tag to a short, stable code used both
// as the on-disk filename suffix and the ?lang= query value.
func normalizeLang(code string) string {
	c := strings.ToLower(strings.TrimSpace(code))
	if c == "" {
		return "und"
	}
	threeToTwo := map[string]string{
		"fra": "fr", "fre": "fr",
		"eng": "en",
		"spa": "es",
		"ger": "de", "deu": "de",
		"ita": "it",
		"por": "pt",
		"jpn": "ja",
		"kor": "ko",
		"chi": "zh", "zho": "zh",
		"rus": "ru",
		"ara": "ar",
		"dut": "nl", "nld": "nl",
		"pol": "pl",
		"tur": "tr",
		"hin": "hi",
		"swe": "sv",
		"dan": "da",
		"fin": "fi",
		"nor": "no",
		"ces": "cs", "cze": "cs",
	}
	if two, ok := threeToTwo[c]; ok {
		return two
	}
	return c
}
