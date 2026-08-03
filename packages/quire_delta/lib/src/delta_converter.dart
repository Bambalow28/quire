import 'dart:convert';

import 'package:quire_core/quire_core.dart';

/// Converts a Quill Delta document (the JSON `List` of ops that
/// `flutter_quill` saves) into a [MutableDocument].
///
/// Never throws on malformed *ops* — a bad op is skipped and the rest of the
/// document still converts. It only throws if [delta] itself is not the
/// shape a Delta is supposed to be (see [deltaToQuireOrNull] for a
/// non-throwing wrapper around the whole call).
MutableDocument deltaToQuire(List<dynamic> delta) {
  final nodes = <DocumentNode>[];
  var pending = <_Segment>[];

  void flushLine(Map<String, Object?> blockAttrs) {
    if (pending.isEmpty) {
      nodes.add(_emptyTextNode(blockAttrs));
      return;
    }
    var run = <_TextSegment>[];
    for (final seg in pending) {
      if (seg is _TextSegment) {
        run.add(seg);
        continue;
      }
      if (run.isNotEmpty) {
        nodes.add(_buildTextNode(run, blockAttrs));
        run = [];
      }
      nodes.add(_buildEmbedNode(seg as _EmbedSegment));
    }
    if (run.isNotEmpty) {
      nodes.add(_buildTextNode(run, blockAttrs));
    }
    pending = [];
  }

  for (final rawOp in delta) {
    if (rawOp is! Map) continue;
    if (!rawOp.containsKey('insert')) continue;
    final insertVal = rawOp['insert'];
    final attrsRaw = rawOp['attributes'];
    // Attributes that aren't a map are dropped, but the op's *text* is still
    // kept — losing a paragraph because its formatting was corrupt would be
    // a far worse outcome than losing the formatting.
    final attrs = attrsRaw is Map
        ? attrsRaw.map((k, v) => MapEntry(k.toString(), v))
        : const <String, Object?>{};

    if (insertVal is String) {
      if (insertVal.isEmpty) continue;
      final inlineAttrs = _parseInlineAttributions(attrs);
      var start = 0;
      while (true) {
        final idx = insertVal.indexOf('\n', start);
        if (idx == -1) {
          final remainder = insertVal.substring(start);
          if (remainder.isNotEmpty) {
            pending.add(_TextSegment(remainder, inlineAttrs));
          }
          break;
        }
        final lineText = insertVal.substring(start, idx);
        if (lineText.isNotEmpty) {
          pending.add(_TextSegment(lineText, inlineAttrs));
        }
        flushLine(attrs);
        start = idx + 1;
      }
    } else if (insertVal is Map) {
      pending.add(
        _EmbedSegment(
          insertVal.map((k, v) => MapEntry(k.toString(), v)),
          attrs,
        ),
      );
    } else {
      continue;
    }
  }

  if (pending.isNotEmpty) {
    flushLine(const {});
  }

  if (nodes.isEmpty) {
    nodes.add(_emptyTextNode(const {}));
  }

  return MutableDocument(nodes: nodes);
}

/// Convenience: parses [json] as a Delta ops list, then [deltaToQuire].
/// Throws if [json] does not decode to a JSON list.
MutableDocument deltaJsonToQuire(String json) =>
    deltaToQuire(jsonDecode(json) as List<dynamic>);

/// Same as [deltaToQuire] but returns `null` instead of throwing, so a
/// caller can fall back to keeping the original note untouched.
MutableDocument? deltaToQuireOrNull(List<dynamic> delta) {
  try {
    return deltaToQuire(delta);
  } catch (_) {
    return null;
  }
}

/// Flattens a Quire document's own JSON (i.e. `MutableDocument.toJson()`
/// re-encoded) into plain text — one line per [TextNode] — for list
/// previews/search. Non-text nodes (images, tables) contribute no text of
/// their own.
String plainTextOfQuireJson(String json) {
  final doc = MutableDocument.fromJson(
    jsonDecode(json) as Map<String, Object?>,
  );
  final buffer = StringBuffer();
  for (final node in doc.nodesInDocumentOrder) {
    if (node is TextNode) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(node.text.text);
    }
  }
  return buffer.toString();
}

abstract class _Segment {}

class _TextSegment extends _Segment {
  _TextSegment(this.text, this.attributions);
  final String text;
  final Set<Attribution> attributions;
}

class _EmbedSegment extends _Segment {
  _EmbedSegment(this.data, this.attrs);
  final Map<String, Object?> data;
  final Map<String, Object?> attrs;
}

TextNode _emptyTextNode(Map<String, Object?> blockAttrs) => TextNode(
  id: generateNodeId(),
  text: AttributedText(''),
  metadata: _blockMetadata(blockAttrs),
);

TextNode _buildTextNode(
  List<_TextSegment> run,
  Map<String, Object?> blockAttrs,
) {
  final buffer = StringBuffer();
  final spans = <AttributionSpan>[];
  var offset = 0;
  for (final seg in run) {
    for (final a in seg.attributions) {
      spans.add(AttributionSpan(a, offset, offset + seg.text.length));
    }
    buffer.write(seg.text);
    offset += seg.text.length;
  }
  return TextNode(
    id: generateNodeId(),
    text: AttributedText(buffer.toString(), spans),
    metadata: _blockMetadata(blockAttrs),
  );
}

DocumentNode _buildEmbedNode(_EmbedSegment seg) {
  final data = seg.data;
  if (data.containsKey('divider')) {
    return HorizontalRuleNode(id: generateNodeId());
  }
  if (data.containsKey('image')) {
    final alt = seg.attrs['alt'];
    return ImageNode(
      id: generateNodeId(),
      url: _stringify(data['image']),
      altText: alt is String ? alt : null,
    );
  }
  if (data.containsKey('video')) {
    final url = _stringify(data['video']);
    return TextNode(
      id: generateNodeId(),
      text: AttributedText(url, [
        AttributionSpan(
          Attribution('link', value: {'url': url}),
          0,
          url.length,
        ),
      ]),
    );
  }
  if (data.containsKey('table')) {
    return _buildTableNode(data['table']);
  }
  // Unknown embed type: preserve as plain text rather than drop it.
  return TextNode(id: generateNodeId(), text: AttributedText(jsonEncode(data)));
}

DocumentNode _buildTableNode(Object? payload) {
  try {
    if (payload is! String) throw const FormatException('not a string');
    final decoded = jsonDecode(payload);
    if (decoded is! Map) throw const FormatException('not an object');
    final cellsRaw = decoded['cells'];
    if (cellsRaw is! List || cellsRaw.isEmpty) {
      throw const FormatException('no cells');
    }
    // Legacy tables can be ragged (a short row). Pad every row to the widest
    // one, so the grid has no holes for the renderer to leave unbordered.
    final width = cellsRaw.whereType<List>().fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final rows = <TableRow>[];
    for (final rowRaw in cellsRaw) {
      if (rowRaw is! List) throw const FormatException('row not a list');
      final cells = <TableCell>[];
      for (final cellRaw in [
        ...rowRaw,
        ...List.filled(width - rowRaw.length, ''),
      ]) {
        cells.add(
          TableCell(
            nodes: [
              TextNode(
                id: generateNodeId(),
                text: AttributedText(_cellText(cellRaw)),
              ),
            ],
          ),
        );
      }
      rows.add(TableRow(cells: cells));
    }
    return TableNode(id: generateNodeId(), rows: rows);
  } catch (_) {
    // Corrupt payload: never drop the content, fall back to plain text.
    final flat = payload is String ? payload : jsonEncode(payload);
    return TextNode(id: generateNodeId(), text: AttributedText(flat));
  }
}

String _stringify(Object? v) => v is String ? v : jsonEncode(v);

/// Extracts plain text from a table cell's raw value. Cells are normally
/// plain strings, but some quill forks store a nested delta (a `List` of
/// `{'insert': ...}` ops, or a bare `{'insert': ...}` map) instead — walk
/// those for their text rather than falling through to `toString()`, which
/// would leak Dart's `{insert: text}` object syntax into the note.
String _cellText(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is Map && v['insert'] is String) return v['insert'] as String;
  if (v is List) {
    final buffer = StringBuffer();
    for (final op in v) {
      if (op is Map && op['insert'] is String) buffer.write(op['insert']);
    }
    return buffer.toString();
  }
  return v.toString();
}

Set<Attribution> _parseInlineAttributions(Map<String, Object?> attrs) {
  final result = <Attribution>{};
  for (final entry in attrs.entries) {
    final value = entry.value;
    switch (entry.key) {
      case 'bold':
        if (value == true) result.add(const Attribution('bold'));
      case 'italic':
        if (value == true) result.add(const Attribution('italic'));
      case 'underline':
        if (value == true) result.add(const Attribution('underline'));
      case 'strike':
        if (value == true) result.add(const Attribution('strikethrough'));
      case 'code':
        if (value == true) result.add(const Attribution('code'));
      case 'link':
        if (value is String) {
          result.add(Attribution('link', value: {'url': value}));
        }
      case 'color':
        if (value is String) {
          result.add(Attribution('color', value: {'hex': value}));
        }
      case 'background':
        if (value is String) {
          result.add(Attribution('backgroundColor', value: {'hex': value}));
        }
      case 'font':
        if (value is String) {
          result.add(Attribution('fontFamily', value: {'family': value}));
        }
      case 'size':
        final size = value is num
            ? value.toDouble()
            : double.tryParse('$value');
        if (size != null) {
          result.add(Attribution('fontSize', value: {'size': size}));
        }
      default:
        // Unknown inline attribute: ignore, keep the text.
        break;
    }
  }
  return result;
}

Map<String, Object?> _blockMetadata(Map<String, Object?> attrs) {
  final metadata = <String, Object?>{};

  final header = attrs['header'];
  final list = attrs['list'];
  if (header is num && header >= 1 && header <= 6) {
    metadata['blockType'] = 'header${header.toInt()}';
  } else if (list == 'ordered') {
    metadata['blockType'] = 'listItemOrdered';
  } else if (list == 'bullet') {
    metadata['blockType'] = 'listItemUnordered';
  } else if (list == 'checked') {
    metadata['blockType'] = 'listItemTask';
    metadata['checked'] = true;
  } else if (list == 'unchecked') {
    metadata['blockType'] = 'listItemTask';
    metadata['checked'] = false;
  } else if (attrs['blockquote'] == true) {
    metadata['blockType'] = 'blockquote';
  } else if (attrs['code-block'] == true) {
    metadata['blockType'] = 'code';
  }

  final indent = attrs['indent'];
  if (indent is num) metadata['indent'] = indent.toInt();

  final align = attrs['align'];
  if (align is String) metadata['textAlign'] = align;

  return metadata;
}
