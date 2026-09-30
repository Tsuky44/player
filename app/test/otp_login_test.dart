import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/otp.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/widgets/global/otp_code_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// Validation en deux étapes (ADR-0041), côté app : un 401 qui porte une étape
/// n'est pas un mot de passe refusé, et les codes de secours se montrent avant
/// que la session ne remplace l'écran de connexion.

ResponseBody _json(Object body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ApiClient _clientAnswering(ResponseBody Function(RequestOptions) handle) {
  final dio = Dio()..httpClientAdapter = Adapter(handle);
  return ApiClient(httpClient: dio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a login stopped on a code raises OtpRequired, not a refusal', () async {
    final api = _clientAnswering((_) => _json({
          'error': 'Code de vérification requis.',
          'otp': {'challenge': 'abc', 'setup': false},
        }, 401));

    await expectLater(
      api.login('lea', 'secret'),
      throwsA(isA<OtpRequired>()
          .having((e) => e.challenge.challenge, 'challenge', 'abc')
          .having((e) => e.challenge.setup, 'setup', isFalse)),
    );
  });

  test('a wrong password stays a refusal', () async {
    final api = _clientAnswering(
        (_) => _json({'error': 'Invalid username or password'}, 401));

    await expectLater(
      api.login('lea', 'faux'),
      throwsA(isA<DioException>()),
    );
  });

  test('an unknown policy reads as the server default', () {
    expect(OtpPolicy.parse('everyone'), OtpPolicy.everyone);
    expect(OtpPolicy.parse(null), OtpPolicy.optional);
    expect(OtpPolicy.parse('sometimes'), OtpPolicy.optional);
  });

  testWidgets('recovery codes are shown before the session is handed back',
      (tester) async {
    OtpLoginResult? returned;
    final codesTyped = <String>[];
    const challenge = OtpChallenge(
      serverUrl: 'http://srv',
      challenge: 'abc',
      setup: true,
      secret: 'JBSWY3DPEHPK3PXP',
      uri: 'otpauth://totp/Onyx:lea?secret=JBSWY3DPEHPK3PXP',
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            returned = await showOtpLoginDialog(
              context,
              challenge: challenge,
              verify: (code) async {
                codesTyped.add(code);
                return OtpLoginResult(
                  serverUrl: 'http://srv',
                  token: 't',
                  user: User(id: 1, username: 'lea'),
                  recoveryCodes: const ['aaaaa-bbbbb', 'ccccc-ddddd'],
                );
              },
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();

    expect(codesTyped, ['123456']);
    expect(find.text('aaaaa-bbbbb'), findsOneWidget);
    expect(returned, isNull,
        reason: 'the session must wait until the codes have been seen');

    await tester.tap(find.text('J’ai noté mes codes'));
    await tester.pumpAndSettle();
    expect(returned?.token, 't');
  });
}
