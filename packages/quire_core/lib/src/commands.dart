import 'attributed_text.dart';
import 'editor.dart';
import 'nodes.dart';
import 'selection.dart';

int _idCounter = 0;

/// Generates a fresh, process-unique node id.
// ponytail: counter-based id, swap for uuid if documents are ever merged
// across processes (e.g. collaborative editing).
String generateNodeId() => 'node-${_idCounter++}';

AttributedText _concatText(AttributedText a, AttributedText b) {
  final offset = a.text.length;
  return AttributedText(a.text + b.text, [
    ...a.spans,
    ...b.spans.map(
      (s) => s.copyWith(start: s.start + offset, end: s.end + offset),
    ),
  ]);
}

DocumentPosition _startOf(DocumentNode node) => DocumentPosition(
  node.id,
  node is TextNode
      ? const TextNodePosition(0)
      : const UpstreamDownstreamNodePosition.upstream(),
);

DocumentPosition _endOf(DocumentNode node) => DocumentPosition(
  node.id,
  node is TextNode
      ? TextNodePosition(node.text.text.length)
      : const UpstreamDownstreamNodePosition.downstream(),
);

// --- InsertTextRequest ------------------------------------------------

class InsertTextRequest extends EditRequest {
  InsertTextRequest(this.position, this.text, [this.attributions]);
  final DocumentPosition position;
  final String text;

  /// `null` means "use the composer's current `composingAttributions`";
  /// pass an explicit empty set for unstyled text.
  final Set<Attribution>? attributions;
}

class _InsertTextCommand extends EditCommand {
  _InsertTextCommand(this.request);
  final InsertTextRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final node = context.document.getNodeById(request.position.nodeId);
    if (node is! TextNode) return;
    final offset = (request.position.nodePosition as TextNodePosition).offset;
    node.text = node.text.insert(
      offset,
      request.text,
      attributions:
          request.attributions ?? context.composer.composingAttributions,
    );
    context.composer.selection = DocumentSelection.collapsed(
      DocumentPosition(node.id, TextNodePosition(offset + request.text.length)),
    );
    executor.emit(DocumentEdited([node.id]));
    executor.emit(SelectionChanged());
  }
}

// --- DeleteSelectionRequest --------------------------------------------

class DeleteSelectionRequest extends EditRequest {}

class _DeleteSelectionCommand extends EditCommand {
  @override
  void execute(EditContext context, CommandExecutor executor) {
    final selection = context.composer.selection;
    if (selection == null || selection.isCollapsed) return;
    final document = context.document;
    final (startPos, endPos) = selection.normalize(document);
    final startIndex = document.getNodeIndexById(startPos.nodeId);
    final endIndex = document.getNodeIndexById(endPos.nodeId);
    final beforeStart = startIndex > 0
        ? document.getNodeAt(startIndex - 1)
        : null;
    final afterEnd = endIndex < document.nodes.length - 1
        ? document.getNodeAt(endIndex + 1)
        : null;
    final changedIds = <String>{};

    for (var i = endIndex - 1; i > startIndex; i--) {
      final id = document.getNodeAt(i).id;
      document.deleteNode(id);
      changedIds.add(id);
    }

    final startNode = document.getNodeById(startPos.nodeId)!;
    final endNode = document.getNodeById(endPos.nodeId)!;

    if (startPos.nodeId == endPos.nodeId) {
      if (startNode is TextNode) {
        final start = (startPos.nodePosition as TextNodePosition).offset;
        final end = (endPos.nodePosition as TextNodePosition).offset;
        startNode.text = startNode.text.remove(start, end);
        changedIds.add(startNode.id);
        context.composer.selection = DocumentSelection.collapsed(
          DocumentPosition(startNode.id, TextNodePosition(start)),
        );
      } else {
        document.deleteNode(startNode.id);
        changedIds.add(startNode.id);
        final landing = beforeStart != null
            ? _endOf(beforeStart)
            : (afterEnd != null ? _startOf(afterEnd) : null);
        if (landing != null) {
          context.composer.selection = DocumentSelection.collapsed(landing);
        }
      }
    } else {
      final startPrefix = startNode is TextNode
          ? startNode.text.copyRange(
              0,
              (startPos.nodePosition as TextNodePosition).offset,
            )
          : null;
      final endSuffix = endNode is TextNode
          ? endNode.text.copyRange(
              (endPos.nodePosition as TextNodePosition).offset,
              endNode.text.text.length,
            )
          : null;

      if (startNode is TextNode && endNode is TextNode) {
        final caretOffset = startPrefix!.text.length;
        startNode.text = _concatText(startPrefix, endSuffix!);
        changedIds.add(startNode.id);
        document.deleteNode(endNode.id);
        changedIds.add(endNode.id);
        context.composer.selection = DocumentSelection.collapsed(
          DocumentPosition(startNode.id, TextNodePosition(caretOffset)),
        );
      } else if (startNode is TextNode) {
        startNode.text = startPrefix!;
        changedIds.add(startNode.id);
        document.deleteNode(endNode.id);
        changedIds.add(endNode.id);
        context.composer.selection = DocumentSelection.collapsed(
          DocumentPosition(
            startNode.id,
            TextNodePosition(startPrefix.text.length),
          ),
        );
      } else if (endNode is TextNode) {
        endNode.text = endSuffix!;
        changedIds.add(endNode.id);
        document.deleteNode(startNode.id);
        changedIds.add(startNode.id);
        context.composer.selection = DocumentSelection.collapsed(
          DocumentPosition(endNode.id, const TextNodePosition(0)),
        );
      } else {
        document.deleteNode(startNode.id);
        changedIds.add(startNode.id);
        document.deleteNode(endNode.id);
        changedIds.add(endNode.id);
        final landing = beforeStart != null
            ? _endOf(beforeStart)
            : (afterEnd != null ? _startOf(afterEnd) : null);
        if (landing != null) {
          context.composer.selection = DocumentSelection.collapsed(landing);
        }
      }
    }

    executor.emit(DocumentEdited(changedIds.toList()));
    executor.emit(SelectionChanged());
  }
}

// --- InsertNewlineRequest ------------------------------------------------

class InsertNewlineRequest extends EditRequest {}

const _headingBlockTypes = {
  'header1',
  'header2',
  'header3',
  'header4',
  'header5',
  'header6',
};

class _InsertNewlineCommand extends EditCommand {
  @override
  void execute(EditContext context, CommandExecutor executor) {
    final selection = context.composer.selection;
    if (selection == null) return;
    final position = selection.extent;
    final document = context.document;
    final node = document.getNodeById(position.nodeId);
    if (node == null) return;

    if (node is TextNode) {
      final offset = (position.nodePosition as TextNodePosition).offset;
      final left = node.text.copyRange(0, offset);
      final right = node.text.copyRange(offset, node.text.text.length);
      node.text = left;

      final secondMetadata = Map<String, Object?>.from(node.metadata);
      if (_headingBlockTypes.contains(node.blockType)) {
        secondMetadata['blockType'] = 'paragraph';
      }
      final newNode = TextNode(
        id: generateNodeId(),
        text: right,
        metadata: secondMetadata,
      );
      document.insertNodeAfter(node.id, newNode);
      context.composer.selection = DocumentSelection.collapsed(
        DocumentPosition(newNode.id, const TextNodePosition(0)),
      );
      executor.emit(DocumentEdited([node.id, newNode.id]));
    } else {
      final isUpstream =
          (position.nodePosition as UpstreamDownstreamNodePosition).isUpstream;
      final newNode = TextNode(id: generateNodeId(), text: AttributedText(''));
      if (isUpstream) {
        document.insertNodeAt(document.getNodeIndexById(node.id), newNode);
      } else {
        document.insertNodeAfter(node.id, newNode);
      }
      context.composer.selection = DocumentSelection.collapsed(
        DocumentPosition(newNode.id, const TextNodePosition(0)),
      );
      executor.emit(DocumentEdited([newNode.id]));
    }
    executor.emit(SelectionChanged());
  }
}

// --- ChangeSelectionRequest ---------------------------------------------

class ChangeSelectionRequest extends EditRequest {
  ChangeSelectionRequest(this.selection);
  final DocumentSelection? selection;
}

class _ChangeSelectionCommand extends EditCommand {
  _ChangeSelectionCommand(this.request);
  final ChangeSelectionRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    context.composer.selection = request.selection;
    executor.emit(SelectionChanged());

    final selection = request.selection;
    Set<Attribution> newComposing = const {};
    if (selection != null && selection.isCollapsed) {
      final node = context.document.getNodeById(selection.extent.nodeId);
      final position = selection.extent.nodePosition;
      if (node is TextNode && position is TextNodePosition) {
        newComposing = node.text.attributionsAt(position.offset);
      }
    }
    if (!_setEquals(context.composer.composingAttributions, newComposing)) {
      context.composer.composingAttributions = newComposing;
      executor.emit(ComposingAttributionsChanged());
    }
  }
}

bool _setEquals(Set<Attribution> a, Set<Attribution> b) =>
    a.length == b.length && a.containsAll(b);

// --- ToggleAttributionRequest ---------------------------------------------

class ToggleAttributionRequest extends EditRequest {
  ToggleAttributionRequest(this.attribution);
  final Attribution attribution;
}

class _ToggleAttributionCommand extends EditCommand {
  _ToggleAttributionCommand(this.request);
  final ToggleAttributionRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final selection = context.composer.selection;
    if (selection == null) return;
    final a = request.attribution;

    if (selection.isCollapsed) {
      final has = context.composer.composingAttributions.any((x) => x == a);
      if (has) {
        context.composer.composingAttributions.removeWhere((x) => x == a);
      } else {
        context.composer.composingAttributions.removeWhere(
          (x) => x.conflictsWith(a),
        );
        context.composer.composingAttributions.add(a);
      }
      executor.emit(ComposingAttributionsChanged());
      return;
    }

    final document = context.document;
    final (startPos, endPos) = selection.normalize(document);
    final startIndex = document.getNodeIndexById(startPos.nodeId);
    final endIndex = document.getNodeIndexById(endPos.nodeId);

    (int, int)? segmentOf(int i, DocumentNode node) {
      if (node is! TextNode) return null;
      final segStart = i == startIndex
          ? (startPos.nodePosition as TextNodePosition).offset
          : 0;
      final segEnd = i == endIndex
          ? (endPos.nodePosition as TextNodePosition).offset
          : node.text.text.length;
      if (segEnd <= segStart) return null;
      return (segStart, segEnd);
    }

    var allHave = true;
    for (var i = startIndex; i <= endIndex; i++) {
      final node = document.getNodeAt(i);
      final seg = segmentOf(i, node);
      if (seg == null) continue;
      if (!(node as TextNode).text.hasAttributionThroughout(
        a,
        seg.$1,
        seg.$2,
      )) {
        allHave = false;
        break;
      }
    }

    final changedIds = <String>[];
    for (var i = startIndex; i <= endIndex; i++) {
      final node = document.getNodeAt(i);
      final seg = segmentOf(i, node);
      if (seg == null) continue;
      final textNode = node as TextNode;
      textNode.text = allHave
          ? textNode.text.removeAttribution(a, seg.$1, seg.$2)
          : textNode.text.addAttribution(a, seg.$1, seg.$2);
      changedIds.add(textNode.id);
    }
    if (changedIds.isNotEmpty) executor.emit(DocumentEdited(changedIds));
  }
}

// --- ChangeBlockTypeRequest / ChangeIndentRequest -----------------------

class ChangeBlockTypeRequest extends EditRequest {
  ChangeBlockTypeRequest(this.blockType);
  final String blockType;
}

class ChangeIndentRequest extends EditRequest {
  ChangeIndentRequest(this.delta);
  final int delta;
}

Iterable<TextNode> _textNodesInSelection(EditContext context) sync* {
  final selection = context.composer.selection;
  if (selection == null) return;
  final document = context.document;
  final (startPos, endPos) = selection.normalize(document);
  final startIndex = document.getNodeIndexById(startPos.nodeId);
  final endIndex = document.getNodeIndexById(endPos.nodeId);
  for (var i = startIndex; i <= endIndex; i++) {
    final node = document.getNodeAt(i);
    if (node is TextNode) yield node;
  }
}

class _ChangeBlockTypeCommand extends EditCommand {
  _ChangeBlockTypeCommand(this.request);
  final ChangeBlockTypeRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final changedIds = <String>[];
    for (final node in _textNodesInSelection(context)) {
      node.metadata = {...node.metadata, 'blockType': request.blockType};
      changedIds.add(node.id);
    }
    if (changedIds.isNotEmpty) executor.emit(DocumentEdited(changedIds));
  }
}

class _ChangeIndentCommand extends EditCommand {
  _ChangeIndentCommand(this.request);
  final ChangeIndentRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final changedIds = <String>[];
    for (final node in _textNodesInSelection(context)) {
      final newIndent = (node.indent + request.delta).clamp(0, 8);
      node.metadata = {...node.metadata, 'indent': newIndent};
      changedIds.add(node.id);
    }
    if (changedIds.isNotEmpty) executor.emit(DocumentEdited(changedIds));
  }
}

// --- InsertNodeRequest / DeleteNodeRequest -------------------------------

class InsertNodeRequest extends EditRequest {
  InsertNodeRequest(this.node, {this.afterNodeId});
  final DocumentNode node;
  final String? afterNodeId;
}

class _InsertNodeCommand extends EditCommand {
  _InsertNodeCommand(this.request);
  final InsertNodeRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    if (request.afterNodeId != null) {
      context.document.insertNodeAfter(request.afterNodeId!, request.node);
    } else {
      context.document.insertNodeAt(
        context.document.nodes.length,
        request.node,
      );
    }
    executor.emit(DocumentEdited([request.node.id]));
  }
}

class DeleteNodeRequest extends EditRequest {
  DeleteNodeRequest(this.nodeId);
  final String nodeId;
}

class _DeleteNodeCommand extends EditCommand {
  _DeleteNodeCommand(this.request);
  final DeleteNodeRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    context.document.deleteNode(request.nodeId);
    final selection = context.composer.selection;
    if (selection != null &&
        (selection.base.nodeId == request.nodeId ||
            selection.extent.nodeId == request.nodeId)) {
      context.composer.selection = null;
      executor.emit(SelectionChanged());
    }
    executor.emit(DocumentEdited([request.nodeId]));
  }
}

// --- MergeWithPreviousNodeRequest ---------------------------------------

/// Merges the node identified by [nodeId] into the node immediately before
/// it. If the previous node is a [TextNode], its text is joined with the
/// (only-if-also-text) target node's text and the caret lands at the join
/// point; otherwise the previous node is simply deleted and the caret lands
/// at the start of [nodeId]. No-op if [nodeId] is the first node.
class MergeWithPreviousNodeRequest extends EditRequest {
  MergeWithPreviousNodeRequest(this.nodeId);
  final String nodeId;
}

class _MergeWithPreviousNodeCommand extends EditCommand {
  _MergeWithPreviousNodeCommand(this.request);
  final MergeWithPreviousNodeRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final document = context.document;
    final node = document.getNodeById(request.nodeId);
    if (node == null) return;
    final previous = document.getNodeBefore(request.nodeId);
    if (previous == null) return;

    if (previous is TextNode && node is TextNode) {
      final joinOffset = previous.text.text.length;
      previous.text = _concatText(previous.text, node.text);
      document.deleteNode(node.id);
      context.composer.selection = DocumentSelection.collapsed(
        DocumentPosition(previous.id, TextNodePosition(joinOffset)),
      );
      executor.emit(DocumentEdited([previous.id, node.id]));
    } else {
      document.deleteNode(previous.id);
      context.composer.selection = DocumentSelection.collapsed(_startOf(node));
      executor.emit(DocumentEdited([previous.id]));
    }
    executor.emit(SelectionChanged());
  }
}

// --- Default handlers ------------------------------------------------

final List<EditRequestHandler> defaultRequestHandlers = [
  (request) =>
      request is InsertTextRequest ? _InsertTextCommand(request) : null,
  (request) =>
      request is DeleteSelectionRequest ? _DeleteSelectionCommand() : null,
  (request) => request is InsertNewlineRequest ? _InsertNewlineCommand() : null,
  (request) => request is ChangeSelectionRequest
      ? _ChangeSelectionCommand(request)
      : null,
  (request) => request is ToggleAttributionRequest
      ? _ToggleAttributionCommand(request)
      : null,
  (request) => request is ChangeBlockTypeRequest
      ? _ChangeBlockTypeCommand(request)
      : null,
  (request) =>
      request is ChangeIndentRequest ? _ChangeIndentCommand(request) : null,
  (request) =>
      request is InsertNodeRequest ? _InsertNodeCommand(request) : null,
  (request) =>
      request is DeleteNodeRequest ? _DeleteNodeCommand(request) : null,
  (request) => request is MergeWithPreviousNodeRequest
      ? _MergeWithPreviousNodeCommand(request)
      : null,
];
