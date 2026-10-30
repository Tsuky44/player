import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/request_progress.dart';

void main() {
  test('le suivi lit le téléchargement et les imports tels que MediaHub les rend',
      () {
    final progress = RequestProgress.fromJson({
      'active': true,
      'download': {
        'progress': 42.5,
        'timeleft': '4m',
        'speed': '3 MB/s',
        'sizeLeft': '600 MB',
        'releaseTitle': 'Show.S01',
      },
      'imports': [
        {
          'releaseName': 'Show.S01',
          'progress': 130,
          'files': 10,
          'filesDone': 1,
          'size': '1 GB',
          'sizeDone': '100 MB',
          'failed': true,
          'message': '  ',
        },
      ],
    });

    expect(progress.download!.progress, 42.5);
    expect(progress.download!.timeLeft, '4m');
    // Un pourcentage hors bornes ne casse pas la barre.
    expect(progress.imports.single.progress, 100);
    // Un message vide n'est pas un message.
    expect(progress.imports.single.message, isNull);
    expect(progress.isEmpty, isFalse);
  });

  test('sans téléchargement ni import le suivi est vide', () {
    final progress = RequestProgress.fromJson(
        {'active': false, 'download': null, 'imports': []});
    expect(progress.isEmpty, isTrue);
  });
}
