/// Known release source/quality tokens, longest-first so e.g. "WEB-DL"
/// isn't shadowed by a shorter partial match.
const _kReleaseSourceTokens = [
  'WEB-DL',
  'WEBDL',
  'WEBRip',
  'BluRay',
  'BDRip',
  'REMUX',
  'DVDRip',
  'HDTV',
];

final _releaseTagPattern = RegExp(
  '(${_kReleaseSourceTokens.join('|')}).*\$',
  caseSensitive: false,
);

/// Extracts a human-readable release tag (e.g. "WEBDL-2160p Proper") from a
/// media file path, for display alongside episode info — best-effort only,
/// scene/P2P filenames aren't a fixed format. Returns null when no known
/// source/quality token is found.
String? releaseTagFromFilePath(String? filePath) {
  if (filePath == null || filePath.isEmpty) return null;

  final fileName = filePath.split(RegExp(r'[\\/]')).last;
  final stem = fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;
  final readable = stem.replaceAll(RegExp(r'[._]'), ' ').trim();

  final match = _releaseTagPattern.firstMatch(readable);
  if (match == null) return null;

  final tag = match.group(0)!.trim();
  return tag.isEmpty ? null : tag;
}

/// Composes an Emby-style episode line, e.g.
/// "S2:E1 - Silo - S02E01 - The Engineer WEBDL-2160p Proper", from a season/
/// episode code, a title, and the release tag parsed from [filePath].
String composeEpisodeInfoLine({
  String? seasonEpisodeCode,
  required String title,
  String? filePath,
}) {
  final parts = <String>[
    if (seasonEpisodeCode != null && seasonEpisodeCode.isNotEmpty)
      seasonEpisodeCode,
    title,
  ];
  final tag = releaseTagFromFilePath(filePath);
  final line = parts.join(' - ');
  return tag == null ? line : '$line $tag';
}
