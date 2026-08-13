import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/release_tag.dart';

void main() {
  test('extracts the release tag from a scene-style filename', () {
    expect(
      releaseTagFromFilePath(
        '/media/shows/Silo/Season 2/Silo.S02E01.The.Engineer.WEBDL-2160p.Proper.mkv',
      ),
      'WEBDL-2160p Proper',
    );
  });

  test('recognises other common source tokens', () {
    expect(
      releaseTagFromFilePath('/media/movies/Movie.2024.1080p.BluRay.x264.mkv'),
      'BluRay x264',
    );
    expect(
      releaseTagFromFilePath('/media/movies/Movie.2024.REMUX.2160p.mkv'),
      'REMUX 2160p',
    );
  });

  test('returns null when no known source token is present', () {
    expect(releaseTagFromFilePath('/media/movies/Movie.2024.mkv'), isNull);
  });

  test('returns null for empty or missing paths', () {
    expect(releaseTagFromFilePath(null), isNull);
    expect(releaseTagFromFilePath(''), isNull);
  });

  test('composeEpisodeInfoLine joins code, title and release tag', () {
    expect(
      composeEpisodeInfoLine(
        seasonEpisodeCode: 'S02E01',
        title: 'The Engineer',
        filePath: '/media/Silo.S02E01.The.Engineer.WEBDL-2160p.Proper.mkv',
      ),
      'S02E01 - The Engineer WEBDL-2160p Proper',
    );
  });

  test('composeEpisodeInfoLine omits the release tag when none is found', () {
    expect(
      composeEpisodeInfoLine(title: 'The Engineer', filePath: '/media/x.mkv'),
      'The Engineer',
    );
  });
}
