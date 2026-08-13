import 'package:flutter/material.dart';
import 'glass_catalog_search.dart';

/// In-bar catalog search that fills the width given by its parent (e.g. Expanded).
class InlineCatalogSearch extends StatelessWidget {
  const InlineCatalogSearch({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.clamp(120.0, 420.0);
        return Align(
          alignment: Alignment.centerRight,
          child: GlassCatalogSearch(
            compactTrigger: false,
            collapsedWidth: w,
            expandedWidth: w,
          ),
        );
      },
    );
  }
}
