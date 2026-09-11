import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

/// The single leading character every node's field carries so that a soft
/// keyboard always has something to delete at offset 0 — see
/// `_fieldTextFor` in quire_editor.dart for why it exists at all.
///
/// It is a real space, not a zero-width space, on purpose: iOS/Android apply
/// their `TextCapitalization.sentences` auto-shift by looking at the
/// characters before the caret, and a zero-width space reads to them as a
/// word character, which is what used to kill the keyboard's shift-on at the
/// start of a paragraph. A leading space still reads as "start of sentence",
/// so the keyboard shifts by itself and the user can unshift if they want
/// lowercase — exactly how a plain TextField behaves. [NodeTextController]
/// paints it at effectively zero width so it never shows up as an indent.
const kEmptyNodeSentinel = ' ';

/// Style that renders [kEmptyNodeSentinel] invisibly. The line keeps its
/// full height regardless: EditableText forces its strut from the widget's
/// own style, not from the spans.
const _sentinelStyle = TextStyle(fontSize: 0.01, letterSpacing: 0);

/// A [TextEditingController] for a single [TextNode]'s [AttributedText].
///
/// Holds the node id and the current [AttributedText], and renders
/// attribution spans as real [TextStyle]s in [buildTextSpan].
class NodeTextController extends TextEditingController {
  NodeTextController({required this.nodeId, required AttributedText text})
    : _attributedText = text,
      super(text: text.text);

  final String nodeId;
  AttributedText _attributedText;

  AttributedText get attributedText => _attributedText;

  /// Updates the underlying [AttributedText] without touching [value] (the
  /// caller is responsible for keeping `text`/`selection` in sync).
  void setAttributedText(AttributedText text) {
    _attributedText = text;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // The field's text carries a leading sentinel the model doesn't have
    // (see [kEmptyNodeSentinel]); it is painted, invisibly, as its own span
    // so the built TextSpan's plain text still matches `value.text` exactly —
    // EditableText requires that, and every offset past it would otherwise be
    // one character out.
    final sentinel = text.startsWith(kEmptyNodeSentinel)
        ? const TextSpan(text: kEmptyNodeSentinel, style: _sentinelStyle)
        : null;

    final spans = _attributedText.spans;
    if (spans.isEmpty || _attributedText.text.isEmpty) {
      // Render the field's own text (`text`, from the base
      // TextEditingController), not the model's — they can diverge by the
      // sentinel.
      final body = sentinel == null
          ? text
          : text.substring(kEmptyNodeSentinel.length);
      return TextSpan(
        style: style,
        children: [if (sentinel != null) sentinel, TextSpan(text: body)],
      );
    }

    // Collect every span boundary as a cut point, so each run between two
    // consecutive cut points is covered by a constant set of attributions.
    final cutPoints = <int>{0, _attributedText.text.length};
    for (final span in spans) {
      cutPoints.add(span.start);
      cutPoints.add(span.end);
    }
    final sortedCuts = cutPoints.toList()..sort();

    final children = <TextSpan>[if (sentinel != null) sentinel];
    for (var i = 0; i < sortedCuts.length - 1; i++) {
      final start = sortedCuts[i];
      final end = sortedCuts[i + 1];
      if (end <= start) continue;
      final covering = spans
          .where((s) => s.start <= start && s.end >= end)
          .map((s) => s.attribution);
      children.add(
        TextSpan(
          text: _attributedText.text.substring(start, end),
          style: _mergeAttributionStyles(covering, context),
        ),
      );
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

  TextStyle _applyAttribution(
    TextStyle style,
    Attribution a,
    BuildContext context,
  ) {
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
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
          ),
        );
      case 'link':
        // A fixed blue rather than the theme's primary — links read as
        // links by convention regardless of the app's accent color.
        return style.merge(
          const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
        );
      case 'color':
        final color = _parseColor(a.value['hex']);
        return color == null ? style : style.merge(TextStyle(color: color));
      case 'backgroundColor':
        final color = _parseColor(a.value['hex']);
        return color == null
            ? style
            : style.merge(TextStyle(backgroundColor: color));
      case 'fontSize':
        final size = a.value['size'];
        if (size is num) {
          return style.merge(TextStyle(fontSize: size.toDouble()));
        }
        return style;
      case 'fontFamily':
        final family = a.value['family'];
        if (family is String) {
          return style.merge(TextStyle(fontFamily: family));
        }
        return style;
      case 'largeEmoji':
        // A fixed size, not a multiplier on the surrounding text: emoji
        // picked from the panel should read as content-sized regardless of
        // the line's own font size (headers, toggle content, etc).
        //
        // `height: 1.0` alongside it: color emoji fonts (Apple Color Emoji
        // in particular) report unusually tall natural line-height metrics
        // compared to the surrounding text face. Left at Flutter's default
        // (no explicit height — each span uses its own font's natural
        // metrics), that extra built-in leading pushes the glyph off the
        // shared baseline the smaller surrounding text sits on, reading as
        // "hanging" above/below center rather than lined up with it.
        // Pinning height to 1.0 discards the font's own leading so the glyph
        // sits directly on the shared baseline like any other span.
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
}
