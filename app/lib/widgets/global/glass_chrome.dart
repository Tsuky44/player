import 'dart:ui';

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// Full-width frosted strip — must float above scrolling content to blur it.
class GlassHeaderStrip extends StatelessWidget {
  final Widget child;

  const GlassHeaderStrip({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.12),
              ],
            ),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Frosted panel for dropdowns and floating elements.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Minimal inline search field — no nested blur (avoids the "sunken" look).
class GlassSearchInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final String hint;
  final bool focused;
  final bool hasText;

  const GlassSearchInput({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    required this.hint,
    this.focused = false,
    this.hasText = false,
  });

  @override
  Widget build(BuildContext context) {
    final idleBorder = Colors.white.withValues(alpha: 0.1);
    final focusBorder = Colors.white.withValues(alpha: 0.22);
    final idleFill = Colors.white.withValues(alpha: 0.05);
    final focusFill = Colors.white.withValues(alpha: 0.1);

    return Theme(
      data: Theme.of(context).copyWith(
        inputDecorationTheme: const InputDecorationTheme(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
      child: SizedBox(
        height: 34,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textInputAction: TextInputAction.search,
          cursorColor: AppColors.textPrimary,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: focused ? focusFill : idleFill,
            hoverColor: Colors.transparent,
            hintText: hint,
            hintStyle: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 17,
              color: AppColors.textSecondary.withValues(alpha: focused ? 0.95 : 0.65),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
            suffixIcon: hasText
                ? IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: AppColors.textMuted.withValues(alpha: 0.8),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 34),
                    onPressed: onClear,
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide(color: idleBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide(color: focusBorder),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide(color: idleBorder),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassBrand extends StatelessWidget {
  final VoidCallback? onTap;

  const GlassBrand({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFE50914), Color(0xFFB20710)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 8),
          Text(
            'PLAYEUR',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  fontSize: 15,
                  height: 1,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 8,
                    ),
                  ],
                ),
          ),
        ],
      ),
    );
  }
}

class GlassNavTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const GlassNavTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.textPrimary : AppColors.textSecondary.withValues(alpha: 0.9),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
                shadows: selected
                    ? null
                    : [Shadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 6)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double size;

  const GlassIconButton({
    super.key,
    required this.child,
    this.onTap,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}
