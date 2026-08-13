/// An installable client app published by the server on /api/downloads.
///
/// The artifacts are baked into the server image at release time, so the set
/// available depends on which machines have published: a Mac can build the DMG
/// and the APK, a Windows machine the EXE and the APK. Platforms nobody has
/// published yet are simply absent from the list.
class AppDownload {
  /// `windows`, `windows-portable`, `macos` or `android`.
  final String platform;

  /// Human-readable platform name, already localised by the server.
  final String label;
  final String file;

  /// Path relative to the server root — resolve against the API base URL.
  final String url;

  /// Version of this specific artifact. It can lag behind the server when the
  /// platform was not rebuilt during the last publish.
  final String version;
  final int size;
  final DateTime? builtAt;

  const AppDownload({
    required this.platform,
    required this.label,
    required this.file,
    required this.url,
    required this.version,
    required this.size,
    this.builtAt,
  });

  factory AppDownload.fromJson(Map<String, dynamic> json) {
    return AppDownload(
      platform: json['platform'] as String? ?? '',
      label: json['label'] as String? ?? '',
      file: json['file'] as String? ?? '',
      url: json['url'] as String? ?? '',
      version: json['version'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      builtAt: DateTime.tryParse(json['built_at'] as String? ?? ''),
    );
  }

  /// Size as `142 Mo`, or an empty string when the server reported none.
  String get formattedSize {
    if (size <= 0) return '';
    final mb = size / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} Go';
    return '${mb.toStringAsFixed(0)} Mo';
  }
}
