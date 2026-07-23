import 'dart:collection';

import 'nodes.dart';

/// The document: an ordered list of nodes plus an id index kept in sync.
///
/// Positions elsewhere in this package address nodes by id, never by list
/// index — so this class is the only place list-index bookkeeping happens.
class MutableDocument {
  MutableDocument({List<DocumentNode>? nodes}) : _nodes = nodes ?? [] {
    _nodesView = UnmodifiableListView(_nodes);
    for (final n in _nodes) {
      _idIndex[n.id] = n;
    }
  }

  final List<DocumentNode> _nodes;
  late final UnmodifiableListView<DocumentNode> _nodesView;
  final Map<String, DocumentNode> _idIndex = {};

  // A live view over _nodes (same backing list), so no cache invalidation
  // is needed when _nodes is mutated.
  List<DocumentNode> get nodes => _nodesView;

  bool get isEmpty => _nodes.isEmpty;
  DocumentNode get first => _nodes.first;
  DocumentNode get last => _nodes.last;

  DocumentNode? getNodeById(String id) => _idIndex[id];

  DocumentNode getNodeAt(int index) => _nodes[index];

  // ponytail: O(n) index lookup, add an id→index map if profiling shows it
  // matters.
  int getNodeIndexById(String id) {
    final node = _idIndex[id];
    if (node == null) return -1;
    return _nodes.indexWhere((n) => identical(n, node));
  }

  DocumentNode? getNodeBefore(String id) {
    final index = getNodeIndexById(id);
    if (index <= 0) return null;
    return _nodes[index - 1];
  }

  DocumentNode? getNodeAfter(String id) {
    final index = getNodeIndexById(id);
    if (index < 0 || index >= _nodes.length - 1) return null;
    return _nodes[index + 1];
  }

  void insertNodeAt(int index, DocumentNode node) {
    _nodes.insert(index, node);
    _idIndex[node.id] = node;
  }

  void insertNodeAfter(String nodeId, DocumentNode node) {
    final index = getNodeIndexById(nodeId);
    if (index < 0) throw ArgumentError('No node with id $nodeId');
    insertNodeAt(index + 1, node);
  }

  void deleteNode(String nodeId) {
    final index = getNodeIndexById(nodeId);
    if (index < 0) return;
    _nodes.removeAt(index);
    _idIndex.remove(nodeId);
  }

  /// Replaces the entire node list in place (id index rebuilt). Used by
  /// history restoration — still only reachable through the Editor funnel,
  /// via a command.
  void replaceAllNodes(List<DocumentNode> newNodes) {
    _nodes
      ..clear()
      ..addAll(newNodes);
    _idIndex
      ..clear()
      ..addEntries(newNodes.map((n) => MapEntry(n.id, n)));
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
