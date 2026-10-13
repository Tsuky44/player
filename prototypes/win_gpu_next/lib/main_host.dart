// Banc d'essai du code de l'app (copie de MpvWindowHost) : fond noir Flutter,
// trou percé par le widget, transparence posée par FFI — sans flutter_acrylic.
import 'package:flutter/material.dart';

import 'main.dart' show Mpv;
import 'mpv_window_host_io.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final player = Mpv()
    ..option('vo', 'null')
    ..option('hwdec', 'auto-safe')
    ..option('loop-file', 'inf')
    ..option('log-file', 'onyx-host.log')
    ..initialize();
  // Comme dans l app : le fichier s ouvre apres que la surface est en place.
  Future<void>.delayed(const Duration(seconds: 4),
      () => player.command(['loadfile', args.first]));
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Padding(
          padding: const EdgeInsets.all(60),
          child: MpvWindowHost(
              setProperty: (name, value) async {
            final code = player.set(name, value);
            debugPrint('SET $name=$value -> $code');
          }),
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: ColoredBox(
            color: Color(0xB3000000),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Contrôles Flutter par-dessus',
                  style: TextStyle(fontSize: 22)),
            ),
          ),
        ),
      ]),
    ),
  ));
}
