import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/pages/shares_page.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/widgets/global/share_media_button.dart';
import 'package:onyx/widgets/global/share_media_dialog.dart';
import 'package:provider/provider.dart';

/// Une doublure qui retient la dernière création demandée.
class _Api extends ApiClient {
  Map<String, Object?>? created;

  @override
  String get baseUrl => 'https://onyx.example.org';

  @override
  Future<MediaShare> createMediaShare({
    required int mediaId,
    String password = '',
    required bool singleUse,
    required ShareLifetime lifetime,
  }) async {
    created = {
      'mediaId': mediaId,
      'password': password,
      'singleUse': singleUse,
      'lifetime': lifetime,
    };
    return MediaShare.fromJson({
      'id': 3,
      'media_id': mediaId,
      'title': 'Film',
      'status': 'active',
      'single_use': singleUse,
      'has_password': password.isNotEmpty,
      'expires_at': '2026-10-01T20:00:00Z',
      'code': 'AbCdEfGhIjKlMnOpQrStUv',
    });
  }
}

class _Auth extends AuthProvider {
  _Auth(super.api, this._permissions);
  final Permissions _permissions;
  @override
  Permissions get permissions => _permissions;
}

HomeMediaItem _item(MediaType type) => HomeMediaItem(
      media: Media(
        id: 7,
        type: type,
        title: 'Film',
        duration: 6000,
        createdAt: DateTime(2026),
      ),
      currentPositionSeconds: 0,
      duration: 6000,
      isFinished: false,
    );

void main() {
  group('MediaShare.fromJson', () {
    test('lit un lien tel que le serveur le décrit', () {
      final share = MediaShare.fromJson({
        'id': 4,
        'media_id': 12,
        'media_type': 'episode',
        'title': 'Lioness',
        'subtitle': 'S01E05 · Cinq cent enfants',
        'has_password': true,
        'single_use': true,
        'claimed': true,
        'views': 2,
        'status': 'watched',
        'consumed_at': '2026-09-24T19:00:00Z',
        'created_at': '2026-09-20T19:00:00Z',
      });
      expect(share.mediaId, 12);
      expect(share.subtitle, 'S01E05 · Cinq cent enfants');
      expect(share.hasPassword && share.singleUse && share.claimed, isTrue);
      expect(share.isActive, isFalse);
      expect(share.consumedAt, isNotNull);
      expect(share.expiresAt, isNull, reason: 'sans échéance');
      expect(share.code, isNull,
          reason: 'le serveur ne redonne jamais le code après la création');
    });
  });

  // Le droit arrive après les six autres : il doit faire l'aller-retour, et un
  // administrateur sans lui n'en est plus un.
  test('le droit share_media fait l’aller-retour JSON', () {
    const granted = Permissions(shareMedia: true);
    expect(Permissions.fromJson(granted.toJson()).shareMedia, isTrue);
    expect(Permissions.all.shareMedia, isTrue);
    expect(Permissions.all.copyWith(shareMedia: false).isAdmin, isFalse);
  });

  group('mediaShareSummary', () {
    final now = DateTime(2026, 9, 24, 21);
    MediaShare share(Map<String, dynamic> json) =>
        MediaShare.fromJson({'id': 1, 'media_id': 1, 'title': 'Film', ...json});

    test('lien à usage unique pas encore ouvert', () {
      expect(
        mediaShareSummary(
            share({
              'status': 'active',
              'single_use': true,
              'has_password': true,
              'expires_at': '2026-10-01T10:00:00Z',
            }),
            now: now),
        'Détruit après lecture · Expire le jeudi 1 octobre · Mot de passe',
      );
    });

    test('lien réutilisable sans échéance', () {
      expect(
        mediaShareSummary(share({'status': 'active', 'views': 3}), now: now),
        'Ouvert 3 fois · Sans limite',
      );
    });

    test('lien vu', () {
      expect(
        mediaShareSummary(
            share({
              'status': 'watched',
              'consumed_at':
                  DateTime(2026, 9, 24, 20, 30).toUtc().toIso8601String(),
            }),
            now: now),
        'Vu il y a 30 min',
      );
    });
  });

  test('isLocalOnlyAddress reconnaît les adresses du réseau local', () {
    for (final local in [
      'http://localhost:8080',
      'http://192.168.1.20:8080',
      'http://10.0.0.5',
      'http://172.20.1.1',
      'http://onyx.local',
    ]) {
      expect(isLocalOnlyAddress(Uri.parse(local)), isTrue, reason: local);
    }
    for (final public in [
      'https://onyx.example.org',
      'http://172.40.1.1',
      'http://82.64.10.3:8080',
    ]) {
      expect(isLocalOnlyAddress(Uri.parse(public)), isFalse, reason: public);
    }
  });

  testWidgets(
      'la boîte de partage crée un lien à usage unique et montre son adresse',
      (tester) async {
    final api = _Api();
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ShareMediaDialog(api: api, mediaId: 42, title: 'Film'),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'popcorn');
    await tester.tap(find.text('30 jours'));
    await tester.pump();
    await tester.tap(find.text('Créer le lien'));
    await tester.pumpAndSettle();

    expect(api.created, {
      'mediaId': 42,
      'password': 'popcorn',
      'singleUse': true,
      'lifetime': ShareLifetime.month,
    });
    const link = 'https://onyx.example.org/share#AbCdEfGhIjKlMnOpQrStUv';
    expect(find.text(link), findsOneWidget);

    await tester.tap(find.text('Copier le lien'));
    await tester.pump();
    expect(copied, link);
    expect(find.text('Copié'), findsOneWidget);
  });

  // Ce qui n'est pas dessiné ne produit pas de 403 : sans le droit, pas de
  // bouton ; une série entière ne se partage pas, seulement un film ou un
  // épisode.
  testWidgets('le bouton de partage suit le droit et le type de média',
      (tester) async {
    Future<bool> shown(Permissions permissions, MediaType type) async {
      final auth = _Auth(_Api(), permissions);
      await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: Scaffold(body: ShareMediaButton(item: _item(type))),
        ),
      ));
      final found = find.byTooltip('Partager par lien').evaluate().isNotEmpty;
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      return found;
    }

    expect(await shown(const Permissions(), MediaType.movie), isFalse);
    expect(await shown(const Permissions(shareMedia: true), MediaType.movie),
        isTrue);
    expect(await shown(const Permissions(shareMedia: true), MediaType.episode),
        isTrue);
    expect(await shown(const Permissions(shareMedia: true), MediaType.show),
        isFalse);
  });
}
