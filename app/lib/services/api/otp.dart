part of '../api_client.dart';

/// La connexion attend un code quand le serveur répond 401 avec un objet
/// `otp` : le mot de passe était juste. Tout autre refus reste un refus.
OtpChallenge? _otpChallengeFrom(DioException error, String serverUrl) {
  final response = error.response;
  final data = response?.data;
  if (response?.statusCode != 401 || data is! Map) return null;
  final otp = data['otp'];
  if (otp is! Map) return null;
  final challenge =
      OtpChallenge.fromJson(serverUrl, Map<String, dynamic>.from(otp));
  return challenge.challenge.isEmpty ? null : challenge;
}

/// Validation en deux étapes (ADR-0041).
///
/// Un morceau d'[ApiClient], comme [_AccountAdminEndpoints] : les doublures de
/// test qui étendent [ApiClient] peuvent surcharger ces méthodes.
mixin _OtpEndpoints {
  Dio get _dio;
  Dio _bareClient();

  /// Termine une connexion arrêtée sur un code. Sur le Dio nu : la route est
  /// publique, et le serveur interrogé n'est pas forcément le serveur actif.
  Future<OtpLoginResult> verifyLoginOtp(
    OtpChallenge challenge,
    String code,
  ) async {
    final response = await _bareClient().post(
      '${challenge.serverUrl}/api/auth/otp/login',
      data: {'challenge': challenge.challenge, 'code': code},
    );
    return OtpLoginResult.fromJson(
      challenge.serverUrl,
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<OtpStatus> getOtpStatus() async {
    final response = await _dio.get('/api/auth/otp');
    return OtpStatus.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Tire un secret. Rien n'est activé tant que [enableOtp] n'a pas reçu un
  /// premier code juste.
  Future<OtpSetup> startOtpSetup() async {
    final response = await _dio.post('/api/auth/otp/setup');
    return OtpSetup.fromJson(Map<String, dynamic>.from(response.data as Map));
  }

  /// Active la validation et rend les codes de secours, à montrer une fois.
  Future<List<String>> enableOtp(String code) async {
    final response =
        await _dio.post('/api/auth/otp/enable', data: {'code': code});
    return parseRecoveryCodes(Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> disableOtp(String password) async {
    await _dio.post('/api/auth/otp/disable', data: {'password': password});
  }

  Future<List<String>> regenerateOtpRecoveryCodes(String password) async {
    final response = await _dio
        .post('/api/auth/otp/recovery-codes', data: {'password': password});
    return parseRecoveryCodes(Map<String, dynamic>.from(response.data as Map));
  }

  /// Retire le code d'un autre compte, qui a perdu son téléphone.
  Future<void> resetUserOtp(int userId) async {
    await _dio.delete('/api/users/$userId/otp');
  }
}
