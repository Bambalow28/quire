import 'commands.dart';
import 'editor.dart';
import 'nodes.dart';
import 'selection.dart';

/// Restores the document and selection to a prior snapshot. Only issued
/// internally by [EditHistory.undo]/[EditHistory.redo], but still flows through the
/// normal [Editor.execute] funnel so listeners are notified as usual.
class RestoreSnapshotRequest extends EditRequest {
  RestoreSnapshotRequest(this.documentJson, this.selectionJson);
  final Map<String, Object?> documentJson;
  final Map<String, Object?>? selectionJson;
}

class _RestoreSnapshotCommand extends EditCommand {
  _RestoreSnapshotCommand(this.request);
  final RestoreSnapshotRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final nodes = (request.documentJson['nodes'] as List)
        .map((n) => nodeFromJson(n as Map<String, Object?>))
        .toList();
    context.document.replaceAllNodes(nodes);
    context.composer.selection = request.selectionJson == null
        ? null
        : DocumentSelection.fromJson(request.selectionJson!);
    executor.emit(DocumentEdited(nodes.map((n) => n.id).toList()));
    executor.emit(SelectionChanged());
  }
}

EditCommand? historyRequestHandler(EditRequest request) =>
    request is RestoreSnapshotRequest ? _RestoreSnapshotCommand(request) : null;

typedef _Snapshot = ({Map<String, Object?> doc, Map<String, Object?>? sel});

// ponytail: full-document snapshots, switch to inverse commands if memory
// hurts on large docs.

/// Undo/redo via document snapshots, listening on an [Editor].
///
/// Once history is in use, call [EditHistory.execute] instead of
/// `editor.execute(...)` directly — it snapshots before delegating, so
/// [undo]/[redo] stay correct.
class EditHistory implements EditListener {
  EditHistory(this.editor, {this.maxEntries = 200}) {
    editor.addListener(this);
  }

  final Editor editor;
  final int maxEntries;

  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];

  // Tracks a run of contiguous single-character InsertTextRequests so they
  // coalesce into one undo step.
  String? _streakNodeId;
  int? _streakNextOffset;

  // Set while this instance is itself driving an `editor.execute` call, so
  // `onEdit` can tell "an edit I recorded" from "an edit that reached the
  // editor some other way" (e.g. a bare `editor.execute([ChangeSelectionRequest(...)])`
  // that bypassed `execute` and so never broke the streak in `_record`).
  bool _inOwnExecute = false;

  /// Any edit that didn't go through [execute] (and so wasn't seen by
  /// [_record]) invalidates a pending coalescing streak — otherwise a
  /// selection change that lands back at the same offset could let two
  /// unrelated typing sessions merge into one undo step.
  @override
  void onEdit(List<EditEvent> events) {
    if (_inOwnExecute) return;
    _streakNodeId = null;
    _streakNextOffset = null;
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  int get undoCount => _undoStack.length;

  /// Snapshots state as it was before [requests], then runs them through
  /// [editor]. Use this instead of calling `editor.execute` directly.
  void execute(List<EditRequest> requests) {
    _record(requests);
    _inOwnExecute = true;
    try {
      editor.execute(requests);
    } finally {
      _inOwnExecute = false;
    }
  }

  void _record(List<EditRequest> requests) {
    final key = _singleCharInsertKey(requests);
    final continuesStreak =
        key != null &&
        _streakNodeId == key.$1 &&
        _streakNextOffset == key.$2 &&
        _undoStack.isNotEmpty;

    if (!continuesStreak) {
      _undoStack.add(_snapshot());
      if (_undoStack.length > maxEntries) _undoStack.removeAt(0);
    }

    if (key != null) {
      _streakNodeId = key.$1;
      _streakNextOffset = key.$2 + 1;
    } else {
      _streakNodeId = null;
      _streakNextOffset = null;
    }
    _redoStack.clear();
  }

  _Snapshot _snapshot() => (
    doc: editor.context.document.toJson(),
    sel: editor.context.composer.selection?.toJson(),
  );

  (String, int)? _singleCharInsertKey(List<EditRequest> requests) {
    if (requests.length != 1) return null;
    final request = requests.single;
    if (request is! InsertTextRequest || request.text.length != 1) return null;
    final position = request.position.nodePosition;
    if (position is! TextNodePosition) return null;
    return (request.position.nodeId, position.offset);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _streakNodeId = null;
    _streakNextOffset = null;
    final current = _snapshot();
    final target = _undoStack.removeLast();
    _redoStack.add(current);
    editor.execute([RestoreSnapshotRequest(target.doc, target.sel)]);
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _streakNodeId = null;
    _streakNextOffset = null;
    final current = _snapshot();
    final target = _redoStack.removeLast();
    _undoStack.add(current);
    editor.execute([RestoreSnapshotRequest(target.doc, target.sel)]);
  }
}
