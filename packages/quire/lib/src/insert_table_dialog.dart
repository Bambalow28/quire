import 'package:flutter/material.dart';

/// Word/Docs-style drag-to-size grid picker, offered to [showInsertTableDialog].
const int _gridColumns = 10;
const int _gridRows = 8;
// 10 columns must fit inside the dialog on the narrowest phone we support:
// 10 x (18 + 4) = 220pt, versus ~280pt of usable dialog width at 320pt.
const double _cellSize = 18.0;
const double _cellGap = 4.0;
const double _cellStride = _cellSize + _cellGap;

/// Shows a dialog for picking a table size the way Word/Google Docs do (drag
/// or tap across a grid), with a Create/Cancel confirmation. Returns the
/// picked `(rows, columns)`, or `null` if the user cancelled.
Future<({int rows, int columns})?> showInsertTableDialog(BuildContext context) {
  return showDialog<({int rows, int columns})>(
    context: context,
    builder: (context) => const _InsertTableDialog(),
  );
}

class _InsertTableDialog extends StatefulWidget {
  const _InsertTableDialog();

  @override
  State<_InsertTableDialog> createState() => _InsertTableDialogState();
}

class _InsertTableDialogState extends State<_InsertTableDialog> {
  int _columns = 3;
  int _rows = 3;

  void _select(int columns, int rows) {
    if (columns == _columns && rows == _rows) return;
    setState(() {
      _columns = columns;
      _rows = rows;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert table'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$_columns × $_rows Table'),
          const SizedBox(height: 12),
          _TableSizeGrid(
            selectedColumns: _columns,
            selectedRows: _rows,
            onChanged: _select,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop((rows: _rows, columns: _columns)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// The drag-to-size grid itself: one [GestureDetector] over the whole grid
/// (not one per cell) hit-tests the pointer position against the grid
/// geometry to find the hovered cell.
class _TableSizeGrid extends StatelessWidget {
  const _TableSizeGrid({
    required this.selectedColumns,
    required this.selectedRows,
    required this.onChanged,
  });

  final int selectedColumns;
  final int selectedRows;
  final void Function(int columns, int rows) onChanged;

  (int, int) _cellAt(Offset local) {
    final column =
        (local.dx / _cellStride).floor().clamp(0, _gridColumns - 1) + 1;
    final row = (local.dy / _cellStride).floor().clamp(0, _gridRows - 1) + 1;
    return (column, row);
  }

  void _handle(Offset local) {
    final (column, row) = _cellAt(local);
    onChanged(column, row);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$selectedColumns by $selectedRows table',
      liveRegion: true,
      child: GestureDetector(
        key: const ValueKey('quireTableSizeGrid'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => _handle(details.localPosition),
        onTapUp: (details) => _handle(details.localPosition),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 1; r <= _gridRows; r++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var c = 1; c <= _gridColumns; c++)
                    Padding(
                      padding: const EdgeInsets.all(_cellGap / 2),
                      child: Container(
                        width: _cellSize,
                        height: _cellSize,
                        decoration: BoxDecoration(
                          color: (c <= selectedColumns && r <= selectedRows)
                              ? scheme.primary
                              : Colors.transparent,
                          border: Border.all(color: scheme.outline),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
