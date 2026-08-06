import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:quire_core/quire_core.dart';

const _boldAttribution = Attribution('bold');
const _italicAttribution = Attribution('italic');
const _underlineAttribution = Attribution('underline');
const _strikethroughAttribution = Attribution('strikethrough');

/// A single find match: the range `[start, end)` of a query hit within one
/// [TextNode]'s text.
typedef FindMatch = ({String nodeId, int start, int end});

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

  int _focusRequest = 0;

  /// Bumped by [requestFocus]. The editor watches this rather than
  /// [focusedNodeId] so that asking for the caret in the node it already
  /// believes is focused still works — focus may have moved to a field
  /// outside the editor (a title box, say) since it last looked.
  int get focusRequest => _focusRequest;

  /// Reports that [nodeId]'s field has taken focus. This is bookkeeping, not
  /// a request — use [requestFocus] to actually move the caret.
  void focusNode(String nodeId) {
    if (_focusedNodeId == nodeId) return;
    _focusedNodeId = nodeId;
    notifyListeners();
  }

  /// Asks the editor to put focus in [nodeId], even if that is already
  /// [focusedNodeId].
  void requestFocus(String nodeId) {
    _focusedNodeId = nodeId;
    _focusRequest++;
    notifyListeners();
  }

  /// Clears [focusedNodeId] if it's still [nodeId] — called once the widget
  /// layer confirms focus genuinely left the editor (not just moved between
  /// two of its own nodes, and not the toolbar's own momentary unfocus while
  /// it swaps in its panel), so a later tap starts from a clean state.
  void clearFocusIfCurrent(String nodeId) {
    if (_focusedNodeId != nodeId) return;
    _focusedNodeId = null;
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

  void toggleCollapsed(String nodeId) =>
      history.execute([ToggleCollapsedRequest(nodeId)]);

  /// Inserts an empty paragraph right after [toggleNodeId], indented one
  /// level deeper, and returns its id — what tapping an empty toggle's
  /// "Empty toggle" hint does, so a toggle with no content yet doesn't
  /// require pressing Enter on its title first to get content into it.
  ///
  /// Doesn't focus the new node itself — the tap that calls this also
  /// reaches the editor's own document-level pointer handling (a `Listener`
  /// sees every pointer event regardless of gesture-arena/widget-tree
  /// nesting), which requests focus on whatever node it resolves the tap
  /// nearest to; doing it here too just races that and sometimes loses.
  /// The caller defers its own focus request a frame to reliably go last.
  String addToggleContent(String toggleNodeId) {
    final toggle = document.getNodeById(toggleNodeId);
    if (toggle is! TextNode) return toggleNodeId;
    final newNode = TextNode(
      id: generateNodeId(),
      text: AttributedText(''),
      metadata: {'indent': toggle.indent + 1},
    );
    history.execute([
      InsertNodeRequest(newNode, afterNodeId: toggleNodeId),
    ]);
    return newNode.id;
  }

  /// Inserts [displayText] carrying a `'link'` attribution pointing at
  /// [url], replacing the current selection if there is one. The toolbar's
  /// Link button and paste's URL-detection both route through this — it's
  /// the one path that needs to force a specific attribution rather than
  /// insert with whatever the composer is already composing in.
  void insertLink({required String url, required String displayText}) {
    if (displayText.isEmpty) return;
    final selection = composer.selection;
    if (selection == null) return;
    if (!selection.isCollapsed) deleteSelection();

    final position = composer.selection?.extent;
    if (position == null) return;
    if (position.nodePosition is! TextNodePosition) return;
    history.execute([
      InsertTextRequest(position, displayText, {
        Attribution('link', value: {'url': url}),
      }),
    ]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) requestFocus(id);
  }

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

  /// Whether the focused node already carries [blockType] — what makes a
  /// toolbar button light up. [setBlockType] toggles on the same condition,
  /// so "lit" and "pressing this turns it off" can't drift apart.
  bool isBlockType(String blockType) => focusedTextNode?.blockType == blockType;

  /// Sets [blockType] outright. For a control that *names* the state it wants
  /// — the text-size menu — where pressing the current choice again should do
  /// nothing rather than undo it.
  void applyBlockType(String blockType) {
    if (composer.selection == null) return;
    history.execute([ChangeBlockTypeRequest(blockType)]);
  }

  /// Applies [blockType] to the selection, or reverts it to a plain paragraph
  /// when it's already active — pressing a lit block button turns it off.
  /// Insertions (image, table) aren't toggles and don't come through here.
  void setBlockType(String blockType) =>
      applyBlockType(isBlockType(blockType) ? 'paragraph' : blockType);

  void changeIndent(int delta) {
    if (composer.selection == null) return;
    history.execute([ChangeIndentRequest(delta)]);
  }

  /// Whether the focused node's alignment is already [align] — what makes an
  /// alignment button light up, mirroring [isBlockType].
  bool isTextAlign(String align) => focusedTextNode?.textAlign == align;

  void changeTextAlign(String align) {
    if (composer.selection == null) return;
    history.execute([ChangeTextAlignRequest(align)]);
  }

  void changeLineSpacing(double spacing) {
    if (composer.selection == null) return;
    history.execute([ChangeLineSpacingRequest(spacing)]);
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
    if (id != null) requestFocus(id);
  }

  void mergeWithPrevious(String nodeId) {
    history.execute([MergeWithPreviousNodeRequest(nodeId)]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) requestFocus(id);
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

  // --- Table actions by explicit id (for the per-table settings button, --
  // --- which doesn't require the caret to be inside the table) -----------

  void addTableRowAtEnd(String tableId) {
    final table = document.getNodeById(tableId);
    if (table is! TableNode) return;
    final (rowCount, _) = table.gridSize;
    history.execute([InsertTableRowRequest(tableId, atRow: rowCount)]);
  }

  void addTableColumnAtEnd(String tableId) {
    final table = document.getNodeById(tableId);
    if (table is! TableNode) return;
    final (_, columnCount) = table.gridSize;
    history.execute([InsertTableColumnRequest(tableId, atColumn: columnCount)]);
  }

  void deleteTableById(String tableId) {
    history.execute([DeleteNodeRequest(tableId)]);
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

  // --- Find & replace -------------------------------------------------

  bool findBarOpen = false;
  String? findQuery;
  List<FindMatch> matches = [];
  int currentMatchIndex = -1;

  void openFind() {
    findBarOpen = true;
    notifyListeners();
  }

  void closeFind() {
    findBarOpen = false;
    findQuery = null;
    matches = [];
    currentMatchIndex = -1;
    notifyListeners();
  }

  /// Recomputes [matches] for [query] (case-insensitive) by scanning every
  /// text node in document order (including table cells), and selects the
  /// first match if any.
  void find(String query) {
    findQuery = query;
    matches = _findMatches(query);
    currentMatchIndex = matches.isEmpty ? -1 : 0;
    _selectCurrentMatch();
    notifyListeners();
  }

  List<FindMatch> _findMatches(String query) {
    if (query.isEmpty) return [];
    final lowerQuery = query.toLowerCase();
    final result = <FindMatch>[];
    for (final node in document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final text = node.text.text.toLowerCase();
      var searchStart = 0;
      while (true) {
        final index = text.indexOf(lowerQuery, searchStart);
        if (index < 0) break;
        result.add((nodeId: node.id, start: index, end: index + query.length));
        searchStart = index + query.length;
      }
    }
    return result;
  }

  void _selectCurrentMatch() {
    if (currentMatchIndex < 0 || currentMatchIndex >= matches.length) return;
    final match = matches[currentMatchIndex];
    changeSelection(
      DocumentSelection(
        base: DocumentPosition(match.nodeId, TextNodePosition(match.start)),
        extent: DocumentPosition(match.nodeId, TextNodePosition(match.end)),
      ),
    );
    requestFocus(match.nodeId);
  }

  void findNext() {
    if (matches.isEmpty) return;
    currentMatchIndex = (currentMatchIndex + 1) % matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

  void findPrevious() {
    if (matches.isEmpty) return;
    currentMatchIndex =
        (currentMatchIndex - 1 + matches.length) % matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

  /// Replaces just the current match, then re-runs [find] (offsets shift
  /// after any edit, so matches are recomputed rather than patched by hand),
  /// landing on the match that took its place — or the last one, if it was
  /// the final match.
  void replaceCurrent(String replacement) {
    if (currentMatchIndex < 0 || currentMatchIndex >= matches.length) return;
    final match = matches[currentMatchIndex];
    changeSelection(
      DocumentSelection(
        base: DocumentPosition(match.nodeId, TextNodePosition(match.start)),
        extent: DocumentPosition(match.nodeId, TextNodePosition(match.end)),
      ),
    );
    replaceSelectionWithText(replacement);
    final query = findQuery;
    if (query == null) return;
    matches = _findMatches(query);
    currentMatchIndex = matches.isEmpty
        ? -1
        : currentMatchIndex.clamp(0, matches.length - 1);
    _selectCurrentMatch();
    notifyListeners();
  }

  /// Replaces every existing match in one pass, in reverse document order —
  /// not by looping [replaceCurrent] and re-finding, because if [replacement]
  /// itself contains [query] (e.g. find "Bob", replace "Bobby"), a re-find
  /// after each replacement matches the text it just inserted and never
  /// terminates. Reverse order means every match's offset, computed once
  /// up front, is still valid when it's replaced — nothing before it in its
  /// node has moved yet.
  void replaceAll(String query, String replacement) {
    final toReplace = _findMatches(query);
    for (final match in toReplace.reversed) {
      changeSelection(
        DocumentSelection(
          base: DocumentPosition(match.nodeId, TextNodePosition(match.start)),
          extent: DocumentPosition(match.nodeId, TextNodePosition(match.end)),
        ),
      );
      replaceSelectionWithText(replacement);
    }
    findQuery = query;
    matches = _findMatches(query);
    currentMatchIndex = matches.isEmpty ? -1 : 0;
    _selectCurrentMatch();
    notifyListeners();
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
    final node = document.getNodeById(nodeId);
    if (end > start) {
      if (node is TextNode) attributions = node.text.attributionsAt(start);
      // A link is atomic: editing any part of it (not just the characters
      // actually removed) invalidates the whole thing, converting the rest
      // back to plain text — otherwise deleting one character out of a link
      // would leave the remaining, now-inaccurate text still styled and
      // clickable as a link. Stripped in the range's *original* coordinates,
      // before the delete below shifts anything.
      if (node is TextNode) {
        final overlappingLinks = node.text.spans.where(
          (s) => s.attribution.name == 'link' && s.start < end && s.end > start,
        );
        for (final span in overlappingLinks) {
          requests.add(
            RemoveAttributionInRangeRequest(
              nodeId,
              span.attribution,
              span.start,
              span.end,
            ),
          );
          attributions = attributions?.where((a) => a.name != 'link').toSet();
        }
      }
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
    var textToInsert = insertedText;
    // Deterministic auto-capitalize: the platform's `textCapitalization`
    // hint (see quire_editor.dart's EditableText) never fires for the first
    // character of a node, because every field is prefixed with a
    // zero-width sentinel (see `_emptyNodeSentinel`) — the character before
    // the caret at offset 0 is the sentinel, not "start of text", which
    // defeats iOS/Android's own auto-shift heuristic. Fix it here instead,
    // at the single choke point every insert (soft keyboard, hardware
    // keyboard, paste) routes through: if this text is landing at offset 0
    // of a node that was empty before this edit, capitalize just its first
    // character. Code blocks are exempt — auto-capitalizing code is wrong.
    if (node is TextNode &&
        start == 0 &&
        node.text.text.isEmpty &&
        node.blockType != 'code' &&
        textToInsert.isNotEmpty) {
      final first = textToInsert[0];
      final upper = first.toUpperCase();
      if (upper != first) textToInsert = upper + textToInsert.substring(1);
    }
    if (textToInsert.isNotEmpty) {
      requests.add(
        InsertTextRequest(
          DocumentPosition(nodeId, TextNodePosition(start)),
          textToInsert,
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
    final id = composer.selection?.extent.nodeId;
    if (id != null) requestFocus(id);
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
    QuireClipboard.instance.store(
      text,
      extractSelectionNodes(document, selection),
    );
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> cutSelection() async {
    final selection = composer.selection;
    if (selection == null || selection.isCollapsed) return;
    await copySelection();
    history.execute([DeleteSelectionRequest()]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) requestFocus(id);
  }

  Future<void> pasteClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;

    final richNodes = QuireClipboard.instance.richNodesFor(text);
    if (richNodes != null && richNodes.isNotEmpty) {
      replaceSelectionWithNodes(richNodes);
      return;
    }
    // ponytail: the OS clipboard only round-trips plain text without a
    // plugin, so content copied outside Quire (or since overwritten
    // elsewhere) pastes unformatted. Ceiling: a clipboard plugin (e.g.
    // super_clipboard) for cross-app text/html round-trip.
    replaceSelectionWithText(text);
  }

  /// Rich-paste counterpart to [replaceSelectionWithText]: replaces the
  /// current selection with [nodes] (clipped [TextNode]s from an in-app
  /// copy), preserving each node's inline attributions and block type.
  void replaceSelectionWithNodes(List<TextNode> nodes) {
    final selection = composer.selection;
    if (selection == null || nodes.isEmpty) return;
    if (!selection.isCollapsed) deleteSelection();
    if (composer.selection == null) return;
    history.execute([InsertRichContentRequest(nodes)]);
    final id = composer.selection?.extent.nodeId;
    if (id != null) requestFocus(id);
  }

  /// Replaces the current selection (deleting it first, if expanded) with
  /// [text] — used for cross-node typing and for paste. A caret-only
  /// (collapsed) selection just inserts at that position.
  ///
  // ponytail: delete-then-insert is two history entries instead of one
  // combined undo step; acceptable since it only affects the multi-node/paste
  // path, not everyday single-character typing.
  void replaceSelectionWithText(String text, {bool requestFocusAfter = true}) {
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
    final id = composer.selection?.extent.nodeId;
    if (requestFocusAfter && id != null) requestFocus(id);
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
