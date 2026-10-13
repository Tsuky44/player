import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_type.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import 'settings_ui.dart';

/// Ce qu'un administrateur a saisi pour une bibliothèque.
typedef LibraryDraft = ({String name, LibraryKind kind, String path});

/// Ouvre le formulaire d'une bibliothèque : création quand [library] est null,
/// modification sinon. [onSubmit] envoie la saisie au serveur ; tant qu'il
/// échoue le formulaire reste ouvert avec la raison que le serveur donne (un
/// dossier introuvable, déjà pris…), au lieu de se fermer sur une saisie
/// perdue. Rend vrai quand la bibliothèque est enregistrée.
Future<bool> showLibraryEditor(
  BuildContext context, {
  MediaLibrary? library,
  required Future<void> Function(LibraryDraft draft) onSubmit,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _LibraryEditorDialog(library: library, onSubmit: onSubmit),
  );
  return saved == true;
}

class _LibraryEditorDialog extends StatefulWidget {
  const _LibraryEditorDialog({required this.library, required this.onSubmit});

  final MediaLibrary? library;
  final Future<void> Function(LibraryDraft draft) onSubmit;

  @override
  State<_LibraryEditorDialog> createState() => _LibraryEditorDialogState();
}

class _LibraryEditorDialogState extends State<_LibraryEditorDialog> {
  late final _name = TextEditingController(text: widget.library?.name ?? '');
  late final _path = TextEditingController(text: widget.library?.path ?? '');
  late LibraryKind _kind = widget.library?.kind ?? LibraryKind.movies;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.library != null;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final path = _path.text.trim();
    if (name.isEmpty || path.isEmpty) {
      setState(() => _error = tr('Donnez un nom et un dossier à la bibliothèque.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit((name: name, kind: _kind, path: path));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = settingsErrorText(e, tr('Échec de l’enregistrement.'));
      });
    }
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    required String hint,
    bool autofocus = false,
    int? maxLength,
  }) {
    return TvDeferredKeyboard(
      builder: (context, focusNode, canRequestFocus) => TextField(
        focusNode: focusNode,
        canRequestFocus: canRequestFocus,
        controller: controller,
        autofocus: autofocus,
        maxLength: maxLength,
        enabled: !_saving,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          counterText: '',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(_editing
          ? tr('Modifier la bibliothèque')
          : tr('Nouvelle bibliothèque')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(
                _name,
                label: tr('Nom'),
                hint: tr('Le nom affiché dans l’app'),
                autofocus: !_editing,
                // La limite du serveur : un nom s'affiche dans un onglet.
                maxLength: 40,
              ),
              const SizedBox(height: 14),
              _field(
                _path,
                label: tr('Dossier'),
                hint: tr('Chemin complet sur le serveur'),
              ),
              const SizedBox(height: 6),
              Text(
                tr('Le dossier tel que le serveur le voit (dans son conteneur). '
                    'Un dossier ne sert qu’à une bibliothèque.'),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppType.footnote,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                tr('Contenu du dossier'),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppType.subhead,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<LibraryKind>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                      value: LibraryKind.movies, label: Text(tr('Films'))),
                  ButtonSegment(
                      value: LibraryKind.shows, label: Text(tr('Séries'))),
                  ButtonSegment(
                      value: LibraryKind.other, label: Text(tr('Autre'))),
                ],
                selected: {_kind},
                // Des fiches lues comme des films ne deviennent pas des
                // épisodes : le type se choisit à la création.
                onSelectionChanged: _editing || _saving
                    ? null
                    : (choice) => setState(() => _kind = choice.first),
              ),
              const SizedBox(height: 8),
              // Ce que le choix change, dit là où il se fait : le serveur va
              // chercher des affiches pour les deux premiers, pas pour « Autre ».
              Text(
                switch (_kind) {
                  LibraryKind.movies => tr('Chaque fichier est un film : le '
                      'serveur cherche son affiche et sa fiche.'),
                  LibraryKind.shows => tr('Les fichiers sont des épisodes, '
                      'regroupés par série et par saison.'),
                  LibraryKind.other => tr('Vidéos personnelles, concerts, '
                      'cours… Chaque vidéo garde le nom de son fichier, sans '
                      'recherche d’affiche ni de fiche.'),
                },
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppType.footnote,
                  height: 1.4,
                ),
              ),
              if (_editing) ...[
                const SizedBox(height: 6),
                Text(
                  tr('Le contenu ne se change pas : supprimez la bibliothèque '
                      'et recréez-la.'),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppType.footnote,
                    height: 1.4,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                SettingsBanner(_error!, tone: BannerTone.error),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(tr('Annuler')),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? tr('Enregistrement…') : tr('Enregistrer')),
        ),
      ],
    );
  }
}
