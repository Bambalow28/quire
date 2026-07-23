import 'dart:collection';

import 'nodes.dart';

/// The document: an ordered list of top-level nodes, plus (since a
/// [TableNode] nests block nodes inside its cells) an id index that also
/// covers nested nodes.
///
/// Positions elsewhere in this package address nodes by id, never by list
/// index — so this class is the only place list-index bookkeeping happens.
class MutableDocument {
  MutableDocument({List<DocumentNode>? nodes}) : _nodes = nodes ?? [] {
    _nodesView = UnmodifiableListView(_nodes);
    reindexNestedNodes();
  }

  final List<DocumentNode> _nodes;
  late final UnmodifiableListView<DocumentNode> _nodesView;
  final Map<String, DocumentNode> _idIndex = {};

  // Maps a node id to the actual growable list it currently lives in — the
  // top-level `_nodes`, or a [TableCell]'s `nodes` list. Insert/delete
  // resolve through this so a nested edit (e.g. splitting a paragraph inside
  // a table cell) mutates the right container without any caller needing to
  // know a table is involved.
  final Map<String, List<DocumentNode>> _containerOf = {};

  // A live view over _nodes (same backing list), so no cache invalidation
  // is needed when _nodes is mutated.
  List<DocumentNode> get nodes => _nodesView;

  bool get isEmpty => _nodes.isEmpty;
  DocumentNode get first => _nodes.first;
  DocumentNode get last => _nodes.last;

  DocumentNode? getNodeById(String id) => _idIndex[id];

  DocumentNode getNodeAt(int index) => nodesInDocumentOrder.elementAt(index);

  /// Every node in document order: top-level nodes in list order, with a
  /// [TableNode]'s cell nodes visited row-major, immediately after the
  /// table itself.
  Iterable<DocumentNode> get nodesInDocumentOrder sync* {
    for (final node in _nodes) {
      yield node;
      if (node is TableNode) {
        for (final row in node.rows) {
          for (final cell in row.cells) {
            yield* cell.nodes;
          }
        }
      }
    }
  }

  // ponytail: O(n) scan of nodesInDocumentOrder per lookup, add a cached
  // position map (invalidated on mutation) if profiling shows it matters.
  int getNodeIndexById(String id) {
    if (!_idIndex.containsKey(id)) return -1;
    var index = 0;
    for (final node in nodesInDocumentOrder) {
      if (node.id == id) return index;
      index++;
    }
    return -1;
  }

  DocumentNode? getNodeBefore(String id) {
    final index = getNodeIndexById(id);
    if (index <= 0) return null;
    return getNodeAt(index - 1);
  }

  DocumentNode? getNodeAfter(String id) {
    final index = getNodeIndexById(id);
    if (index < 0) return null;
    final ordered = nodesInDocumentOrder.toList();
    if (index >= ordered.length - 1) return null;
    return ordered[index + 1];
  }

  /// Inserts [node] at top-level list index [index]. Only meaningful for
  /// top-level nodes — nested nodes are always inserted relative to a
  /// sibling id via [insertNodeAfter]/[insertNodeBefore].
  void insertNodeAt(int index, DocumentNode node) {
    _nodes.insert(index, node);
    _indexNode(node, _nodes);
  }

  void insertNodeAfter(String nodeId, DocumentNode node) {
    final container = _containerOf[nodeId];
    if (container == null) throw ArgumentError('No node with id $nodeId');
    final index = container.indexWhere((n) => n.id == nodeId);
    if (index < 0) throw ArgumentError('No node with id $nodeId');
    container.insert(index + 1, node);
    _indexNode(node, container);
  }

  /// Inserts [node] immediately before [nodeId], in whichever list (top
  /// level or a table cell) currently holds it.
  void insertNodeBefore(String nodeId, DocumentNode node) {
    final container = _containerOf[nodeId];
    if (container == null) throw ArgumentError('No node with id $nodeId');
    final index = container.indexWhere((n) => n.id == nodeId);
    if (index < 0) throw ArgumentError('No node with id $nodeId');
    container.insert(index, node);
    _indexNode(node, container);
  }

  void deleteNode(String nodeId) {
    final container = _containerOf[nodeId];
    if (container == null) return;
    final index = container.indexWhere((n) => n.id == nodeId);
    if (index < 0) return;
    final node = container.removeAt(index);
    _unindexNode(node);
  }

  /// Replaces the entire top-level node list in place (id index rebuilt).
  /// Used by history restoration — still only reachable through the Editor
  /// funnel, via a command.
  void replaceAllNodes(List<DocumentNode> newNodes) {
    _nodes
      ..clear()
      ..addAll(newNodes);
    reindexNestedNodes();
  }

  /// Rebuilds the id/container index from scratch, walking every top-level
  /// node's nested content. Call after mutating a [TableNode]'s [TableRow]s
  /// directly (row/column insert-delete, cell merge/split) — those change
  /// which nodes are nested without going through
  /// [insertNodeAfter]/[insertNodeBefore]/[deleteNode].
  void reindexNestedNodes() {
    _idIndex.clear();
    _containerOf.clear();
    for (final node in _nodes) {
      _indexNode(node, _nodes);
    }
  }

  void _indexNode(DocumentNode node, List<DocumentNode> container) {
    _idIndex[node.id] = node;
    _containerOf[node.id] = container;
    if (node is TableNode) {
      for (final row in node.rows) {
        for (final cell in row.cells) {
          for (final n in cell.nodes) {
            _indexNode(n, cell.nodes);
          }
        }
      }
    }
  }

  void _unindexNode(DocumentNode node) {
    _idIndex.remove(node.id);
    _containerOf.remove(node.id);
    if (node is TableNode) {
      for (final row in node.rows) {
        for (final cell in row.cells) {
          for (final n in cell.nodes) {
            _unindexNode(n);
          }
        }
      }
    }
  }

  Map<String, Object?> toJson() => {
    'nodes': _nodes.map((n) => n.toJson()).toList(),
  };

  factory MutableDocument.fromJson(Map<String, Object?> json) =>
      MutableDocument(
        nodes: (json['nodes'] as List)
            .map((n) => nodeFromJson(n as Map<String, Object?>))
            .toList(),
      );
}
