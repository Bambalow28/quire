import 'dart:convert';

import 'attributed_text.dart';
import 'document.dart';
import 'node_ids.dart';
import 'nodes.dart';

/// The schema version [MutableDocument.toJson] writes. Bump when a change to
/// the JSON shape is not readable by older builds.
const int documentSchemaVersion = 1;

/// What [loadDocument] made of its input.
class LoadResult {
  LoadResult(this.document, this.repairs, {required this.fromNewerVersion});

  final MutableDocument document;

  /// Human-readable notes on anything that had to be fixed; empty if the
  /// input was already sound.
  final List<String> repairs;

  /// The JSON was written by a newer schema than this build understands.
  /// Callers should treat the document as read-only: saving would downgrade
  /// it and could drop data this build cannot see.
  final bool fromNewerVersion;
}

/// Builds a document from stored JSON without ever throwing. Anything it can
/// not make sense of is repaired or preserved, never silently lost:
/// unreadable nodes are kept as [UnknownNode]s, duplicate ids are reissued,
/// empty table cells get a paragraph, and an empty document gets one too.
LoadResult loadDocument(Object? input) {
  final repairs = <String>[];
  // Round-trip through JSON text so every nested map has the exact
  // Map<String, dynamic> type the fromJson factories cast to, whatever
  // produced [input] (a decoded string, a database row, a hand-built map).
  Object? json;
  try {
    json = jsonDecode(jsonEncode(input));
  } catch (_) {
    repairs.add('document is not JSON-encodable');
  }
  var newer = false;
  final nodes = <DocumentNode>[];

  if (json is Map) {
    final version = json['version'];
    if (version is int && version > documentSchemaVersion) newer = true;
    final rawNodes = json['nodes'];
    if (rawNodes is List) {
      for (final raw in rawNodes) {
        final node = _loadNode(raw, repairs);
        if (node != null) nodes.add(node);
      }
    } else {
      repairs.add('document has no node list');
    }
  } else {
    repairs.add('document is not a JSON object');
  }

  final seen = <String>{};
  for (final node in nodes) {
    _repairNode(node, seen, repairs);
  }
  if (nodes.isEmpty) {
    nodes.add(TextNode(id: generateNodeId(), text: AttributedText('')));
    repairs.add('empty document given a paragraph');
  }
  return LoadResult(
    MutableDocument(nodes: nodes),
    repairs,
    fromNewerVersion: newer,
  );
}

DocumentNode? _loadNode(Object? raw, List<String> repairs) {
  if (raw is! Map) {
    repairs.add('dropped a node that is not an object');
    return null;
  }
  final map = Map<String, Object?>.from(raw);
  try {
    return nodeFromJson(map);
  } catch (_) {
    repairs.add('kept an unreadable node as-is');
    final id = map['id'];
    return UnknownNode(id: id is String ? id : generateNodeId(), raw: map);
  }
}

void _repairNode(DocumentNode node, Set<String> seen, List<String> repairs) {
  if (!seen.add(node.id)) {
    final fresh = generateNodeId();
    repairs.add('duplicate id ${node.id} reissued as $fresh');
    node.id = fresh;
    if (node is UnknownNode) node.raw['id'] = fresh;
    seen.add(fresh);
  }
  if (node is! TableNode) return;
  if (node.rows.isEmpty) {
    node.rows = [
      TableRow(cells: [TableCell(nodes: [])]),
    ];
    repairs.add('table ${node.id} had no rows');
  }
  for (final row in node.rows) {
    for (final cell in row.cells) {
      if (cell.rowSpan < 1) cell.rowSpan = 1;
      if (cell.colSpan < 1) cell.colSpan = 1;
      if (cell.nodes.isEmpty) {
        cell.nodes.add(
          TextNode(id: generateNodeId(), text: AttributedText('')),
        );
        repairs.add('table ${node.id}: empty cell given a paragraph');
      }
      for (final inner in cell.nodes) {
        _repairNode(inner, seen, repairs);
      }
    }
  }
}
