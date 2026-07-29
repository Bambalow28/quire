import 'nodes.dart';

/// In-memory "internal clipboard": alongside the plain text written to the
/// OS clipboard, stashes the rich [TextNode]s that were actually selected so
/// an in-app paste can restore formatting/block types. Keyed off the plain
/// text so a paste can tell whether the OS clipboard still holds what was
/// last copied from Quire (same-app round trip) or something else entirely
/// (copied elsewhere since, or in another app) — in which case the rich
/// content is stale and must not be used.
class QuireClipboard {
  QuireClipboard._();

  static final QuireClipboard instance = QuireClipboard._();

  String? _plainText;
  List<TextNode>? _nodes;

  void store(String plainText, List<TextNode> nodes) {
    _plainText = plainText;
    _nodes = nodes;
  }

  /// The rich nodes stored at copy time, if [plainText] still matches that
  /// copy's snapshot — `null` otherwise (nothing copied yet, or the OS
  /// clipboard has since changed).
  List<TextNode>? richNodesFor(String plainText) =>
      _plainText == plainText ? _nodes : null;
}
