import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/announcement.dart';
import 'package:onyx/screens/shell/pending_announcement.dart';

const _message = ServerAnnouncement(id: 7, title: 'Maintenance', message: 'Ce soir');

class _Harness {
  _Harness({this.fails = false, this.shows = true});

  ServerAnnouncement? pending = _message;
  bool fails;
  bool shows;
  int fetches = 0;
  final shown = <int>[];
  final seen = <int>[];

  late final check = PendingAnnouncementCheck(
    fetch: () async {
      fetches++;
      if (fails) throw Exception('hors ligne');
      return pending;
    },
    markSeen: (id) async => seen.add(id),
    show: (announcement) async {
      if (!shows) return false;
      shown.add(announcement.id);
      return true;
    },
  );
}

void main() {
  test('le message s’affiche puis se marque vu, une fois par compte ouvert',
      () async {
    final h = _Harness();
    await h.check.run('server-a');
    await h.check.run('server-a');

    expect(h.fetches, 1);
    expect(h.shown, [7]);
    expect(h.seen, [7]);
  });

  test('une bascule vers un autre compte repose la question à son serveur',
      () async {
    final h = _Harness();
    await h.check.run('server-a');
    h.pending = null;
    await h.check.run('server-b');

    expect(h.fetches, 2);
    expect(h.shown, [7]);
  });

  test('sans compte actif, rien n’est demandé', () async {
    final h = _Harness();
    await h.check.run(null);
    expect(h.fetches, 0);
  });

  test('un serveur injoignable ne fait rien perdre : la question revient',
      () async {
    final h = _Harness(fails: true);
    await h.check.run('server-a');
    expect(h.shown, isEmpty);

    h.fails = false;
    await h.check.run('server-a');
    expect(h.shown, [7]);
    expect(h.seen, [7]);
  });

  test('un message qui n’a pas pu s’afficher n’est pas marqué vu', () async {
    final h = _Harness(shows: false);
    await h.check.run('server-a');
    expect(h.seen, isEmpty);

    h.shows = true;
    await h.check.run('server-a');
    expect(h.seen, [7]);
  });
}
