import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';

/// Bottom sheet-style panel to tune the size (and optionally width) of the
/// selected control.
class ControlSizeSlider extends StatelessWidget {
  final PlacedControl? selectedPlaced;

  /// Relative size (fraction of shortest screen side, 0.03 -> 0.12).
  final double? sizePercentage;
  final ValueChanged<double> onSizePercentageChanged;

  /// Relative width for the progress bar (0.1 -> 1.0); null for icon controls.
  final double? widthPercentage;
  final ValueChanged<double>? onWidthPercentageChanged;

  /// Called when the user taps the delete button.
  final VoidCallback? onDelete;

  const ControlSizeSlider({
    super.key,
    required this.selectedPlaced,
    required this.sizePercentage,
    required this.onSizePercentageChanged,
    this.widthPercentage,
    this.onWidthPercentageChanged,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasSelection = selectedPlaced != null && sizePercentage != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: hasSelection
          ? _buildSlider(context)
          : const SizedBox(
              height: 56,
              child: Center(
                child: Text(
                  'Sélectionne un contrôle pour ajuster sa taille',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
            ),
    );
  }

  Widget _buildSlider(BuildContext context) {
    final type = selectedPlaced!.type;
    final bool showWidth = type.isProgressBar || type == PlayerControlType.volumeSlider;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.straighten, color: Color(0xFF007AFF), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                type.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                onPressed: onDelete,
                tooltip: 'Supprimer',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
        if (showWidth &&
            widthPercentage != null &&
            onWidthPercentageChanged != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.width_normal, color: Color(0xFF007AFF), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Largeur',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
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
      ],
    );
  }
}

/// A compact editable percentage field that shows values with a comma
/// (French decimal separator) and allows the user to type a value directly.
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
