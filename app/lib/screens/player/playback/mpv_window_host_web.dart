import 'package:flutter/widgets.dart';

/// Version web de `MpvWindowHost` : jamais construite, un navigateur n'a ni
/// mpv ni fenêtre à placer.
class MpvWindowHost extends StatelessWidget {
  const MpvWindowHost({super.key, required this.setProperty});

  final Future<void> Function(String name, String value) setProperty;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
