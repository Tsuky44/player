/// Picks the transcoding tier that preserves a source's own resolution.
///
/// The web always transcodes — a browser cannot open the containers and audio
/// codecs a private library is made of — so the only question left is which tier
/// to ask for. Answering it from the source rather than defaulting to a fixed
/// one is what keeps the web looking like the app: a 4K file is served in 4K, a
/// 1080p file in 1080p, and nothing is quietly downscaled.
///
/// It also unlocks the cheap path on the server. Asking for the resolution the
/// file already has means no rescaling, which is one of the conditions for
/// repackaging the picture instead of re-encoding it — so an H.264 source costs
/// a few percent of a core rather than a whole one, at its native quality.
library;

/// Tier used when the source height is unknown.
const webFallbackQuality = '1080p';

/// The tier matching [height], the source's pixel height.
///
/// Thresholds sit below each nominal height on purpose: real files are rarely
/// exactly 1080 or 2160. A 2.39:1 film stored without letterboxing is 1920×804,
/// and anamorphic or slightly cropped masters land a few dozen lines short —
/// all of which must still be treated as the tier they belong to rather than
/// demoted to the one below.
String qualityForSourceHeight(int height) {
  if (height <= 0) return webFallbackQuality;
  if (height > 1400) return '2160p';
  if (height > 800) return '1080p';
  if (height > 560) return '720p';
  if (height > 400) return '480p';
  return '360p';
}
