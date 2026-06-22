import 'package:flutter/material.dart';

/// Top bar shown over the video: a glass back button + the media title.
///
/// Shared by both the standard HUD ([PlayerHUDOverlay]) and the modular
/// layout so the chrome stays identical in both modes.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const PlayerTopBar({
    super.key,
    required this.title,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.15),
                  width: 1,
                ),
              ),
              child: const Icon(
                Icons.arrow_back,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              fontFamily: 'Manrope',
              letterSpacing: 0.01,
            ),
          ),
        ),
      ],
    );
  }
}
