import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// La vue AppKit dans laquelle libmpv dessine.
///
/// C'est l'équivalent macOS de la `SurfaceView` d'ExoPlayer : une vraie vue du
/// système, pas une texture Flutter. mpv y présente ses images lui-même avec
/// `gpu-next` — le seul moteur de mpv qui applique la couche RPU du Dolby
/// Vision, et que l'API de rendu utilisée par media_kit ne sait pas piloter.
///
/// mpv ne trouve pas la vue tout seul : il faut lui en donner l'adresse
/// (`wid`) avant de créer sa sortie vidéo — c'est [onAttach] — et la lui
/// reprendre avant qu'elle ne disparaisse — [onDetach] — sinon il continue de
/// présenter dans une vue libérée.
///
/// Dessiner *par-dessus* fonctionne normalement : les contrôles et les
/// sous-titres se composent au-dessus. La vue ne prend aucun clic, pour que
/// ceux-ci arrivent aux détecteurs du lecteur.
class MpvHostView extends StatefulWidget {
  const MpvHostView({
    super.key,
    required this.onAttach,
    required this.onDetach,
  });

  /// Reçoit l'adresse de la `NSView`, à donner à mpv comme `wid`.
  final Future<void> Function(int viewHandle) onAttach;

  /// Doit rendre la main une fois que mpv a lâché cette vue-là.
  final Future<void> Function(int viewHandle) onDetach;

  @override
  State<MpvHostView> createState() => _MpvHostViewState();
}

class _MpvHostViewState extends State<MpvHostView> {
  static const _channel = MethodChannel('onyx_mpv_macos');

  /// Doit correspondre à `OnyxMpvMacosPlugin.viewType` côté Swift.
  static const _viewType = 'onyx_mpv_macos/surface';

  int? _viewId;
  int? _attachedHandle;

  Future<void> _onCreated(int id) async {
    _viewId = id;
    final handle = await _channel.invokeMethod<int>('viewHandle', id);
    if (handle == null || !mounted) return;
    _attachedHandle = handle;
    await widget.onAttach(handle);
  }

  @override
  void dispose() {
    final id = _viewId;
    final handle = _attachedHandle;
    final detach = widget.onDetach;
    // AppKitView retire la vue de la hiérarchie tout de suite, mais mpv peut
    // encore être en train d'y présenter une image. Le côté Swift la retient
    // donc jusqu'à `release`, qui n'arrive qu'une fois mpv détaché.
    unawaited(() async {
      try {
        if (handle != null) await detach(handle);
      } finally {
        if (id != null) await _channel.invokeMethod<void>('release', id);
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppKitView(
      viewType: _viewType,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      onPlatformViewCreated: _onCreated,
    );
  }
}
