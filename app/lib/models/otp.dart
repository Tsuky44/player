import 'models.dart';
import '../l10n/tr.dart';

/// Validation en deux étapes (ADR-0041) : ce que le serveur exige, ce que le
/// compte a configuré, et la connexion arrêtée entre le mot de passe et le code.

/// La politique choisie par un administrateur pour tout le serveur.
enum OtpPolicy {
  /// Personne ne peut l'activer, et la connexion ne demande jamais de code.
  disabled('disabled', 'Désactivée'),

  /// Chaque compte décide pour lui-même.
  optional('optional', 'Facultative'),

  /// Imposée aux comptes qui administrent le serveur.
  admins('admins', 'Obligatoire pour les admins'),

  /// Imposée à tous les comptes.
  everyone('everyone', 'Obligatoire pour tous');

  const OtpPolicy(this.wire, this._label);

  final String wire;
  final String _label;

  String get label => tr(_label);

  /// Une valeur inconnue, ou un serveur trop ancien pour en envoyer une, se lit
  /// comme la politique par défaut du serveur.
  static OtpPolicy parse(String? raw) => OtpPolicy.values.firstWhere(
        (p) => p.wire == raw,
        orElse: () => OtpPolicy.optional,
      );
}

/// Une connexion dont le mot de passe est juste, et qui attend un code.
class OtpChallenge {
  /// Le serveur qui a posé la question : c'est à lui que le code répond, que
  /// ce soit le serveur actif ou celui qu'on ajoute au carnet.
  final String serverUrl;
  final String challenge;

  /// Vrai quand la politique impose un code que le compte n'a pas encore
  /// configuré : il faut d'abord scanner [uri] ou recopier [secret].
  final bool setup;
  final String secret;
  final String uri;

  const OtpChallenge({
    required this.serverUrl,
    required this.challenge,
    this.setup = false,
    this.secret = '',
    this.uri = '',
  });

  factory OtpChallenge.fromJson(String serverUrl, Map<String, dynamic> json) {
    return OtpChallenge(
      serverUrl: serverUrl,
      challenge: json['challenge'] as String? ?? '',
      setup: json['setup'] == true,
      secret: json['secret'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
    );
  }
}

/// Levée par une connexion qui attend un code : ce n'est pas un échec, c'est
/// la moitié du chemin.
class OtpRequired implements Exception {
  final OtpChallenge challenge;
  const OtpRequired(this.challenge);

  @override
  String toString() => 'OtpRequired(${challenge.serverUrl})';
}

/// Une connexion menée jusqu'au bout. La session n'est pas encore rangée au
/// carnet : les codes de secours se montrent d'abord, sans que l'écran de
/// connexion disparaisse sous l'utilisateur.
class OtpLoginResult {
  final String serverUrl;
  final String token;
  final User user;
  final List<String> recoveryCodes;

  const OtpLoginResult({
    required this.serverUrl,
    required this.token,
    required this.user,
    this.recoveryCodes = const [],
  });

  factory OtpLoginResult.fromJson(String serverUrl, Map<String, dynamic> json) {
    return OtpLoginResult(
      serverUrl: serverUrl,
      token: json['token'] as String,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      recoveryCodes: parseRecoveryCodes(json),
    );
  }
}

List<String> parseRecoveryCodes(Map<String, dynamic> json) =>
    (json['recovery_codes'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();

/// L'état de la validation en deux étapes du compte connecté.
class OtpStatus {
  final OtpPolicy policy;
  final bool enabled;

  /// La politique l'impose à ce compte : il ne peut pas la désactiver.
  final bool required;
  final int recoveryCodesLeft;

  const OtpStatus({
    required this.policy,
    required this.enabled,
    required this.required,
    required this.recoveryCodesLeft,
  });

  factory OtpStatus.fromJson(Map<String, dynamic> json) {
    return OtpStatus(
      policy: OtpPolicy.parse(json['policy'] as String?),
      enabled: json['enabled'] == true,
      required: json['required'] == true,
      recoveryCodesLeft: json['recovery_codes_left'] as int? ?? 0,
    );
  }
}

/// Le secret à donner à l'application d'authentification.
class OtpSetup {
  final String secret;
  final String uri;

  const OtpSetup({required this.secret, required this.uri});

  factory OtpSetup.fromJson(Map<String, dynamic> json) => OtpSetup(
        secret: json['secret'] as String? ?? '',
        uri: json['uri'] as String? ?? '',
      );
}
