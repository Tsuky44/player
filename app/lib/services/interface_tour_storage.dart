import 'package:shared_preferences/shared_preferences.dart';

/// Retient, par compte, que la présentation de l'interface a déjà été vue.
///
/// Sur l'appareil et non sur le compte : la présentation montre le chrome de
/// *cet* écran — une barre d'onglets en bas sur un téléphone, un en-tête sur
/// un téléviseur — et l'avoir vue sur l'un n'apprend rien de l'autre. Par
/// compte et non une fois pour toutes, parce que deux personnes d'un même
/// foyer se succèdent sur un téléviseur (ADR-0043).
abstract final class InterfaceTourStorage {
  static const String _prefix = 'interface_tour_seen:';

  /// [accountId] est l'identifiant du compte au carnet
  /// (`ServerAccount.id`), stable d'un lancement à l'autre.
  static Future<bool> hasSeen(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_prefix$accountId') ?? false;
    } catch (_) {
      // Des préférences illisibles valent « déjà vue » : l'inverse rejouerait
      // la présentation à chaque lancement, sans moyen de s'en défaire.
      return true;
    }
  }

  static Future<void> markSeen(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefix$accountId', true);
    } catch (_) {
      // Rien à rattraper : au pire, la présentation repasse une fois.
    }
  }
}
