/// Splits long track labels into a title + technical subtitle when possible.
(String title, String? subtitle) splitTrackLabel(String label) {
  final atIdx = label.indexOf('@');
  if (atIdx > 0 && atIdx < label.length - 2) {
    final title = label.substring(0, atIdx).trim();
    final rest = label.substring(atIdx).trim();
    if (title.isNotEmpty) return (title, rest);
  }
  if (label.length > 42) {
    final split = label.lastIndexOf(' ', 42);
    if (split > 12) {
      return (label.substring(0, split).trim(), label.substring(split).trim());
    }
  }
  return (label, null);
}
