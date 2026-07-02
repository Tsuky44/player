import 'package:flutter/material.dart';
import 'glass_catalog_search.dart';

/// Floating catalog search for narrow layouts (overlay).
class StickyGlassSearch extends StatelessWidget {
  const StickyGlassSearch({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Colors.transparent,
      child: GlassCatalogSearch(
        collapsedWidth: 160,
        expandedWidth: 280,
      ),
    );
  }
}
