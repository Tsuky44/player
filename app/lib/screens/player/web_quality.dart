/// Picks the transcoding tier a browser should ask for.
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
///
/// That last paragraph is the whole reason for the second ceiling below. When
/// repackaging is impossible — an HEVC source, which is most 4K in practice —
/// asking for 4K buys no cheap path, and the server spends a full libx264 encode
/// of 8 megapixels per frame on pixels the window cannot show. On the CPU-only
/// production box that was 3 to 6 seconds before the first frame appeared. So
/// the surface the video is painted on caps the request too, and the lower of
/// the two ceilings wins.
library;

/// Tier used when the source height is unknown.
const webFallbackQuality = '1080p';

/// The tiers the server offers, smallest first. Order is what "the lower of the
/// two ceilings" means.
const _tiers = <String>['360p', '480p', '720p', '1080p', '2160p'];

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

/// The tier to ask for when starting a web session on its own.
///
/// [viewportHeight] is the surface height in REAL pixels; 0 means unknown, which
/// applies no ceiling. Only the automatic first choice goes through here — an
/// explicit pick from the quality menu is the user overruling all of this and
/// must be honoured as asked.
String webQualityFor({
  required int sourceHeight,
  required int viewportHeight,
  required String sourceCodec,
}) {
  final native = qualityForSourceHeight(sourceHeight);

  // A source the server can repackage is asked for at its native resolution
  // whatever the window size, because scaling is precisely what would forbid the
  // repackaging: capping a 4K H.264 file to 1080p would trade a copy that costs
  // the server nothing and starts instantly for a full 4K→1080p encode. The
  // fastest start for those files is the biggest tier, not the smallest.
  if (_canRepackage(sourceCodec)) return native;

  final surface = _tierForSurfaceHeight(viewportHeight);
  return _tiers.indexOf(surface) < _tiers.indexOf(native) ? surface : native;
}

/// Smallest tier that can still fill a surface [height] real pixels tall.
///
/// Compared against the surface rather than the source, so unlike
/// [qualityForSourceHeight] there is no letterboxing allowance to make: a window
/// is exactly as tall as it is, and a video fitted into it is never taller. The
/// comparison is deliberately generous in that direction — a scope film in a
/// 1080-tall window only paints 800 or so rows, and asking for 1080p anyway
/// costs little and survives the user resizing.
String _tierForSurfaceHeight(int height) {
  if (height <= 0) return _tiers.last; // unknown — do not cap
  if (height <= 360) return '360p';
  if (height <= 480) return '480p';
  if (height <= 720) return '720p';
  if (height <= 1080) return '1080p';
  return '2160p';
}

/// Whether the server stands a chance of repackaging this codec instead of
/// re-encoding it.
///
/// Mirrors the codec gate in the server's CanCopyVideo, and deliberately only
/// that gate: the server also refuses on pixel format (10-bit, 4:2:2) and on
/// source bitrate, neither of which is in the track list this side reads. So the
/// answer is optimistic — a 4K H.264 file the server ends up re-encoding anyway
/// is asked for at 4K. That is the behaviour this ceiling replaced, so being
/// wrong here is never worse than not having asked.
bool _canRepackage(String codec) {
  switch (codec.toLowerCase()) {
    case 'h264':
    case 'avc1':
      return true;
    default:
      return false;
  }
}
