import 'package:flutter/material.dart';

/// Text colours the options panel offers, as `(name, hex)`. Mid-tones picked
/// to read on both a light and a dark page, so a colour chosen in one theme
/// is still legible when the note is opened in the other.
const kTextColors = <(String, String)>[
  ('Gray', '#787774'),
  ('Brown', '#9F6B53'),
  ('Orange', '#D9730D'),
  ('Yellow', '#CB912F'),
  ('Green', '#448361'),
  ('Blue', '#337EA9'),
  ('Purple', '#9065B0'),
  ('Pink', '#C14C8A'),
  ('Red', '#D44C47'),
];

/// Highlights are the same hues at ~30% alpha (`AARRGGBB`), so the text under
/// them keeps its own colour and contrast in either theme.
const kHighlightColors = <(String, String)>[
  ('Gray', '#4D787774'),
  ('Brown', '#4D9F6B53'),
  ('Orange', '#4DD9730D'),
  ('Yellow', '#4DCB912F'),
  ('Green', '#4D448361'),
  ('Blue', '#4D337EA9'),
  ('Purple', '#4D9065B0'),
  ('Pink', '#4DC14C8A'),
  ('Red', '#4DD44C47'),
];

/// Parses a stored colour (`#RRGGBB`, `#AARRGGBB` or without the `#`).
Color? parseHexColor(String hex) {
  var value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 6) value = 'FF$value';
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? null : Color(parsed);
}

/// One option-panel row of colour swatches: a "none" swatch that clears the
/// colour, then the palette. [highlight] draws filled squares instead of
/// coloured letters.
class SwatchRow extends StatelessWidget {
  const SwatchRow({
    super.key,
    required this.label,
    required this.icon,
    required this.palette,
    required this.active,
    required this.onPick,
    this.highlight = false,
  });

  final String label;
  final IconData icon;
  final List<(String, String)> palette;

  /// The hex currently applied at the caret/selection, if any.
  final String? active;

  /// Called with the chosen hex, or null for "no colour".
  final ValueChanged<String?> onPick;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A plain Row of equal cells, not a scrolling list: the panel around it
    // already scrolls, and a nested scrollable would fight it for drags.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.onSurface),
              const SizedBox(width: 32),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _Swatch(
                  tooltip: 'No $label'.toLowerCase(),
                  selected: active == null,
                  onTap: () => onPick(null),
                  child: Icon(
                    Icons.block,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final (name, hex) in palette)
                Expanded(
                  child: _Swatch(
                    tooltip: '$name ${label.toLowerCase()}',
                    selected: active == hex,
                    fill: highlight ? parseHexColor(hex) : null,
                    onTap: () => onPick(hex),
                    child: highlight
                        ? const SizedBox.shrink()
                        : Text(
                            'A',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: parseHexColor(hex),
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
    this.fill,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            // The 44pt-tall cell is the tap target; the 26pt chip inside it
            // is what's drawn.
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
