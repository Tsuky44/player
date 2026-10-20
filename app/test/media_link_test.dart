import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/navigation/media_link.dart';

/// « Lire dans Onyx » depuis OnyxHub ouvre la fiche que nomme le lien
/// (ADR-0073).
void main() {
  test('un lien ?movie= ou ?show= nomme la fiche à ouvrir', () {
    expect(MediaLink.parse(Uri.parse('https://onyx.example/?movie=12')),
        (MediaType.movie, 12));
    expect(MediaLink.parse(Uri.parse('https://onyx.example/?show=40')),
        (MediaType.show, 40));
  });

  test('un lien sans identifiant valable ne fait rien', () {
    expect(MediaLink.parse(Uri.parse('https://onyx.example/')), isNull);
    expect(
        MediaLink.parse(Uri.parse('https://onyx.example/?movie=abc')), isNull);
    expect(MediaLink.parse(Uri.parse('https://onyx.example/?show=0')), isNull);
    expect(MediaLink.parse(Uri.parse('https://onyx.example/?tv=ABCD')), isNull);
  });

  test('la fiche ne sert qu’une fois', () {
    MediaLink.capture(); // Uri.base des tests n'a pas de requête
    expect(MediaLink.takeRoute(), isNull);
  });
}
