import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

/// U+200B — painted when a text node has no text of its own, purely so it
/// still has a line box for caret placement/height measurement. Render-only:
/// it is never part of the model, and any hit-tested offset against it is
/// clamped back to the model's own (zero) length by the caller.
///
/// Deliberately NOT named `kEmptyNodeSentinel` — that public constant
/// (`node_text_controller.dart`, `' '`) is a different, IME-facing concept
/// this rewrite keeps working unchanged (see `document_input_client.dart`'s
/// own `_imeSentinel`); this one is private and purely a rendering detail.
const _emptyNodeRenderPlaceholder = '​';

/// Builds the [TextSpan] for one [TextNode]'s rendered text: the node's own
/// [AttributedText] styled by its attributions (bold/italic/link/etc, same
/// rules the old `NodeTextController.buildTextSpan` used), with an optional
/// underlined [composingRange] for the IME's current composing region.
///
/// Render offsets equal model offsets exactly — there is no field-level
/// sentinel here (contrast [_emptyNodeRenderPlaceholder], which is a
/// stand-in *character* used only when the node is empty, not an offset
/// shift).
TextSpan buildAttributedTextSpan({
  required AttributedText text,
  required TextStyle style,
  required BuildContext context,
  TextRange? composingRange,
}) {
  if (text.text.isEmpty) {
    return TextSpan(text: _emptyNodeRenderPlaceholder, style: style);
  }

  final spans = text.spans;
  final validComposing =
      composingRange != null &&
      composingRange.isValid &&
      !composingRange.isCollapsed &&
      composingRange.start >= 0 &&
      composingRange.end <= text.text.length;

  if (spans.isEmpty && !validComposing) {
    return TextSpan(text: text.text, style: style);
  }

  // Collect every span boundary (plus the composing range's, if any) as a
  // cut point, so each run between two consecutive cut points is covered by
  // a constant set of attributions and a constant composing state.
  final cutPoints = <int>{0, text.text.length};
  for (final span in spans) {
    cutPoints.add(span.start);
    cutPoints.add(span.end);
  }
  if (validComposing) {
    cutPoints.add(composingRange.start);
    cutPoints.add(composingRange.end);
  }
  final sortedCuts = cutPoints.toList()..sort();

  final children = <TextSpan>[];
  for (var i = 0; i < sortedCuts.length - 1; i++) {
    final start = sortedCuts[i];
    final end = sortedCuts[i + 1];
    if (end <= start) continue;
    final covering = spans
        .where((s) => s.start <= start && s.end >= end)
        .map((s) => s.attribution);
    var runStyle = _mergeAttributionStyles(covering, context);
    if (validComposing &&
        start >= composingRange.start &&
        end <= composingRange.end) {
      runStyle = runStyle.merge(const TextStyle(decoration: TextDecoration.underline));
    }
    children.add(TextSpan(text: text.text.substring(start, end), style: runStyle));
  }

  return TextSpan(style: style, children: children);
}

TextStyle _mergeAttributionStyles(
  Iterable<Attribution> attributions,
  BuildContext context,
) {
  var style = const TextStyle();
  for (final a in attributions) {
    style = _applyAttribution(style, a, context);
  }
  return style;
}

TextStyle _applyAttribution(TextStyle style, Attribution a, BuildContext context) {
  switch (a.name) {
    case 'bold':
      return style.merge(const TextStyle(fontWeight: FontWeight.w700));
    case 'italic':
      return style.merge(const TextStyle(fontStyle: FontStyle.italic));
    case 'underline':
      // TextStyle has no property for the gap between text and its
      // underline — Skia draws it flush against descenders. Rendering the
      // glyphs as a shadow offset upward, with the real glyph color made
      // transparent, fakes the gap: the underline (painted separately, at
      // decorationColor) stays put while the visible "text" shifts up.
      final resolvedColor =
          style.color ??
          Theme.of(context).textTheme.bodyLarge?.color ??
          Theme.of(context).colorScheme.onSurface;
      return _addDecoration(style, TextDecoration.underline).merge(
        TextStyle(
          color: Colors.transparent,
          decorationColor: resolvedColor,
          shadows: [
            ...?style.shadows,
            Shadow(color: resolvedColor, offset: const Offset(0, -2)),
          ],
        ),
      );
    case 'strikethrough':
      return _addDecoration(style, TextDecoration.lineThrough);
    case 'code':
      return style.merge(
        TextStyle(
          fontFamily: 'monospace',
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      );
    case 'link':
      // A fixed blue rather than the theme's primary — links read as links
      // by convention regardless of the app's accent color.
      return style.merge(
        const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
      );
    case 'color':
      final color = _parseColor(a.value['hex']);
      return color == null ? style : style.merge(TextStyle(color: color));
    case 'backgroundColor':
      final color = _parseColor(a.value['hex']);
      return color == null ? style : style.merge(TextStyle(backgroundColor: color));
    case 'fontSize':
      final size = a.value['size'];
      if (size is num) return style.merge(TextStyle(fontSize: size.toDouble()));
      return style;
    case 'fontFamily':
      final family = a.value['family'];
      if (family is String) return style.merge(TextStyle(fontFamily: family));
      return style;
    case 'largeEmoji':
      // A fixed size, not a multiplier on the surrounding text: emoji picked
      // from the panel should read as content-sized regardless of the
      // line's own font size (headers, toggle content, etc).
      //
      // `height: 1.0` alongside it: color emoji fonts (Apple Color Emoji in
      // particular) report unusually tall natural line-height metrics
      // compared to the surrounding text face. Left at Flutter's default,
      // that extra built-in leading pushes the glyph off the shared
      // baseline the smaller surrounding text sits on. Pinning height to
      // 1.0 discards the font's own leading so the glyph sits directly on
      // the shared baseline like any other span.
      return style.merge(const TextStyle(fontSize: 22, height: 1.0));
    default:
      // Unknown attribution names are ignored, never thrown on.
      return style;
  }
}

TextStyle _addDecoration(TextStyle style, TextDecoration decoration) {
  final existing = style.decoration;
  return style.merge(
    TextStyle(
      decoration: existing == null
          ? decoration
          : TextDecoration.combine([existing, decoration]),
    ),
  );
}

Color? _parseColor(Object? hex) {
  if (hex is int) return Color(hex);
  if (hex is String) {
    var value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? null : Color(parsed);
  }
  return null;
}
