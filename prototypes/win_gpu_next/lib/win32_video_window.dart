import 'dart:ffi';
import 'dart:io' show pid;

import 'package:ffi/ffi.dart';

/// Le Win32 qu'il faut pour glisser la fenêtre de mpv sous celle de l'app
/// (ADR-0061). Rien d'autre ne doit passer par ici : c'est le seul endroit de
/// l'app qui parle à `user32.dll`.
abstract final class Win32VideoWindow {
  static final _user32 = DynamicLibrary.open('user32.dll');

  static final _findWindowEx = _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
  static final _windowProcess = _user32.lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _setWindowPos = _user32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)>('SetWindowPos');
  static final _isWindow = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
  static final _isIconic = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
  static final _showWindow = _user32.lookupFunction<
      Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
  static final _getWindow = _user32.lookupFunction<
      IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetWindow');
  static final _getWindowLong = _user32.lookupFunction<
      IntPtr Function(IntPtr, Int32),
      int Function(int, int)>('GetWindowLongPtrW');
  static final _setWindowLong = _user32.lookupFunction<
      IntPtr Function(IntPtr, Int32, IntPtr),
      int Function(int, int, int)>('SetWindowLongPtrW');
  static final _setProp = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, IntPtr),
      int Function(int, Pointer<Utf16>, int)>('SetPropW');
  static final _removeProp = _user32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)>('RemovePropW');
  static final _getWindowRect = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)>('GetWindowRect');
  static final _setComposition = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<_CompositionAttribute>),
      int Function(int,
          Pointer<_CompositionAttribute>)>('SetWindowCompositionAttribute');

  /// La classe de fenêtre du runner Flutter (`win32_window.cpp`).
  static const flutterWindowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

  /// La classe des fenêtres que mpv ouvre lui-même.
  static const mpvWindowClass = 'mpv';

  /// La fenêtre de cette classe qui appartient à ce processus, ou 0. Par
  /// processus et non par titre : deux instances de l'app ne doivent pas se
  /// prendre leurs fenêtres.
  static int findOwn(String className) => using((arena) {
        final name = className.toNativeUtf16(allocator: arena);
        final owner = arena<Uint32>();
        var window = 0;
        while (true) {
          window = _findWindowEx(0, window, name, nullptr);
          if (window == 0) return 0;
          _windowProcess(window, owner);
          if (owner.value == pid) return window;
        }
      });

  /// Rend la fenêtre invisible pour la barre des tâches et Alt+Tab, et
  /// l'empêche de prendre le focus : elle n'existe que sous celle de l'app.
  static void makeBackdrop(int window) {
    const exStyle = -20;
    const toolWindow = 0x00000080;
    const noActivate = 0x08000000;
    _setWindowLong(window, exStyle,
        _getWindowLong(window, exStyle) | toolWindow | noActivate);
  }

  // Les propriétés que lit `windows/runner/video_backdrop.h` : les noms
  // doivent rester les mêmes des deux côtés.
  static const _windowProp = 'OnyxVideoWindow';
  static const _insetProps = [
    'OnyxVideoLeft',
    'OnyxVideoTop',
    'OnyxVideoRight',
    'OnyxVideoBottom',
  ];

  /// La classe de la vue Flutter, enfant de la fenêtre du runner.
  static const _flutterViewClass = 'FLUTTERVIEW';

  /// Colle [video] sous [app], aux marges données (gauche, haut, droite, bas,
  /// en pixels physiques de la vue Flutter), et le dit au runner.
  ///
  /// Le runner refait ce placement à chaque message de fenêtre — c'est lui
  /// qui suit un glissement, pendant lequel rien ne tourne côté Dart. Cet
  /// appel-ci sert quand c'est la mise en page de Flutter qui change. Le
  /// calcul est le même des deux côtés : voir `video_backdrop::Sync`.
  static void attach({
    required int app,
    required int video,
    required List<int> insets,
  }) {
    using((arena) {
      _setProp(app, _windowProp.toNativeUtf16(allocator: arena), video);
      for (var i = 0; i < _insetProps.length; i++) {
        _setProp(
            app, _insetProps[i].toNativeUtf16(allocator: arena), insets[i]);
      }
      final target = _target(arena, app, insets);
      if (target == null) return;
      const noActivate = 0x0010;
      const noOwnerZOrder = 0x0200;
      _setWindowPos(video, app, target[0], target[1], target[2] - target[0],
          target[3] - target[1], noActivate | noOwnerZOrder);
    });
  }

  /// Si [video] occupe bien le rectangle que [attach] lui a donné.
  ///
  /// mpv déplace sa fenêtre de lui-même — à l'ouverture d'un fichier, il la
  /// remet à la taille de la vidéo — sans que rien n'ait changé côté app.
  static bool isInPlace({
    required int app,
    required int video,
    required List<int> insets,
  }) =>
      using((arena) {
        final target = _target(arena, app, insets);
        if (target == null) return true;
        final actual = arena<Int32>(4);
        if (_getWindowRect(video, actual) == 0) return true;
        for (var i = 0; i < 4; i++) {
          if (actual[i] != target[i]) return false;
        }
        return true;
      });

  /// Le rectangle écran (gauche, haut, droite, bas) de la vidéo : la vue
  /// Flutter, moins les marges. Le même calcul que `video_backdrop::Sync`.
  static List<int>? _target(Arena arena, int app, List<int> insets) {
    final view = _findWindowEx(
        app, 0, _flutterViewClass.toNativeUtf16(allocator: arena), nullptr);
    if (view == 0) return null;
    final area = arena<Int32>(4);
    if (_getWindowRect(view, area) == 0) return null;
    return [
      area[0] + insets[0],
      area[1] + insets[1],
      area[2] - insets[2],
      area[3] - insets[3],
    ];
  }

  /// Le runner cesse de suivre : la vidéo n'est plus sous [app].
  static void detach(int app) {
    using((arena) {
      _removeProp(app, _windowProp.toNativeUtf16(allocator: arena));
      for (final name in _insetProps) {
        _removeProp(app, name.toNativeUtf16(allocator: arena));
      }
    });
  }

  /// Si [window] est bien la fenêtre placée juste sous [above].
  static bool isRightUnder(int window, int above) {
    const next = 2; // GW_HWNDNEXT
    return _getWindow(above, next) == window;
  }

  /// Si [window] existe encore. mpv détruit la sienne quand sa sortie vidéo
  /// se ferme, sur son propre fil.
  static bool exists(int window) => _isWindow(window) != 0;

  static bool isMinimized(int window) => _isIconic(window) != 0;

  static void setVisible(int window, bool visible) {
    const hide = 0;
    const showNoActivate = 4;
    _showWindow(window, visible ? showNoActivate : hide);
  }

  /// Laisse voir, ou non, ce qui se trouve sous les pixels transparents de
  /// [window]. Sans ça, DWM compose la fenêtre de l'app opaque et le trou
  /// percé par la surface vidéo sort noir.
  ///
  /// C'est l'appel que fait `flutter_acrylic` pour son effet « transparent »
  /// — une fonction de `user32` non documentée mais stable depuis Windows 10.
  static void setSeeThrough(int window, bool seeThrough) {
    using((arena) {
      const accentDisabled = 0;
      const accentTransparentGradient = 2;
      final policy = arena<_AccentPolicy>();
      policy.ref
        ..state = seeThrough ? accentTransparentGradient : accentDisabled
        ..flags = 2
        ..gradientColor = 0
        ..animationId = 0;
      const accentPolicy = 19; // WCA_ACCENT_POLICY
      final data = arena<_CompositionAttribute>();
      data.ref
        ..attribute = accentPolicy
        ..data = policy.cast()
        ..size = sizeOf<_AccentPolicy>();
      _setComposition(window, data);
    });
  }
}

final class _AccentPolicy extends Struct {
  @Int32()
  external int state;
  @Int32()
  external int flags;
  @Uint32()
  external int gradientColor;
  @Int32()
  external int animationId;
}

final class _CompositionAttribute extends Struct {
  @Int32()
  external int attribute;
  external Pointer<Void> data;
  @IntPtr()
  external int size;
}
