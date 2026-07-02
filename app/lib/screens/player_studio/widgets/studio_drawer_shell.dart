import 'package:flutter/material.dart';

/// Shared chrome for Player Studio side drawers (header + scroll body).
class StudioDrawerShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget child;

  const StudioDrawerShell({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1A1A),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(icon, color: const Color(0xFF007AFF), size: 22),
                ],
              ),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Text(
                  subtitle!,
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
