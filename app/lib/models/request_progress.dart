/// Le téléchargement en cours d'un titre, tel que MediaHub le rapporte
/// (`GET /api/requests/progress`). Toutes les chaînes sont déjà formatées par
/// MediaHub (« 1.2 GB », « 4m ») : l'app les affiche sans les recalculer.
class RequestDownload {
  const RequestDownload({
    required this.progress,
    this.timeLeft,
    this.speed,
    this.sizeLeft,
    this.releaseTitle,
  });

  /// De 0 à 100.
  final double progress;
  final String? timeLeft;
  final String? speed;
  final String? sizeLeft;
  final String? releaseTitle;

  factory RequestDownload.fromJson(Map<String, dynamic> json) {
    return RequestDownload(
      progress: _percent(json['progress']),
      timeLeft: _text(json['timeleft']),
      speed: _text(json['speed']),
      sizeLeft: _text(json['sizeLeft']),
      releaseTitle: _text(json['releaseTitle']),
    );
  }
}

/// La copie d'un téléchargement terminé dans la bibliothèque.
class RequestImport {
  const RequestImport({
    required this.releaseName,
    required this.progress,
    required this.files,
    required this.filesDone,
    required this.size,
    required this.sizeDone,
    required this.failed,
    this.current,
    this.message,
  });

  final String releaseName;

  /// De 0 à 100.
  final double progress;
  final int files;
  final int filesDone;
  final String size;
  final String sizeDone;
  final bool failed;
  final String? current;
  final String? message;

  factory RequestImport.fromJson(Map<String, dynamic> json) {
    return RequestImport(
      releaseName: _text(json['releaseName']) ?? '',
      progress: _percent(json['progress']),
      files: (json['files'] as num?)?.toInt() ?? 0,
      filesDone: (json['filesDone'] as num?)?.toInt() ?? 0,
      size: _text(json['size']) ?? '',
      sizeDone: _text(json['sizeDone']) ?? '',
      failed: json['failed'] == true,
      current: _text(json['current']),
      message: _text(json['message']),
    );
  }
}

/// Le suivi d'un titre : un téléchargement, des imports, ou rien.
class RequestProgress {
  const RequestProgress({this.download, this.imports = const []});

  final RequestDownload? download;
  final List<RequestImport> imports;

  bool get isEmpty => download == null && imports.isEmpty;

  factory RequestProgress.fromJson(Map<String, dynamic> json) {
    final download = json['download'];
    final imports = json['imports'];
    return RequestProgress(
      download: download is Map
          ? RequestDownload.fromJson(Map<String, dynamic>.from(download))
          : null,
      imports: imports is List
          ? [
              for (final item in imports)
                if (item is Map)
                  RequestImport.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
    );
  }
}

double _percent(Object? value) =>
    ((value as num?)?.toDouble() ?? 0).clamp(0, 100).toDouble();

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
