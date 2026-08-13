import 'package:web/web.dart' as web;

/// Web implementation — see `external_url.dart`.
///
/// `noopener` keeps the opened tab from reaching back into this one through
/// `window.opener`. The call is always made from a click handler, so the popup
/// blocker lets it through.
Future<bool> openExternalUrl(String url) async {
  web.window.open(url, '_blank', 'noopener');
  return true;
}
