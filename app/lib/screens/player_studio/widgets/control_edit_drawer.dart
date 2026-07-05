import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import 'studio_drawer_shell.dart';

/// Side drawer to tune size/width of the selected control on the canvas.
class ControlEditDrawer extends StatelessWidget {
  final PlacedControl? selectedPlaced;
  final double? sizePercentage;
  final ValueChanged<double> onSizePercentageChanged;
  final double? widthPercentage;
  final ValueChanged<double>? onWidthPercentageChanged;
  final TimelineChromeOptions? timelineOptions;
  final ValueChanged<TimelineChromeOptions>? onTimelineOptionsChanged;
  final VoidCallback? onDelete;

  const ControlEditDrawer({
    super.key,
    required this.selectedPlaced,
    required this.sizePercentage,
    required this.onSizePercentageChanged,
    this.widthPercentage,
    this.onWidthPercentageChanged,
    this.timelineOptions,
    this.onTimelineOptionsChanged,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedPlaced != null && sizePercentage != null;
    final isTimeline = selectedPlaced?.type.isTimelineBar ?? false;
    final tlOpts = timelineOptions ?? TimelineChromeOptions.legacy();

    return StudioDrawerShell(
      title: hasSelection ? selectedPlaced!.type.label : 'Contrôle',
      icon: Icons.straighten,
      subtitle: hasSelection
          ? isTimeline
              ? 'Taille, largeur et boutons intégrés à la barre timeline.'
              : 'Ajuste la taille du contrôle sélectionné sur le canvas.'
          : 'Sélectionne un contrôle sur l’aperçu pour le modifier.',
      child: hasSelection
          ? ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Taille',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onDelete != null)
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                          size: 20,
                        ),
                        onPressed: onDelete,
                        tooltip: 'Supprimer',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    _PercentageField(
                      value: sizePercentage!,
                      min: kMinSizePct,
                      max: kMaxSizePct,
                      onChanged: onSizePercentageChanged,
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF007AFF),
                    inactiveTrackColor: Colors.white.withOpacity(0.15),
                    thumbColor: Colors.white,
                    overlayColor: const Color(0xFF007AFF).withOpacity(0.2),
                  ),
                  child: Slider(
                    min: kMinSizePct,
                    max: kMaxSizePct,
                    value: sizePercentage!.clamp(kMinSizePct, kMaxSizePct),
                    onChanged: onSizePercentageChanged,
                  ),
                ),
                if (_showWidth &&
                    widthPercentage != null &&
                    onWidthPercentageChanged != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Largeur',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _PercentageField(
                        value: widthPercentage!,
                        min: 0.1,
                        max: 1.0,
                        onChanged: onWidthPercentageChanged,
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF007AFF),
                      inactiveTrackColor: Colors.white.withOpacity(0.15),
                      thumbColor: Colors.white,
                      overlayColor: const Color(0xFF007AFF).withOpacity(0.2),
                    ),
                    child: Slider(
                      min: 0.1,
                      max: 1.0,
                      value: widthPercentage!.clamp(0.1, 1.0),
                      onChanged: onWidthPercentageChanged,
                    ),
                  ),
                ],
                if (isTimeline && onTimelineOptionsChanged != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    switch (selectedPlaced!.type) {
                      PlayerControlType.timelineEmby =>
                        'Style Emby — barre fine, sans fond',
                      PlayerControlType.timelineGlassInline =>
                        'Style verre fin — une ligne, heures de chaque côté',
                      _ => 'Style verre — pill floutée, boutons en dessous',
                    },
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Transport (gauche)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _TimelineToggle(
                    label: 'Épisode précédent',
                    value: tlOpts.showSkipPrevious,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showSkipPrevious: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Reculer 10 s',
                    value: tlOpts.showRewind,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showRewind: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Lecture / Pause',
                    value: tlOpts.showPlayPause,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showPlayPause: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Avancer 10 s',
                    value: tlOpts.showForward,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showForward: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Épisode suivant',
                    value: tlOpts.showSkipNext,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showSkipNext: v),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    selectedPlaced!.type == PlayerControlType.timelineEmby ||
                            tlOpts.visualStyle == TimelineVisualStyle.emby
                        ? 'Actions (haut droite)'
                        : 'Actions (droite)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _TimelineToggle(
                    label: 'Paramètres',
                    value: tlOpts.showSettings,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showSettings: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Sous-titres',
                    value: tlOpts.showSubtitles,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showSubtitles: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'Plein écran',
                    value: tlOpts.showFullscreen,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showFullscreen: v),
                    ),
                  ),
                  _TimelineToggle(
                    label: 'À suivre',
                    value: tlOpts.showUpNext,
                    onChanged: (v) => onTimelineOptionsChanged!(
                      tlOpts.copyWith(showUpNext: v),
                    ),
                  ),
                ],
              ],
            )
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Clique sur un bouton ou une barre dans l’aperçu.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
            ),
    );
  }

  bool get _showWidth {
    final type = selectedPlaced?.type;
    return type != null &&
        (type.isProgressBar || type == PlayerControlType.volumeSlider);
  }
}

class _TimelineToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _TimelineToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
      value: value,
      activeThumbColor: const Color(0xFF007AFF),
      onChanged: onChanged,
    );
  }
}

class _PercentageField extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  const _PercentageField({
    required this.value,
    required this.min,
    required this.max,
    this.onChanged,
  });

  @override
  State<_PercentageField> createState() => _PercentageFieldState();
}

class _PercentageFieldState extends State<_PercentageField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _syncText();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _isEditing) {
      _apply();
    }
  }

  @override
  void didUpdateWidget(covariant _PercentageField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_isEditing) {
      _syncText();
    }
  }

  void _syncText() {
    final pct = widget.value * 100;
    _controller.text = pct.toStringAsFixed(2).replaceAll('.', ',');
  }

  void _apply() {
    if (widget.onChanged == null) return;
    final raw = _controller.text.replaceAll(',', '.').replaceAll('%', '');
    final parsed = double.tryParse(raw);
    if (parsed != null) {
      final clamped = (parsed / 100).clamp(widget.min, widget.max);
      widget.onChanged!(clamped);
      _isEditing = false;
    } else {
      _isEditing = false;
      _syncText();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        textAlign: TextAlign.end,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.only(left: 6, top: 4, bottom: 4, right: 2),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: Colors.white24),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: Color(0xFF007AFF)),
          ),
          suffixText: '%',
          suffixStyle: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        readOnly: widget.onChanged == null,
        onTap: widget.onChanged == null ? null : () => _isEditing = true,
      ),
    );
  }
}
