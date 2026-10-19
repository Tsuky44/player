import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/watch_list.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_deferred_keyboard.dart';

/// Ce que la boîte de dialogue rend : le nom, la description et le partage.
typedef WatchListDraft = ({String name, String description, bool isShared});

/// Crée une liste, ou modifie [existing] (ADR-0070). Null quand on annule.
///
/// « À regarder plus tard » n'a que son partage à régler : son nom est celui
/// de l'app, et le serveur ignorerait un autre.
Future<WatchListDraft?> showWatchListEditor(
  BuildContext context, {
  WatchList? existing,
}) {
  return showDialog<WatchListDraft>(
    context: context,
    builder: (_) => _WatchListEditor(existing: existing),
  );
}

class _WatchListEditor extends StatefulWidget {
  const _WatchListEditor({this.existing});

  final WatchList? existing;

  @override
  State<_WatchListEditor> createState() => _WatchListEditorState();
}

class _WatchListEditorState extends State<_WatchListEditor> {
  // Les bornes du serveur (server/watchlists) : au-delà, il refuserait.
  static const _maxName = 80;
  static const _maxDescription = 500;

  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late bool _isShared = widget.existing?.isShared ?? false;

  bool get _fixedName => widget.existing?.isWatchLater ?? false;
  bool get _canSave => _fixedName || _name.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop((
      name: _fixedName ? widget.existing!.name : _name.text.trim(),
      description:
          _fixedName ? widget.existing!.description : _description.text.trim(),
      isShared: _isShared,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text(existing == null
          ? tr('Nouvelle liste')
          : _fixedName
              ? existing.displayName
              : tr('Modifier la liste')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_fixedName) ...[
                TvDeferredKeyboard(
                  builder: (context, focusNode, canRequestFocus) => TextField(
                    controller: _name,
                    focusNode: focusNode,
                    canRequestFocus: canRequestFocus,
                    autofocus: existing == null,
                    maxLength: _maxName,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: tr('Nom'),
                      hintText: tr('Mes recommandations'),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TvDeferredKeyboard(
                  builder: (context, focusNode, canRequestFocus) => TextField(
                    controller: _description,
                    focusNode: focusNode,
                    canRequestFocus: canRequestFocus,
                    maxLength: _maxDescription,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: tr('Description (facultative)'),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isShared,
                onChanged: (v) => setState(() => _isShared = v),
                title: Text(tr('Partager avec les autres comptes')),
                subtitle: Text(
                  _isShared
                      ? tr('Tous les comptes de ce serveur peuvent voir la '
                          'liste. Vous seul la modifiez.')
                      : tr('Vous seul voyez cette liste.'),
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: AppType.subhead),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Annuler')),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(existing == null ? tr('Créer') : tr('Enregistrer')),
        ),
      ],
    );
  }
}
