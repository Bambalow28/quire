import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Per-child grid placement for [TableGrid] — set with [TableCellData].
class TableGridParentData extends ContainerBoxParentData<RenderBox> {
  int row = 0;
  int column = 0;
  int rowSpan = 1;
  int colSpan = 1;
}

/// Attaches grid coordinates to a [TableGrid] child.
class TableCellData extends ParentDataWidget<TableGridParentData> {
  const TableCellData({
    super.key,
    required this.row,
    required this.column,
    this.rowSpan = 1,
    this.colSpan = 1,
    required super.child,
  });

  final int row;
  final int column;
  final int rowSpan;
  final int colSpan;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as TableGridParentData;
    var needsLayout = false;
    if (parentData.row != row) {
      parentData.row = row;
      needsLayout = true;
    }
    if (parentData.column != column) {
      parentData.column = column;
      needsLayout = true;
    }
    if (parentData.rowSpan != rowSpan) {
      parentData.rowSpan = rowSpan;
      needsLayout = true;
    }
    if (parentData.colSpan != colSpan) {
      parentData.colSpan = colSpan;
      needsLayout = true;
    }
    if (needsLayout) {
      final targetParent = renderObject.parent;
      if (targetParent is RenderObject) targetParent.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => TableGrid;
}

/// Renders children on a grid where a child may span multiple rows/columns
/// (via [TableCellData]) — something Flutter's own `Table` cannot do.
class TableGrid extends MultiChildRenderObjectWidget {
  const TableGrid({
    super.key,
    required super.children,
    required this.rowCount,
    required this.columnCount,
    this.columnWidths,
    required this.borderColor,
  });

  final int rowCount;
  final int columnCount;

  /// Fractions of the available width, one per column, summing to 1. `null`
  /// means equal-width columns.
  final List<double>? columnWidths;
  final Color borderColor;

  @override
  RenderTableGrid createRenderObject(BuildContext context) => RenderTableGrid(
    rowCount: rowCount,
    columnCount: columnCount,
    columnWidths: columnWidths,
    borderColor: borderColor,
  );

  @override
  void updateRenderObject(BuildContext context, RenderTableGrid renderObject) {
    renderObject
      ..rowCount = rowCount
      ..columnCount = columnCount
      ..columnWidths = columnWidths
      ..borderColor = borderColor;
  }
}

class _Entry {
  _Entry(this.child, this.data, this.height);
  final RenderBox child;
  final TableGridParentData data;
  final double height;
}

/// Lays children out on a row/column grid, honoring row/column spans.
///
/// Algorithm: every column gets a fixed width up front (from
/// [columnWidths], or equal shares). Each child is laid out at the width of
/// the columns it spans and measured for its natural height. Row heights are
/// then resolved by processing children in order of the row their span
/// *ends* in — by the time a spanning child is processed, every row before
/// its last one already has a final height (from a child ending there), so
/// the spanning child only needs to supply whatever height is left over for
/// its last row. Children are positioned from the resulting column/row
/// offsets, and borders are painted as the outline of each child's
/// (possibly multi-cell) rectangle, so a merged cell gets no border through
/// its middle.
class RenderTableGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TableGridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, TableGridParentData> {
  RenderTableGrid({
    required int rowCount,
    required int columnCount,
    required List<double>? columnWidths,
    required Color borderColor,
  }) : _rowCount = rowCount,
       _columnCount = columnCount,
       _columnWidths = columnWidths,
       _borderColor = borderColor;

  int _rowCount;
  int get rowCount => _rowCount;
  set rowCount(int value) {
    if (_rowCount == value) return;
    _rowCount = value;
    markNeedsLayout();
  }

  int _columnCount;
  int get columnCount => _columnCount;
  set columnCount(int value) {
    if (_columnCount == value) return;
    _columnCount = value;
    markNeedsLayout();
  }

  List<double>? _columnWidths;
  List<double>? get columnWidths => _columnWidths;
  set columnWidths(List<double>? value) {
    // By value: the widget layer rebuilds this list every frame, so an
    // identity check would relayout the whole table on every rebuild.
    if (listEquals(_columnWidths, value)) return;
    _columnWidths = value;
    markNeedsLayout();
  }

  Color _borderColor;
  Color get borderColor => _borderColor;
  set borderColor(Color value) {
    if (_borderColor == value) return;
    _borderColor = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderObject child) {
    child.parentData = TableGridParentData();
  }

  List<double> _resolveColumnOffsets(double width) {
    final fractions =
        (columnWidths != null && columnWidths!.length == columnCount)
        ? columnWidths!
        : List.filled(columnCount, columnCount == 0 ? 0.0 : 1.0 / columnCount);
    final offsets = <double>[0];
    for (final fraction in fractions) {
      offsets.add(offsets.last + fraction * width);
    }
    return offsets;
  }

  double _columnSpanWidth(
    List<double> columnOffsets,
    int column,
    int colSpan,
  ) =>
      columnOffsets[(column + colSpan).clamp(0, columnCount)] -
      columnOffsets[column.clamp(0, columnCount)];

  ({List<double> columnOffsets, List<double> rowOffsets, Size size})
  _resolveGeometry(BoxConstraints constraints, bool dry) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    final columnOffsets = _resolveColumnOffsets(width);
    final rowHeights = List<double>.filled(rowCount, 0);
    final entries = <_Entry>[];

    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as TableGridParentData;
      final childWidth = _columnSpanWidth(
        columnOffsets,
        data.column,
        data.colSpan,
      );
      final childConstraints = BoxConstraints.tightFor(width: childWidth);
      double height;
      if (dry) {
        height = ChildLayoutHelper.dryLayoutChild(
          child,
          childConstraints,
        ).height;
      } else {
        child.layout(childConstraints, parentUsesSize: true);
        height = child.size.height;
      }
      entries.add(_Entry(child, data, height));
      child = data.nextSibling;
    }

    entries.sort(
      (a, b) =>
          (a.data.row + a.data.rowSpan).compareTo(b.data.row + b.data.rowSpan),
    );
    for (final entry in entries) {
      final endRow = (entry.data.row + entry.data.rowSpan - 1).clamp(
        0,
        rowCount - 1,
      );
      if (entry.data.rowSpan <= 1) {
        rowHeights[endRow] = entry.height > rowHeights[endRow]
            ? entry.height
            : rowHeights[endRow];
        continue;
      }
      var priorHeight = 0.0;
      for (var r = entry.data.row; r < endRow; r++) {
        priorHeight += rowHeights[r];
      }
      final needed = entry.height - priorHeight;
      if (needed > rowHeights[endRow]) rowHeights[endRow] = needed;
    }

    final rowOffsets = <double>[0];
    for (final h in rowHeights) {
      rowOffsets.add(rowOffsets.last + h);
    }

    if (!dry) {
      // Second pass: re-lay every child at the full height of the rows it
      // spans. Without it a short cell keeps its natural height, which both
      // draws a stunted border inside a taller row and leaves the rest of
      // the cell dead to taps — tapping any part of a cell must put the
      // caret in it.
      for (final entry in entries) {
        final data = entry.data;
        final endRow = (data.row + data.rowSpan).clamp(0, rowCount);
        entry.child.layout(
          BoxConstraints.tightFor(
            width: _columnSpanWidth(columnOffsets, data.column, data.colSpan),
            height: rowOffsets[endRow] - rowOffsets[data.row],
          ),
          parentUsesSize: true,
        );
        data.offset = Offset(columnOffsets[data.column], rowOffsets[data.row]);
      }
    }

    return (
      columnOffsets: columnOffsets,
      rowOffsets: rowOffsets,
      size: constraints.constrain(Size(width, rowOffsets.last)),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _resolveGeometry(constraints, true).size;

  @override
  void performLayout() {
    size = _resolveGeometry(constraints, false).size;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as TableGridParentData;
      final rect = (offset + data.offset) & child.size;
      context.canvas.drawRect(rect, paint);
      child = data.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
