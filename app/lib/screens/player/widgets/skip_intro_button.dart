import 'package:flutter/material.dart';

class SkipIntroButton extends StatelessWidget {
  final VoidCallback onSkip;

  const SkipIntroButton({super.key, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 170,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSkip,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A).withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Passer l'intro",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.skip_next, color: Colors.white, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
