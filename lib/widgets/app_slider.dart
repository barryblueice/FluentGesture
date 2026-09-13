import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

/// A compact slider without Fluent HoverButton's MergeSemantics wrapper.
/// Material Slider owns an OverlayPortal; merging that portal's anchor with
/// its parent can orphan the indicator's Windows AX node on hover (Flutter
/// 3.47 / fluent_ui 4.16). Keep the slider's own adjustable semantics intact.
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return material.Theme(
      data: material.ThemeData(
        brightness: theme.brightness,
        colorSchemeSeed: accent,
        sliderTheme: material.SliderThemeData(
          trackHeight: 4,
          thumbShape: const material.RoundSliderThumbShape(
            enabledThumbRadius: 8,
          ),
          overlayShape: const material.RoundSliderOverlayShape(
            overlayRadius: 14,
          ),
          // The current value is already displayed beside every app slider.
          showValueIndicator: material.ShowValueIndicator.never,
        ),
      ),
      child: material.Material(
        type: material.MaterialType.transparency,
        child: material.Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: accent,
          onChanged: onChanged,
          semanticFormatterCallback: (number) =>
              max <= 1 ? number.toStringAsFixed(2) : number.round().toString(),
        ),
      ),
    );
  }
}
