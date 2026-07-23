import 'package:flutter/foundation.dart';
import 'package:quire_core/quire_core.dart';

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');

/// Owns the document/composer/editor/history and is the single place the
/// widget layer talks to the model. Every mutation goes through
/// [EditHistory.execute] (never the document directly), so undo/redo stay
/// correct.
class QuireEditorController extends ChangeNotifier implements EditListener {
  QuireEditorController({MutableDocument? document})
    : document = document ?? MutableDocument(),
      composer = DocumentComposer() {
    editor = Editor(
      this.document,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
    history = EditHistory(editor);
    editor.addListener(this);
  }

  final MutableDocument document;
  final DocumentComposer composer;
  late final Editor editor;
  late final EditHistory history;

  String? _focusedNodeId;
  String? get focusedNodeId => _focusedNodeId;

  void focusNode(String nodeId) {
    if (_focusedNodeId == nodeId) return;
    _focusedNodeId = nodeId;
    notifyListeners();
  }

  @override
  void onEdit(List<EditEvent> events) => notifyListeners();

  @override
  void dispose() {
    editor.removeListener(this);
    super.dispose();
  }

  // --- Toolbar actions ----------------------------------------------------

  void toggleBold() => _toggle(_boldAttribution);
  void toggleItalic() => _toggle(_italicAttribution);
  void toggleUnderline() => _toggle(_underlineAttribution);

  void _toggle(Attribution attribution) {
    final selection = composer.selection;
    if (selection == null) return;
    // A collapsed selection only arms `composingAttributions`, which isn't
    // part of the document snapshot — routing it through `history` would
    // record an undo step that visibly does nothing.
    if (selection.isCollapsed) {
      editor.execute([ToggleAttributionRequest(attribution)]);
    } else {
      history.execute([ToggleAttributionRequest(attribution)]);
    }
  }

  void setBlockType(String blockType) {
    if (composer.selection == null) return;
    history.execute([ChangeBlockTypeRequest(blockType)]);
  }

  void changeIndent(int delta) {
    if (composer.selection == null) return;
    history.execute([ChangeIndentRequest(delta)]);
  }

  void undo() => history.undo();
  void redo() => history.redo();

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  /// The attributions active for the current selection: `composingAttributions`
  /// when collapsed, or every attribution that covers the whole (single-node)
  /// selection range otherwise.
  Set<Attribution> get activeAttributions {
    final selection = composer.selection;
    if (selection == null) return const {};
    if (selection.isCollapsed) return composer.composingAttributions;

    final node = document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) return const {};
    final basePos = selection.base.nodePosition;
    final extentPos = selection.extent.nodePosition;
    if (basePos is! TextNodePosition || extentPos is! TextNodePosition) {
      return const {};
    }
    final lo = basePos.offset < extentPos.offset
        ? basePos.offset
        : extentPos.offset;
    final hi = basePos.offset < extentPos.offset
        ? extentPos.offset
        : basePos.offset;

    final candidates = node.text.spans.map((s) => s.attribution).toSet();
    return candidates
        .where((a) => node.text.hasAttributionThroughout(a, lo, hi))
        .toSet();
  }

  TextNode? get focusedTextNode {
    final id = _focusedNodeId;
    if (id == null) return null;
    final node = document.getNodeById(id);
    return node is TextNode ? node : null;
  }

  // --- Requests used by the editor widget's node syncing -------------------

  void insertNewline() {
    history.execute([InsertNewlineRequest()]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) focusNode(id);
  }

  void mergeWithPrevious(String nodeId) {
    history.execute([MergeWithPreviousNodeRequest(nodeId)]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) focusNode(id);
  }

  void changeSelection(DocumentSelection? selection) {
    history.execute([ChangeSelectionRequest(selection)]);
  }

  void replaceText({
    required String nodeId,
    required int start,
    required int end,
    required String insertedText,
  }) {
    final requests = <EditRequest>[];
    // Capture the attributions at the deletion point *before* issuing the
    // selection change — a non-collapsed ChangeSelectionRequest resets
    // composingAttributions to {}, which would otherwise make the following
    // insert (attributions: null -> composer's set) come out unformatted.
    Set<Attribution>? attributions;
    if (end > start) {
      final node = document.getNodeById(nodeId);
      if (node is TextNode) attributions = node.text.attributionsAt(start);
      requests.add(
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(nodeId, TextNodePosition(start)),
            extent: DocumentPosition(nodeId, TextNodePosition(end)),
          ),
        ),
      );
      requests.add(DeleteSelectionRequest());
    }
    if (insertedText.isNotEmpty) {
      requests.add(
        InsertTextRequest(
          DocumentPosition(nodeId, TextNodePosition(start)),
          insertedText,
          attributions,
        ),
      );
    }
    if (requests.isNotEmpty) history.execute(requests);
  }
}
