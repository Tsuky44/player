// PROTOTYPE JETABLE — voir README.md. Rien ici n'est du code de production.
//
// Question : une fenêtre mpv `vo=gpu-next` glissée derrière une fenêtre
// Flutter transparente affiche-t-elle un Dolby Vision profil 5 avec les bonnes
// couleurs, avec des contrôles Flutter par-dessus ?
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

// --- libmpv ----------------------------------------------------------------

final _mpv = DynamicLibrary.open('libmpv-2.dll');
final _mpvCreate = _mpv.lookupFunction<Pointer Function(), Pointer Function()>(
  'mpv_create',
);
final _mpvInitialize = _mpv
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'mpv_initialize',
    );
final _mpvSetOption = _mpv
    .lookupFunction<
      Int32 Function(Pointer, Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer, Pointer<Utf8>, Pointer<Utf8>)
    >('mpv_set_option_string');
final _mpvSetProperty = _mpv
    .lookupFunction<
      Int32 Function(Pointer, Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer, Pointer<Utf8>, Pointer<Utf8>)
    >('mpv_set_property_string');
final _mpvGetProperty = _mpv
    .lookupFunction<
      Pointer<Utf8> Function(Pointer, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer, Pointer<Utf8>)
    >('mpv_get_property_string');
final _mpvFree = _mpv
    .lookupFunction<Void Function(Pointer), void Function(Pointer)>('mpv_free');
final _mpvCommand = _mpv
    .lookupFunction<
      Int32 Function(Pointer, Pointer<Pointer<Utf8>>),
      int Function(Pointer, Pointer<Pointer<Utf8>>)
    >('mpv_command');
final _mpvDestroy = _mpv
    .lookupFunction<Void Function(Pointer), void Function(Pointer)>(
      'mpv_terminate_destroy',
    );

class Mpv {
  Mpv() : _handle = _mpvCreate();
  final Pointer _handle;

  int option(String name, String value) => using(
    (arena) => _mpvSetOption(
      _handle,
      name.toNativeUtf8(allocator: arena),
      value.toNativeUtf8(allocator: arena),
    ),
  );

  int set(String name, String value) => using(
    (arena) => _mpvSetProperty(
      _handle,
      name.toNativeUtf8(allocator: arena),
      value.toNativeUtf8(allocator: arena),
    ),
  );

  String? get(String name) => using((arena) {
    final raw = _mpvGetProperty(_handle, name.toNativeUtf8(allocator: arena));
    if (raw == nullptr) return null;
    final value = raw.toDartString();
    _mpvFree(raw);
    return value;
  });

  int command(List<String> args) => using((arena) {
    final array = arena<Pointer<Utf8>>(args.length + 1);
    for (var i = 0; i < args.length; i++) {
      array[i] = args[i].toNativeUtf8(allocator: arena);
    }
    array[args.length] = nullptr;
    return _mpvCommand(_handle, array);
  });

  int initialize() => _mpvInitialize(_handle);
  void dispose() => _mpvDestroy(_handle);
}

// --- Win32 -------------------------------------------------------------------

final _user32 = DynamicLibrary.open('user32.dll');
final _findWindow = _user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');
final _setWindowPos = _user32
    .lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)
    >('SetWindowPos');
final _getClientRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('GetClientRect');
final _clientToScreen = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('ClientToScreen');
final _isIconic = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final _showWindow = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );
final _getWindowLong = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
      'GetWindowLongPtrW',
    );
final _setWindowLong = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, Int32, IntPtr),
      int Function(int, int, int)
    >('SetWindowLongPtrW');

const _videoTitle = 'ONYX_PROTO_VIDEO';
const _swpNoActivate = 0x0010;
const _swpNoOwnerZOrder = 0x0200;
const _gwlExStyle = -20;
const _wsExToolWindow = 0x00000080;
const _wsExNoActivate = 0x08000000;

int _find({String? className, String? title}) => using(
  (arena) => _findWindow(
    className == null ? nullptr : className.toNativeUtf16(allocator: arena),
    title == null ? nullptr : title.toNativeUtf16(allocator: arena),
  ),
);

/// Le rectangle client de [hwnd] en coordonnées écran : x, y, largeur, hauteur.
List<int> _clientRectOnScreen(int hwnd) => using((arena) {
  final rect = arena<Int32>(4);
  final origin = arena<Int32>(2);
  _getClientRect(hwnd, rect);
  origin[0] = 0;
  origin[1] = 0;
  _clientToScreen(hwnd, origin);
  return [origin[0], origin[1], rect[2], rect[3]];
});

// --- Serveur Onyx -----------------------------------------------------------

/// Le strict nécessaire pour lire un média du serveur : une session, puis un
/// ticket de lecture, comme `ApiClient.openPlaybackAccess`.
class OnyxServer {
  OnyxServer(String url) : origin = url.trim().replaceAll(RegExp(r'/+$'), '');
  final String origin;
  String? _token;
  String? _otpChallenge;

  bool get needsCode => _otpChallenge != null;

  Future<(int, dynamic)> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.parse('$origin$path'));
      request.headers.contentType = ContentType.json;
      if (_token != null) {
        request.headers.set('Authorization', 'Bearer $_token');
      }
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      dynamic data;
      try {
        data = jsonDecode(text);
      } catch (_) {
        data = text;
      }
      return (response.statusCode, data);
    } finally {
      client.close();
    }
  }

  /// Rend null quand la session est ouverte, sinon ce qui manque.
  Future<String?> login(String username, String password, String code) async {
    if (_otpChallenge != null && code.isNotEmpty) {
      final (status, data) = await _post('/api/auth/otp/login', {
        'challenge': _otpChallenge,
        'code': code,
      });
      if (status != 200 || data is! Map || data['token'] is! String) {
        return 'Code refusé ($status)';
      }
      _token = data['token'] as String;
      _otpChallenge = null;
      return null;
    }
    final (status, data) = await _post('/api/auth/login', {
      'username': username,
      'password': password,
    });
    if (status == 200 && data is Map && data['token'] is String) {
      _token = data['token'] as String;
      return null;
    }
    if (status == 401 && data is Map && data['otp'] is Map) {
      _otpChallenge = (data['otp'] as Map)['challenge'] as String?;
      return 'Ce compte demande un code : saisissez-le, puis « Lire » à nouveau.';
    }
    return 'Connexion refusée ($status)';
  }

  /// L'adresse du fichier tel quel, avec son ticket de lecture.
  Future<String> streamUrl(int mediaId) async {
    final (status, data) = await _post('/api/playback/tickets', {
      'media_id': mediaId,
    });
    if (status != 200 && status != 201 || data is! Map) {
      throw StateError('Ticket de lecture refusé ($status)');
    }
    return '$origin/stream?media_id=$mediaId&ticket=${data['ticket']}';
  }
}

// --- App ---------------------------------------------------------------------

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Window.initialize();
  await Window.setEffect(effect: WindowEffect.transparent);
  runApp(ProtoApp(initialSource: args.isEmpty ? '' : args.first));
}

class ProtoApp extends StatelessWidget {
  const ProtoApp({super.key, required this.initialSource});
  final String initialSource;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    color: Colors.transparent,
    theme: ThemeData.dark(useMaterial3: true),
    home: ProtoScreen(initialSource: initialSource),
  );
}

class ProtoScreen extends StatefulWidget {
  const ProtoScreen({super.key, required this.initialSource});
  final String initialSource;

  @override
  State<ProtoScreen> createState() => _ProtoScreenState();
}

class _ProtoScreenState extends State<ProtoScreen> {
  late final _source = TextEditingController(text: widget.initialSource);
  final _serverUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _mediaId = TextEditingController();
  OnyxServer? _server;
  Mpv? _player;
  int _flutterHwnd = 0;
  int _videoHwnd = 0;
  Timer? _follow;
  Timer? _poll;
  String _status = 'Serveur + numéro de média, ou chemin d’un fichier.';
  String _verdict = '';
  double _position = 0;
  double _duration = 0;
  bool _paused = false;
  bool _controls = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialSource.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  /// Lit le média du serveur : la session s'ouvre au premier appel et sert
  /// aux suivants. Le mot de passe ne quitte pas la mémoire de ce processus.
  Future<void> _playFromServer() async {
    final id = int.tryParse(_mediaId.text.trim());
    if (id == null || _serverUrl.text.trim().isEmpty) {
      setState(
        () => _status = 'Il faut l’adresse du serveur et un numéro de média.',
      );
      return;
    }
    try {
      var server = _server;
      if (server == null ||
          server.origin != OnyxServer(_serverUrl.text).origin) {
        server = _server = OnyxServer(_serverUrl.text);
      }
      if (server._token == null) {
        final missing = await server.login(
          _username.text.trim(),
          _password.text,
          _code.text.trim(),
        );
        if (missing != null) {
          setState(() => _status = missing);
          return;
        }
      }
      _open(await server.streamUrl(id));
    } catch (e) {
      setState(() => _status = 'Serveur : $e');
    }
  }

  void _play() {
    final source = _source.text.trim().replaceAll('"', '');
    if (source.isEmpty) return;
    _open(source);
  }

  void _open(String source) {
    _stop();

    _flutterHwnd = _find(className: 'FLUTTER_RUNNER_WIN32_WINDOW');
    final log = '${Directory.systemTemp.path}\\onyx-proto-mpv.log';
    final player = Mpv()
      // Le seul moteur de mpv qui applique la couche RPU.
      ..option('vo', 'gpu-next')
      ..option('gpu-api', 'd3d11')
      ..option('hwdec', 'auto-safe')
      // Laisse gpu-next passer l'écran en HDR quand la source l'est.
      ..option('target-colorspace-hint', 'yes')
      // Une fenêtre nue, que l'app place et qui ne prend jamais la main.
      ..option('title', _videoTitle)
      ..option('border', 'no')
      ..option('force-window', 'immediate')
      ..option('keepaspect-window', 'no')
      ..option('focus-on', 'never')
      ..option('input-default-bindings', 'no')
      ..option('input-vo-keyboard', 'no')
      ..option('input-cursor', 'no')
      ..option('cursor-autohide', 'no')
      ..option('osc', 'no')
      ..option('taskbar-progress', 'no')
      ..option('terminal', 'no')
      ..option('log-file', log);
    final init = player.initialize();
    if (init < 0) {
      setState(() => _status = 'mpv_initialize a échoué ($init)');
      player.dispose();
      return;
    }
    player.command(['loadfile', source]);
    _player = player;
    setState(() => _status = 'Ouverture… (journal mpv : $log)');

    _follow = Timer.periodic(const Duration(milliseconds: 16), (_) => _sync());
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _read());
  }

  /// Colle la fenêtre de mpv sous celle de Flutter, à la taille de sa zone
  /// client. Une minuterie et non un message Windows : c'est un prototype.
  void _sync() {
    if (_videoHwnd == 0) {
      _videoHwnd = _find(className: 'mpv', title: _videoTitle);
      if (_videoHwnd == 0) return;
      // Ni bouton dans la barre des tâches, ni activation au clic.
      _setWindowLong(
        _videoHwnd,
        _gwlExStyle,
        _getWindowLong(_videoHwnd, _gwlExStyle) |
            _wsExToolWindow |
            _wsExNoActivate,
      );
    }
    if (_isIconic(_flutterHwnd) != 0) {
      _showWindow(_videoHwnd, 0); // SW_HIDE
      return;
    }
    final r = _clientRectOnScreen(_flutterHwnd);
    _showWindow(_videoHwnd, 4); // SW_SHOWNOACTIVATE
    _setWindowPos(
      _videoHwnd,
      _flutterHwnd,
      r[0],
      r[1],
      r[2],
      r[3],
      _swpNoActivate | _swpNoOwnerZOrder,
    );
  }

  void _read() {
    final p = _player;
    if (p == null) return;
    final profile = p.get('current-tracks/video/dolby-vision-profile');
    final matrix = p.get('video-params/colormatrix') ?? '?';
    final source =
        '${p.get('video-params/primaries') ?? '?'}/${p.get('video-params/gamma') ?? '?'}';
    final target =
        '${p.get('video-target-params/primaries') ?? '?'}/${p.get('video-target-params/gamma') ?? '?'}';
    final size =
        '${p.get('video-params/w') ?? '?'}x${p.get('video-params/h') ?? '?'}';
    final dolby = profile == null
        ? 'pas de Dolby Vision dans ce fichier'
        : 'Dolby Vision profil $profile — '
              '${matrix == 'dolbyvision' ? 'APPLIQUÉ' : 'NON appliqué (matrice $matrix)'}';
    setState(() {
      _position = double.tryParse(p.get('time-pos') ?? '') ?? _position;
      _duration = double.tryParse(p.get('duration') ?? '') ?? _duration;
      _paused = p.get('pause') == 'yes';
      _verdict = dolby;
      _status =
          '$size · vo=${p.get('current-vo') ?? '?'} · '
          'hwdec=${p.get('hwdec-current') ?? '?'} · '
          'source $source → écran $target · '
          'images perdues ${p.get('frame-drop-count') ?? '?'}';
    });
  }

  void _stop() {
    _follow?.cancel();
    _poll?.cancel();
    _player?.dispose();
    _player = null;
    _videoHwnd = 0;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  String _clock(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player != null;
    return Scaffold(
      // Sans vidéo, un fond : une fenêtre entièrement transparente ne se voit
      // pas. Avec, un trou — c'est mpv qu'on voit à travers.
      backgroundColor: playing ? Colors.transparent : const Color(0xFF101014),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _controls = !_controls),
        child: AnimatedOpacity(
          opacity: _controls ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Column(
            children: [
              _bar(
                child: Column(
                  children: [
                    Row(
                      children: [
                        _field(_serverUrl, 'https://serveur…', flex: 3),
                        _field(_username, 'Compte', flex: 2),
                        _field(
                          _password,
                          'Mot de passe',
                          flex: 2,
                          secret: true,
                        ),
                        if (_server?.needsCode ?? false)
                          _field(_code, 'Code', flex: 1),
                        _field(_mediaId, 'N° média', flex: 1),
                        FilledButton(
                          onPressed: _playFromServer,
                          child: const Text('Lire du serveur'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _source,
                            onSubmitted: (_) => _play(),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText:
                                  r'C:\chemin\vers\episode.mkv  ou  https://…',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.tonal(
                          onPressed: _play,
                          child: const Text('Lire le fichier'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _bar(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_verdict.isNotEmpty)
                      Text(
                        _verdict,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: _verdict.contains('APPLIQUÉ')
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                      ),
                    Text(_status, style: const TextStyle(fontSize: 13)),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                          onPressed: playing
                              ? () => _player!.set(
                                  'pause',
                                  _paused ? 'no' : 'yes',
                                )
                              : null,
                        ),
                        Text(_clock(_position)),
                        Expanded(
                          child: Slider(
                            value: _duration <= 0
                                ? 0
                                : (_position / _duration)
                                      .clamp(0, 1)
                                      .toDouble(),
                            onChanged: playing && _duration > 0
                                ? (v) => _player!.command([
                                    'seek',
                                    '${v * _duration}',
                                    'absolute',
                                  ])
                                : null,
                          ),
                        ),
                        Text(_clock(_duration)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String hint, {
    required int flex,
    bool secret = false,
  }) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextField(
        controller: controller,
        obscureText: secret,
        onSubmitted: (_) => _playFromServer(),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    ),
  );

  Widget _bar({required Widget child}) => Container(
    width: double.infinity,
    color: const Color(0xB3000000),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: child,
  );
}
