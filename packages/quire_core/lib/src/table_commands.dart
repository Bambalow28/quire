import 'attributed_text.dart';
import 'editor.dart';
import 'node_ids.dart';
import 'nodes.dart';
import 'selection.dart';

TableCell _emptyCell() => TableCell(
  nodes: [TextNode(id: generateNodeId(), text: AttributedText(''))],
);

/// Clears the composer's selection if it currently points at [nodeId] or any
/// node no longer present in [document] — mirrors `_DeleteNodeCommand`'s
/// safety check, needed here because deleting the last row/column removes
/// the whole table (and everything the caret may have been sitting in).
void _clearSelectionIfMissing(EditContext context, CommandExecutor executor) {
  final selection = context.composer.selection;
  if (selection == null) return;
  if (context.document.getNodeById(selection.base.nodeId) == null ||
      context.document.getNodeById(selection.extent.nodeId) == null) {
    context.composer.selection = null;
    executor.emit(SelectionChanged());
  }
}

// --- InsertTableRequest --------------------------------------------------

class InsertTableRequest extends EditRequest {
  InsertTableRequest({this.rows = 3, this.columns = 3, this.afterNodeId});
  final int rows;
  final int columns;
  final String? afterNodeId;
}

class _InsertTableCommand extends EditCommand {
  _InsertTableCommand(this.request);
  final InsertTableRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = TableNode(
      id: generateNodeId(),
      rows: List.generate(
        request.rows,
        (_) => TableRow(
          cells: List.generate(request.columns, (_) => _emptyCell()),
        ),
      ),
    );
    if (request.afterNodeId != null) {
      context.document.insertNodeAfter(request.afterNodeId!, table);
    } else {
      context.document.insertNodeAt(context.document.nodes.length, table);
    }
    final changedIds = [table.id];

    // Same trailing-paragraph guarantee as a non-text InsertNodeRequest, but
    // the caret still lands in the table's first cell — not the paragraph —
    // matching today's behaviour.
    final next = context.document.getNodeAfterInContainer(table.id);
    if (next is! TextNode) {
      final paragraph = TextNode(
        id: generateNodeId(),
        text: AttributedText(''),
      );
      context.document.insertNodeAfter(table.id, paragraph);
      changedIds.add(paragraph.id);
    }

    final firstNode = table.rows.first.cells.first.nodes.first;
    context.composer.selection = DocumentSelection.collapsed(
      DocumentPosition(firstNode.id, const TextNodePosition(0)),
    );
    executor.emit(DocumentEdited(changedIds));
    executor.emit(SelectionChanged());
  }
}

// --- InsertTableRowRequest / DeleteTableRowRequest ------------------------

class InsertTableRowRequest extends EditRequest {
  InsertTableRowRequest(this.tableId, {required this.atRow});
  final String tableId;
  final int atRow;
}

class _InsertTableRowCommand extends EditCommand {
  _InsertTableRowCommand(this.request);
  final InsertTableRowRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0) return;
    final numCols = grid[0].length;
    final atRow = request.atRow.clamp(0, numRows);

    final originRow = <TableCell, int>{};
    for (var r = 0; r < numRows; r++) {
      for (var c = 0; c < numCols; c++) {
        final cell = grid[r][c];
        if (cell != null) originRow.putIfAbsent(cell, () => r);
      }
    }

    // A cell whose span already crosses the insertion line grows by one row
    // instead of getting a fresh cell in the new row.
    final crossing = <TableCell>{};
    if (atRow < numRows) {
      for (var c = 0; c < numCols; c++) {
        final cell = grid[atRow][c]!;
        if (originRow[cell]! < atRow) crossing.add(cell);
      }
    }
    for (final cell in crossing) {
      cell.rowSpan += 1;
    }

    final newCells = <TableCell>[];
    for (var c = 0; c < numCols; c++) {
      if (atRow < numRows && crossing.contains(grid[atRow][c])) continue;
      newCells.add(_emptyCell());
    }
    table.rows.insert(atRow, TableRow(cells: newCells));

    context.document.reindexNestedNodes();
    executor.emit(DocumentEdited([table.id]));
  }
}

class DeleteTableRowRequest extends EditRequest {
  DeleteTableRowRequest(this.tableId, {required this.row});
  final String tableId;
  final int row;
}

class _DeleteTableRowCommand extends EditCommand {
  _DeleteTableRowCommand(this.request);
  final DeleteTableRowRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0 || request.row < 0 || request.row >= numRows) return;

    if (numRows == 1) {
      final id = table.id;
      context.document.deleteNode(id);
      _clearSelectionIfMissing(context, executor);
      executor.emit(DocumentEdited([id]));
      return;
    }

    final row = request.row;
    final numCols = grid[0].length;
    final originRow = <TableCell, int>{};
    for (var r = 0; r < numRows; r++) {
      for (var c = 0; c < numCols; c++) {
        final cell = grid[r][c];
        if (cell != null) originRow.putIfAbsent(cell, () => r);
      }
    }

    // Cells originating in the deleted row: a rowSpan of 1 is fully removed
    // with the row; a bigger rowSpan shrinks and moves down to originate in
    // the next row instead.
    final movedCells = <TableCell>[];
    for (final cell in table.rows[row].cells) {
      if (cell.rowSpan > 1) {
        cell.rowSpan -= 1;
        movedCells.add(cell);
      }
    }

    // Cells spanning down across the deleted line from an earlier row just
    // shrink in place.
    for (var r = 0; r < row; r++) {
      for (final cell in table.rows[r].cells) {
        final r0 = originRow[cell]!;
        if (r0 < row && r0 + cell.rowSpan > row) {
          cell.rowSpan -= 1;
        }
      }
    }

    table.rows.removeAt(row);
    if (movedCells.isNotEmpty) {
      final originCol = <TableCell, int>{};
      for (var c = 0; c < numCols; c++) {
        final cell = grid[row][c];
        if (cell != null) originCol.putIfAbsent(cell, () => c);
      }
      final nextRow = table.rows[row];
      final merged = [...nextRow.cells, ...movedCells]
        ..sort((a, b) => originCol[a]!.compareTo(originCol[b]!));
      table.rows[row] = TableRow(cells: merged);
    }

    context.document.reindexNestedNodes();
    _clearSelectionIfMissing(context, executor);
    executor.emit(DocumentEdited([table.id]));
  }
}

// --- InsertTableColumnRequest / DeleteTableColumnRequest ------------------

class InsertTableColumnRequest extends EditRequest {
  InsertTableColumnRequest(this.tableId, {required this.atColumn});
  final String tableId;
  final int atColumn;
}

class _InsertTableColumnCommand extends EditCommand {
  _InsertTableColumnCommand(this.request);
  final InsertTableColumnRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0) return;
    final numCols = grid[0].length;
    final atColumn = request.atColumn.clamp(0, numCols);

    final originCol = <TableCell, int>{};
    for (var r = 0; r < numRows; r++) {
      for (var c = 0; c < numCols; c++) {
        final cell = grid[r][c];
        if (cell != null) originCol.putIfAbsent(cell, () => c);
      }
    }

    final crossing = <TableCell>{};
    if (atColumn < numCols) {
      for (var r = 0; r < numRows; r++) {
        final cell = grid[r][atColumn]!;
        if (originCol[cell]! < atColumn) crossing.add(cell);
      }
    }
    for (final cell in crossing) {
      cell.colSpan += 1;
    }

    for (var r = 0; r < numRows; r++) {
      if (atColumn < numCols && crossing.contains(grid[r][atColumn])) continue;
      final row = table.rows[r];
      final insertIndex = row.cells
          .where((c) => originCol[c]! < atColumn)
          .length;
      row.cells.insert(insertIndex, _emptyCell());
    }

    context.document.reindexNestedNodes();
    executor.emit(DocumentEdited([table.id]));
  }
}

class DeleteTableColumnRequest extends EditRequest {
  DeleteTableColumnRequest(this.tableId, {required this.column});
  final String tableId;
  final int column;
}

class _DeleteTableColumnCommand extends EditCommand {
  _DeleteTableColumnCommand(this.request);
  final DeleteTableColumnRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0) return;
    final numCols = grid[0].length;
    final column = request.column;
    if (column < 0 || column >= numCols) return;

    if (numCols == 1) {
      final id = table.id;
      context.document.deleteNode(id);
      _clearSelectionIfMissing(context, executor);
      executor.emit(DocumentEdited([id]));
      return;
    }

    final originCol = <TableCell, int>{};
    for (var r = 0; r < numRows; r++) {
      for (var c = 0; c < numCols; c++) {
        final cell = grid[r][c];
        if (cell != null) originCol.putIfAbsent(cell, () => c);
      }
    }

    // Every distinct cell touching the deleted column, whether it
    // originates there or spans down through it from an earlier row.
    final cellsHere = <TableCell>{
      for (var r = 0; r < numRows; r++) grid[r][column]!,
    };
    for (final cell in cellsHere) {
      if (originCol[cell] == column) {
        if (cell.colSpan > 1) {
          cell.colSpan -= 1;
        } else {
          for (final row in table.rows) {
            if (row.cells.remove(cell)) break;
          }
        }
      } else {
        cell.colSpan -= 1;
      }
    }

    context.document.reindexNestedNodes();
    _clearSelectionIfMissing(context, executor);
    executor.emit(DocumentEdited([table.id]));
  }
}

// --- MergeTableCellsRequest / SplitTableCellRequest -----------------------

class MergeTableCellsRequest extends EditRequest {
  MergeTableCellsRequest(
    this.tableId, {
    required this.fromRow,
    required this.fromColumn,
    required this.toRow,
    required this.toColumn,
  });
  final String tableId;
  final int fromRow;
  final int fromColumn;
  final int toRow;
  final int toColumn;
}

class _MergeTableCellsCommand extends EditCommand {
  _MergeTableCellsCommand(this.request);
  final MergeTableCellsRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0) return;
    final numCols = grid[0].length;
    final r0 = request.fromRow;
    final r1 = request.toRow;
    final c0 = request.fromColumn;
    final c1 = request.toColumn;
    if (r0 < 0 ||
        c0 < 0 ||
        r1 >= numRows ||
        c1 >= numCols ||
        r1 < r0 ||
        c1 < c0) {
      return;
    }
    final target = grid[r0][c0];
    if (target == null) return;

    final seen = <TableCell>{target};
    final absorbed = <TableCell>[];
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        final cell = grid[r][c];
        if (cell != null && seen.add(cell)) absorbed.add(cell);
      }
    }

    for (final cell in absorbed) {
      target.nodes.addAll(cell.nodes);
      for (final row in table.rows) {
        if (row.cells.remove(cell)) break;
      }
    }
    target.rowSpan = r1 - r0 + 1;
    target.colSpan = c1 - c0 + 1;

    context.document.reindexNestedNodes();
    executor.emit(DocumentEdited([table.id]));
  }
}

class SplitTableCellRequest extends EditRequest {
  SplitTableCellRequest(
    this.tableId, {
    required this.row,
    required this.column,
  });
  final String tableId;
  final int row;
  final int column;
}

class _SplitTableCellCommand extends EditCommand {
  _SplitTableCellCommand(this.request);
  final SplitTableCellRequest request;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final table = context.document.getNodeById(request.tableId);
    if (table is! TableNode) return;
    final grid = table.grid;
    final numRows = grid.length;
    if (numRows == 0) return;
    final numCols = grid[0].length;
    if (request.row < 0 ||
        request.row >= numRows ||
        request.column < 0 ||
        request.column >= numCols) {
      return;
    }
    final cell = grid[request.row][request.column];
    if (cell == null) return;

    final originRow = <TableCell, int>{};
    final originCol = <TableCell, int>{};
    for (var r = 0; r < numRows; r++) {
      for (var c = 0; c < numCols; c++) {
        final g = grid[r][c];
        if (g != null) {
          originRow.putIfAbsent(g, () => r);
          originCol.putIfAbsent(g, () => c);
        }
      }
    }
    final r0 = originRow[cell]!;
    final c0 = originCol[cell]!;
    if (cell.rowSpan == 1 && cell.colSpan == 1) return;

    for (var r = r0; r < r0 + cell.rowSpan; r++) {
      final newForRow = <(int, TableCell)>[
        for (var c = c0; c < c0 + cell.colSpan; c++)
          if (!(r == r0 && c == c0)) (c, _emptyCell()),
      ];
      if (newForRow.isEmpty) continue;
      final merged = [
        for (final existing in table.rows[r].cells)
          (originCol[existing]!, existing),
        ...newForRow,
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      table.rows[r] = TableRow(cells: [for (final e in merged) e.$2]);
    }
    cell.rowSpan = 1;
    cell.colSpan = 1;

    context.document.reindexNestedNodes();
    executor.emit(DocumentEdited([table.id]));
  }
}

// --- Handlers --------------------------------------------------------

final List<EditRequestHandler> tableRequestHandlers = [
  (request) =>
      request is InsertTableRequest ? _InsertTableCommand(request) : null,
  (request) =>
      request is InsertTableRowRequest ? _InsertTableRowCommand(request) : null,
  (request) =>
      request is DeleteTableRowRequest ? _DeleteTableRowCommand(request) : null,
  (request) => request is InsertTableColumnRequest
      ? _InsertTableColumnCommand(request)
      : null,
  (request) => request is DeleteTableColumnRequest
      ? _DeleteTableColumnCommand(request)
      : null,
  (request) => request is MergeTableCellsRequest
      ? _MergeTableCellsCommand(request)
      : null,
  (request) =>
      request is SplitTableCellRequest ? _SplitTableCellCommand(request) : null,
];
