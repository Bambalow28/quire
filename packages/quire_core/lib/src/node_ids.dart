int _idCounter = 0;

/// Generates a fresh, process-unique node id.
// ponytail: counter-based id, swap for uuid if documents are ever merged
// across processes (e.g. collaborative editing).
String generateNodeId() => 'node-${_idCounter++}';
