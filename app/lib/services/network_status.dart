import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_platform.dart';

/// Sur quel genre de réseau l'appareil se trouve.
///
/// Volontairement grossier : les téléchargements n'ont que deux questions à
/// poser — « y a-t-il un réseau ? » et « est-ce que ce réseau se paie à
/// l'octet ? ». Tout le reste est du détail que l'utilisateur n'a pas à
/// arbitrer.
enum NetworkKind { none, wifi, ethernet, mobile, other }

/// De quel réseau dispose l'appareil, et est-ce qu'on peut y télécharger
/// plusieurs gigaoctets sans se faire remarquer.
///
/// Ce n'est **pas** le remplaçant de [ServerReachability] : celui-là demande au
/// serveur s'il répond (`GET /api/ping`, ADR-0010 §6), et c'est lui qui décide
/// si l'app est utilisable. Ici on répond à une autre question, que le ping ne
/// sait pas poser : *sur quoi* passent les octets. Un NAS joignable en 4G est
/// parfaitement joignable — et rapatrier une saison dessus vide un forfait.
///
/// ## Ce qui compte comme « payant »
///
/// Les données mobiles, évidemment. Mais aussi, sur Android, tout réseau que le
/// système déclare limité (`isActiveNetworkMetered`) : c'est ce qui attrape le
/// **partage de connexion** — un téléphone raccordé au hotspot d'un autre voit
/// du Wi-Fi et rien d'autre, alors que les octets sortent bien d'un forfait.
/// Sans cette seconde question, le cas le plus coûteux serait le seul à passer
/// au travers.
///
/// Un VPN par-dessus le Wi-Fi ne compte pas : Android annonce alors `[vpn]`
/// ou `[vpn, wifi]`, et refuser de télécharger parce que quelqu'un a allumé son
/// VPN à la maison serait absurde.
class NetworkStatus extends ChangeNotifier {
  NetworkStatus({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Le canal de l'appareil, déjà utilisé par le mode TV et l'image dans
  /// l'image. Seule la question est nouvelle ; on n'y pose jamais de gestionnaire
  /// d'appels, qui écraserait celui de l'image dans l'image.
  static const MethodChannel _device = MethodChannel('onyx/device');

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  List<ConnectivityResult> _results = const [];

  /// Réponse d'Android à « le réseau actif est-il facturé ? ». Null ailleurs,
  /// et ailleurs c'est le type de réseau seul qui tranche.
  bool? _systemMetered;

  bool _started = false;

  final List<VoidCallback> _onUnmetered = [];

  /// Vrai tant qu'on n'a pas encore eu de réponse. Avant ça, on ne bloque rien :
  /// supposer le pire ferait attendre un Wi-Fi à tous les appareils de bureau
  /// pendant la seconde que met la première réponse à venir.
  bool get isUnknown => _results.isEmpty;

  NetworkKind get kind {
    if (_results.isEmpty) return NetworkKind.other;
    if (_results.contains(ConnectivityResult.wifi)) return NetworkKind.wifi;
    if (_results.contains(ConnectivityResult.ethernet)) {
      return NetworkKind.ethernet;
    }
    if (_results.contains(ConnectivityResult.mobile)) return NetworkKind.mobile;
    if (_results.length == 1 && _results.first == ConnectivityResult.none) {
      return NetworkKind.none;
    }
    return NetworkKind.other;
  }

  /// Aucun réseau du tout. L'avion, le métro, le sous-sol.
  bool get isDisconnected => kind == NetworkKind.none;

  /// Ce réseau-là se paie à l'octet, ou du moins il faut faire comme si.
  bool get isMetered {
    if (isDisconnected) return false; // rien à arbitrer : il n'y a pas de réseau
    if (_systemMetered == true) return true;
    if (_systemMetered == false) return false;
    return kind == NetworkKind.mobile;
  }

  /// Un réseau sur lequel on peut télécharger sans rien demander à personne.
  bool get isFreeToDownload => !isDisconnected && !isMetered;

  /// Rappelé quand un réseau gratuit revient — la box du salon après une
  /// journée en 4G, ou tout simplement du réseau après une journée sans.
  ///
  /// C'est le rendez-vous des téléchargements mis de côté : ce qui attendait
  /// le Wi-Fi repart ici, sans que l'utilisateur ait à rouvrir quoi que ce soit.
  void addUnmeteredListener(VoidCallback listener) => _onUnmetered.add(listener);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscription = _connectivity.onConnectivityChanged.listen(
      _apply,
      onError: (Object error) =>
          debugPrint('Réseau: flux de connectivité interrompu ($error)'),
    );
    try {
      _apply(await _connectivity.checkConnectivity());
    } catch (error) {
      debugPrint('Réseau: état initial indisponible ($error)');
    }
  }

  /// Repose les deux questions maintenant.
  ///
  /// Le retour d'arrière-plan est le moment où la réponse a le plus de chances
  /// d'avoir changé : on a pu quitter la maison entre deux.
  Future<void> refresh() async {
    try {
      _apply(await _connectivity.checkConnectivity());
    } catch (error) {
      debugPrint('Réseau: état indisponible ($error)');
    }
  }

  void _apply(List<ConnectivityResult> results) {
    _results = results;
    // La question au système suit le changement de réseau, jamais l'inverse :
    // c'est le même réseau qu'on vient d'apprendre qu'on interroge.
    unawaited(_askSystemMetered());
    _publish();
  }

  Future<void> _askSystemMetered() async {
    if (!AppPlatform.isAndroid) return;
    try {
      final metered = await _device.invokeMethod<bool>('isNetworkMetered');
      if (_systemMetered == metered) return;
      _systemMetered = metered;
      _publish();
    } on MissingPluginException {
      // Un hôte qui ne connaît pas la question : le type de réseau tranchera.
      _systemMetered = null;
    } catch (error) {
      debugPrint('Réseau: nature du réseau indisponible ($error)');
    }
  }

  bool _wasFree = false;

  void _publish() {
    final free = isFreeToDownload;
    notifyListeners();
    if (free && !_wasFree) {
      for (final listener in List<VoidCallback>.from(_onUnmetered)) {
        listener();
      }
    }
    _wasFree = free;
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
