import 'package:flutter/material.dart';
import 'package:quire_core/quire_core.dart';

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
    final spans = _attributedText.spans;
    if (spans.isEmpty || _attributedText.text.isEmpty) {
      // Render the field's own text (`text`, from the base
      // TextEditingController), not the model's — they can diverge by the
      // empty-node zero-width-space sentinel the editor uses for
      // soft-keyboard backspace (see quire_editor.dart), and EditableText
      // requires the built TextSpan's plain text to match `value.text`
      // exactly.
      return TextSpan(style: style, text: text);
    }

    // Collect every span boundary as a cut point, so each run between two
    // consecutive cut points is covered by a constant set of attributions.
    final cutPoints = <int>{0, _attributedText.text.length};
    for (final span in spans) {
      cutPoints.add(span.start);
      cutPoints.add(span.end);
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
        return _addDecoration(style, TextDecoration.underline);
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
        return style.merge(const TextStyle(fontSize: 28));
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
