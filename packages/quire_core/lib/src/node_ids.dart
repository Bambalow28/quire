import 'dart:math';

final Random _random = Random();
int _idCounter = 0;

/// Generates a fresh node id, unique across processes.
///
/// Documents are persisted and reloaded across app restarts, so a plain
/// per-process counter (the old `node-0`, `node-1`, ...) reliably collides
/// with ids already saved in a reopened document as soon as any session
/// creates the same number of nodes as a prior one. Two nodes sharing an id
/// then share editor state (controller, focus node, GlobalKey), which is
/// what made an existing item vanish and its checkbox stop responding.
String generateNodeId() => 'node-${_random.nextInt(1 << 32)}-${_idCounter++}';
