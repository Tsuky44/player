// Banc : mpv comme fenêtre ENFANT de la fenêtre de l'app (`wid`), rangée sous
// la vue Flutter. Windows déplace alors les deux ensemble, sans suivi.
//
// Usage : gpu_next_proto.exe <video> [seethrough]
import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import 'main.dart' show Mpv;
import 'win32_video_window.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _findWindowEx = _user32.lookupFunction<
    IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _setWindowPos = _user32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');

final _getWindowLong = _user32.lookupFunction<IntPtr Function(IntPtr, Int32),
    int Function(int, int)>('GetWindowLongPtrW');
final _setWindowLong = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32, IntPtr),
    int Function(int, int, int)>('SetWindowLongPtrW');

int _child(int parent, String className) => using((arena) => _findWindowEx(
    parent, 0, className.toNativeUtf16(allocator: arena), nullptr));

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final seeThrough = args.length > 1;
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _Bench(source: args.first, seeThrough: seeThrough),
  ));
}

class _Bench extends StatefulWidget {
  const _Bench({required this.source, required this.seeThrough});
  final String source;
  final bool seeThrough;

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  String _state = 'démarrage';
  bool _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final top = Win32VideoWindow.findOwn(Win32VideoWindow.flutterWindowClass);
    final player = Mpv()
      ..option('wid', '$top')
      ..option('vo', 'gpu-next')
      ..option('hwdec', 'auto-safe')
      ..option('loop-file', 'inf')
      ..option('input-default-bindings', 'no')
      ..option('input-vo-keyboard', 'no')
      ..option('input-cursor', 'no')
      ..option('cursor-autohide', 'no')
      ..option('log-file', 'onyx-child.log')
      ..initialize();
    player.command(['loadfile', widget.source]);

    var video = 0;
    for (var i = 0; i < 100 && video == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      video = _child(top, 'mpv');
    }
    if (video == 0) {
      setState(() => _state = 'aucune fenêtre enfant mpv');
      return;
    }
    // HWND_BOTTOM (1) : sous la vue Flutter, sans bouger ni redimensionner.
    const noSize = 0x0001, noMove = 0x0002, noActivate = 0x0010;
    // WS_CLIPSIBLINGS : sans lui, une fenêtre du dessous peint par-dessus
    // ses voisines du dessus.
    _setWindowLong(video, -16, _getWindowLong(video, -16) | 0x04000000);
    _setWindowPos(video, 1, 0, 0, 0, 0, noSize | noMove | noActivate | 0x0020);
    if (widget.seeThrough) Win32VideoWindow.setSeeThrough(top, true);
    setState(() {
      _open = true;
      _state = 'enfant mpv=$video sous la vue Flutter'
          '${widget.seeThrough ? ' + fenêtre transparente' : ''}';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          Padding(
            padding: const EdgeInsets.all(60),
            child: CustomPaint(painter: _Hole(_open), size: Size.infinite),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ColoredBox(
              color: const Color(0xB3000000),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Contrôles Flutter — $_state',
                    style: const TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ]),
      );
}

class _Hole extends CustomPainter {
  const _Hole(this.open);
  final bool open;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF202020)
        ..blendMode = open ? BlendMode.clear : BlendMode.srcOver);

  @override
  bool shouldRepaint(_Hole old) => old.open != open;
}
