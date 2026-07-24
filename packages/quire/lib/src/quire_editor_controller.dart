import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:quire_core/quire_core.dart';

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');
const _strikethroughAttribution = Attribution('strikethrough');

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
  void toggleStrikethrough() => _toggle(_strikethroughAttribution);

  void toggleTaskChecked(String nodeId) =>
      history.execute([ToggleTaskCheckedRequest(nodeId)]);

  /// Inserts an [ImageNode] right after the currently-focused node (or at
  /// the document end if nothing is focused).
  void insertImage(String url) {
    history.execute([
      InsertNodeRequest(
        ImageNode(id: generateNodeId(), url: url),
        afterNodeId: _focusedNodeId ?? document.nodes.lastOrNull?.id,
      ),
    ]);
  }

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

  // --- Table navigation/toolbar actions -------------------------------

  /// The table cell the caret currently sits in, as grid coordinates
  /// (resolving spans) — `null` when the caret isn't inside a table. Drives
  /// which table-editing buttons the toolbar shows.
  ({TableNode table, int row, int column})? get focusedTableCell {
    final id = _focusedNodeId;
    if (id == null) return null;
    for (final node in document.nodes) {
      if (node is! TableNode) continue;
      final grid = node.grid;
      for (var r = 0; r < grid.length; r++) {
        for (var c = 0; c < grid[r].length; c++) {
          final cell = grid[r][c];
          if (cell != null && cell.nodes.any((n) => n.id == id)) {
            return (table: node, row: r, column: c);
          }
        }
      }
    }
    return null;
  }

  bool isInsideTable(String nodeId) {
    for (final node in document.nodes) {
      if (node is! TableNode) continue;
      for (final row in node.rows) {
        for (final cell in row.cells) {
          if (cell.nodes.any((n) => n.id == nodeId)) return true;
        }
      }
    }
    return false;
  }

  void insertTable({int rows = 3, int columns = 3}) {
    history.execute([
      InsertTableRequest(
        rows: rows,
        columns: columns,
        afterNodeId: _topLevelAnchorId(),
      ),
    ]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) focusNode(id);
  }

  /// Never inserts inside a cell (nested tables are unsupported) — anchors
  /// after the currently-focused top-level node, or after the table
  /// enclosing the focused node if it's nested, or at the document end.
  String? _topLevelAnchorId() {
    final id = _focusedNodeId;
    if (id == null) return null;
    if (document.nodes.any((n) => n.id == id)) return id;
    for (final node in document.nodes) {
      if (node is TableNode &&
          node.rows.any(
            (row) => row.cells.any((c) => c.nodes.any((n) => n.id == id)),
          )) {
        return node.id;
      }
    }
    return null;
  }

  void insertTableRowAbove() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([InsertTableRowRequest(cell.table.id, atRow: cell.row)]);
  }

  void insertTableRowBelow() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([
      InsertTableRowRequest(cell.table.id, atRow: cell.row + 1),
    ]);
  }

  void deleteTableRow() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([DeleteTableRowRequest(cell.table.id, row: cell.row)]);
  }

  void insertTableColumnLeft() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([
      InsertTableColumnRequest(cell.table.id, atColumn: cell.column),
    ]);
  }

  void insertTableColumnRight() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([
      InsertTableColumnRequest(cell.table.id, atColumn: cell.column + 1),
    ]);
  }

  void deleteTableColumn() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([
      DeleteTableColumnRequest(cell.table.id, column: cell.column),
    ]);
  }

  /// Whether the caret's cell has a cell to its right to merge with — the
  /// toolbar acts on the caret's cell only, there is no rectangular mouse
  /// selection.
  bool get canMergeFocusedCellRight {
    final cell = focusedTableCell;
    if (cell == null) return false;
    final (_, columnCount) = cell.table.gridSize;
    return cell.column + 1 < columnCount;
  }

  void mergeWithNextCell() {
    if (!canMergeFocusedCellRight) return;
    final cell = focusedTableCell!;
    history.execute([
      MergeTableCellsRequest(
        cell.table.id,
        fromRow: cell.row,
        fromColumn: cell.column,
        toRow: cell.row,
        toColumn: cell.column + 1,
      ),
    ]);
  }

  /// Whether the caret's cell actually spans more than one grid position —
  /// splitting an unmerged cell would be a no-op.
  bool get canSplitFocusedCell {
    final cell = focusedTableCell;
    if (cell == null) return false;
    final tableCell = cell.table.cellAt(cell.row, cell.column);
    return tableCell != null &&
        (tableCell.rowSpan > 1 || tableCell.colSpan > 1);
  }

  void splitFocusedCell() {
    if (!canSplitFocusedCell) return;
    final cell = focusedTableCell!;
    history.execute([
      SplitTableCellRequest(cell.table.id, row: cell.row, column: cell.column),
    ]);
  }

  /// Deletes the whole table the caret is currently inside.
  void deleteTable() {
    final cell = focusedTableCell;
    if (cell == null) return;
    history.execute([DeleteNodeRequest(cell.table.id)]);
  }

  /// Tab/Shift-Tab: moves the caret to the next/previous cell in reading
  /// order (row-major over cells, wrapping into the next row); Tab in the
  /// last cell appends a row, the way Word does.
  void moveToAdjacentCell(String nodeId, {required bool forward}) {
    TableNode? table;
    var flatIndex = 0;
    outer:
    for (final node in document.nodes) {
      if (node is! TableNode) continue;
      var index = 0;
      for (final row in node.rows) {
        for (final cell in row.cells) {
          if (cell.nodes.any((n) => n.id == nodeId)) {
            table = node;
            flatIndex = index;
            break outer;
          }
          index++;
        }
      }
    }
    if (table == null) return;

    final flat = [for (final row in table.rows) ...row.cells];
    final targetIndex = forward ? flatIndex + 1 : flatIndex - 1;

    TableCell? target;
    if (targetIndex < 0) {
      return;
    } else if (targetIndex >= flat.length) {
      history.execute([
        InsertTableRowRequest(table.id, atRow: table.rows.length),
      ]);
      final lastRow = table.rows.last.cells;
      target = lastRow.isEmpty ? null : lastRow.first;
    } else {
      target = flat[targetIndex];
    }
    if (target == null || target.nodes.isEmpty) return;

    final firstNode = target.nodes.first;
    final position = firstNode is TextNode
        ? DocumentPosition(firstNode.id, const TextNodePosition(0))
        : DocumentPosition(
            firstNode.id,
            const UpstreamDownstreamNodePosition.upstream(),
          );
    changeSelection(DocumentSelection.collapsed(position));
    focusNode(firstNode.id);
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

  // --- Cross-node selection operations -------------------------------

  void deleteSelection() {
    final selection = composer.selection;
    if (selection == null || selection.isCollapsed) return;
    history.execute([DeleteSelectionRequest()]);
  }

  /// Selects the entire document, from the start of the first node to the
  /// end of the last (in document order, so this reaches into table cells).
  void selectAll() {
    final ordered = document.nodesInDocumentOrder.toList();
    if (ordered.isEmpty) return;
    changeSelection(
      DocumentSelection(
        base: _startOf(ordered.first),
        extent: _endOf(ordered.last),
      ),
    );
  }

  Future<void> copySelection() async {
    final selection = composer.selection;
    if (selection == null) return;
    final text = flattenSelectionText(document, selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> cutSelection() async {
    final selection = composer.selection;
    if (selection == null || selection.isCollapsed) return;
    await copySelection();
    history.execute([DeleteSelectionRequest()]);
  }

  Future<void> pasteClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    replaceSelectionWithText(text);
  }

  /// Replaces the current selection (deleting it first, if expanded) with
  /// [text] — used for cross-node typing and for paste. A caret-only
  /// (collapsed) selection just inserts at that position.
  ///
  // ponytail: delete-then-insert is two history entries instead of one
  // combined undo step; acceptable since it only affects the multi-node/paste
  // path, not everyday single-character typing.
  void replaceSelectionWithText(String text) {
    final selection = composer.selection;
    if (selection == null) return;
    if (!selection.isCollapsed) deleteSelection();

    final position = composer.selection?.extent;
    if (position == null || text.isEmpty) return;
    final nodePosition = position.nodePosition;
    if (nodePosition is! TextNodePosition) return;

    final segments = text.split('\n');
    replaceText(
      nodeId: position.nodeId,
      start: nodePosition.offset,
      end: nodePosition.offset,
      insertedText: segments.first,
    );
    for (var i = 1; i < segments.length; i++) {
      insertNewline();
      final currentNodeId = composer.selection?.extent.nodeId;
      if (currentNodeId != null && segments[i].isNotEmpty) {
        replaceText(
          nodeId: currentNodeId,
          start: 0,
          end: 0,
          insertedText: segments[i],
        );
      }
    }
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
}
