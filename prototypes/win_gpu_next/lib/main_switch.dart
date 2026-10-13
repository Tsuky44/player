// Banc : un lecteur media_kit avec sa texture (comme l'app), basculé en cours
// de lecture vers la fenêtre gpu-next — ce que l'app fait pour un Dolby Vision
// profil 5 une fois ses pistes connues.
//
// Usage : gpu_next_proto.exe <video>     (bascule à 5 s)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mpv_window_host_io.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _Bench(source: args.first),
  ));
}

class _Bench extends StatefulWidget {
  const _Bench({required this.source});
  final String source;

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final _player = Player();
  late final _controller = VideoController(_player);
  bool _window = false;
  String _state = 'texture';

  @override
  void initState() {
    super.initState();
    _player.setPlaylistMode(PlaylistMode.loop);
    _player.open(Media(widget.source));
    Timer(const Duration(seconds: 5), () => setState(() => _window = true));
    Timer.periodic(const Duration(seconds: 1), (_) async {
      final platform = _player.platform as dynamic;
      final vo = await platform.getProperty('current-vo');
      final hwdec = await platform.getProperty('hwdec-current');
      final pos = await platform.getProperty('time-pos');
      if (mounted) setState(() => _state = 'vo=$vo hwdec=$hwdec t=$pos');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          Padding(
            padding: const EdgeInsets.all(60),
            child: _window
                ? MpvWindowHost(
                    setProperty: (name, value) async {
                      await (_player.platform as dynamic)
                          .setProperty(name, value);
                    },
                  )
                : Video(controller: _controller, controls: NoVideoControls),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ColoredBox(
              color: const Color(0xB3000000),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('${_window ? 'FENÊTRE' : 'TEXTURE'} — $_state',
                    style: const TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ]),
      );
}
