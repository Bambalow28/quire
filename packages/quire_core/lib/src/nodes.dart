import 'attributed_text.dart';

/// A position within a single node's content (interpretation depends on node
/// type).
abstract class NodePosition {
  const NodePosition();

  Map<String, Object?> toJson();
}

NodePosition nodePositionFromJson(Map<String, Object?> json) {
  switch (json['type']) {
    case 'text':
      return TextNodePosition(json['offset'] as int);
    case 'upstreamDownstream':
      return (json['isUpstream'] as bool)
          ? const UpstreamDownstreamNodePosition.upstream()
          : const UpstreamDownstreamNodePosition.downstream();
    default:
      throw ArgumentError('Unknown NodePosition type: ${json['type']}');
  }
}

/// Caret offset into a [TextNode]'s text.
class TextNodePosition extends NodePosition {
  const TextNodePosition(this.offset);

  final int offset;

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'offset': offset};

  @override
  bool operator ==(Object other) =>
      other is TextNodePosition && other.offset == offset;

  @override
  int get hashCode => offset.hashCode;

  @override
  String toString() => 'TextNodePosition($offset)';
}

/// Caret position relative to an atomic block node (image, HR): either just
/// before it (upstream) or just after it (downstream).
class UpstreamDownstreamNodePosition extends NodePosition {
  const UpstreamDownstreamNodePosition._(this.isUpstream);

  const UpstreamDownstreamNodePosition.upstream() : this._(true);
  const UpstreamDownstreamNodePosition.downstream() : this._(false);

  final bool isUpstream;

  @override
  Map<String, Object?> toJson() => {
    'type': 'upstreamDownstream',
    'isUpstream': isUpstream,
  };

  @override
  bool operator ==(Object other) =>
      other is UpstreamDownstreamNodePosition && other.isUpstream == isUpstream;

  @override
  int get hashCode => isUpstream.hashCode;

  @override
  String toString() => isUpstream
      ? 'UpstreamDownstreamNodePosition.upstream()'
      : 'UpstreamDownstreamNodePosition.downstream()';
}

/// A registry mapping a node's JSON `type` tag to a `fromJson` factory, so
/// new node types can register themselves without editing a switch here.
typedef NodeFromJson = DocumentNode Function(Map<String, Object?> json);

final Map<String, NodeFromJson> nodeTypeRegistry = {
  'text': TextNode.fromJson,
  'image': ImageNode.fromJson,
  'horizontalRule': HorizontalRuleNode.fromJson,
  'table': TableNode.fromJson,
};

DocumentNode nodeFromJson(Map<String, Object?> json) {
  final type = json['type'] as String;
  final factory = nodeTypeRegistry[type];
  if (factory == null) {
    throw ArgumentError('Unknown node type in JSON: $type');
  }
  return factory(json);
}

abstract class DocumentNode {
  DocumentNode(this.id, {Map<String, Object?>? metadata})
    : metadata = metadata ?? {};

  final String id;
  Map<String, Object?> metadata;

  String get type;

  Map<String, Object?> toJson();
}

/// Paragraphs, headings, list items, blockquotes, code blocks — all
/// distinguished by `metadata['blockType']`.
class TextNode extends DocumentNode {
  TextNode({
    required String id,
    required this.text,
    Map<String, Object?>? metadata,
  }) : super(id, metadata: metadata);

  AttributedText text;

  String get blockType => metadata['blockType'] as String? ?? 'paragraph';
  int get indent => metadata['indent'] as int? ?? 0;
  bool get isChecked => metadata['checked'] == true;
  String get textAlign => metadata['textAlign'] as String? ?? 'left';
  double get lineSpacing => (metadata['lineSpacing'] as num?)?.toDouble() ?? 1.0;

  @override
  String get type => 'text';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'text': text.toJson(),
    'metadata': metadata,
  };

  factory TextNode.fromJson(Map<String, Object?> json) => TextNode(
    id: json['id'] as String,
    text: AttributedText.fromJson(json['text'] as Map<String, Object?>),
    metadata: Map<String, Object?>.from(
      json['metadata'] as Map<String, Object?>? ?? const {},
    ),
  );
}

class ImageNode extends DocumentNode {
  ImageNode({
    required String id,
    required this.url,
    this.altText,
    Map<String, Object?>? metadata,
  }) : super(id, metadata: metadata);

  String url;
  String? altText;

  @override
  String get type => 'image';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'url': url,
    'altText': altText,
    'metadata': metadata,
  };

  factory ImageNode.fromJson(Map<String, Object?> json) => ImageNode(
    id: json['id'] as String,
    url: json['url'] as String,
    altText: json['altText'] as String?,
    metadata: Map<String, Object?>.from(
      json['metadata'] as Map<String, Object?>? ?? const {},
    ),
  );
}

/// A single cell of a [TableNode]'s grid: a list of block nodes (so a cell
/// can hold more than one paragraph) plus how many grid rows/columns it
/// spans. `rowSpan`/`colSpan` default to `1`.
class TableCell {
  TableCell({required this.nodes, this.rowSpan = 1, this.colSpan = 1});

  List<DocumentNode> nodes;
  int rowSpan;
  int colSpan;

  Map<String, Object?> toJson() => {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'rowSpan': rowSpan,
    'colSpan': colSpan,
  };

  factory TableCell.fromJson(Map<String, Object?> json) => TableCell(
    nodes: (json['nodes'] as List)
        .map((n) => nodeFromJson(n as Map<String, Object?>))
        .toList(),
    rowSpan: json['rowSpan'] as int? ?? 1,
    colSpan: json['colSpan'] as int? ?? 1,
  );
}

/// One row of a [TableNode]. Only holds the cells that *originate* in this
/// row — see [TableNode] for the sparse-storage invariant.
class TableRow {
  TableRow({required this.cells});

  List<TableCell> cells;

  Map<String, Object?> toJson() => {
    'cells': cells.map((c) => c.toJson()).toList(),
  };

  factory TableRow.fromJson(Map<String, Object?> json) => TableRow(
    cells: (json['cells'] as List)
        .map((c) => TableCell.fromJson(c as Map<String, Object?>))
        .toList(),
  );
}

/// A table.
///
/// Storage is **sparse**, the way HTML tables are: [rows] holds only the
/// cells that originate at that grid position. A cell covered by another
/// cell's [TableCell.rowSpan]/[TableCell.colSpan] is *not* present in [rows]
/// at all — it is only reachable by resolving spans. Use [grid], [gridSize]
/// or [cellAt] to resolve the full grid (including covered positions) rather
/// than reinventing span resolution at each call site.
class TableNode extends DocumentNode {
  TableNode({
    required String id,
    required this.rows,
    Map<String, Object?>? metadata,
  }) : super(id, metadata: metadata);

  /// At least one row; each row holds only its origin cells.
  List<TableRow> rows;

  /// Column widths as fractions summing to 1, or `null` for equal widths.
  List<double>? get columnWidths {
    final widths = metadata['columnWidths'];
    if (widths is List) {
      return widths.map((w) => (w as num).toDouble()).toList();
    }
    return null;
  }

  @override
  String get type => 'table';

  /// Resolves [rows] into a full row-major grid: a cell that spans multiple
  /// positions appears (the same instance) at every position it covers. A
  /// grid position with no cell (should not happen given a well-formed
  /// table) resolves to `null`.
  ///
  /// Algorithm: walk rows top to bottom. For each column, track the grid row
  /// index one-past the last row still reserved by an earlier cell's
  /// [TableCell.rowSpan] (`reservedUntil`). At each column of the current
  /// row: if still reserved, repeat the reserving cell; otherwise consume
  /// the next cell from this row's own (origin) list and stamp it across the
  /// columns/rows it spans.
  List<List<TableCell?>> get grid {
    final result = List.generate(rows.length, (_) => <TableCell?>[]);
    final reservedUntil = <int>[];
    final occupant = <TableCell?>[];
    var columnCount = 0;

    int reservedUntilAt(int column) =>
        column < reservedUntil.length ? reservedUntil[column] : 0;
    void growTo(int column) {
      while (reservedUntil.length <= column) {
        reservedUntil.add(0);
        occupant.add(null);
      }
    }

    for (var r = 0; r < rows.length; r++) {
      final cells = rows[r].cells;
      var column = 0;
      var index = 0;
      while (index < cells.length || reservedUntilAt(column) > r) {
        if (reservedUntilAt(column) > r) {
          result[r].add(occupant[column]);
          column++;
          continue;
        }
        final cell = cells[index++];
        for (var s = 0; s < cell.colSpan; s++) {
          final c = column + s;
          growTo(c);
          result[r].add(cell);
          reservedUntil[c] = r + cell.rowSpan;
          occupant[c] = cell;
        }
        column += cell.colSpan;
      }
      if (column > columnCount) columnCount = column;
    }
    for (final row in result) {
      while (row.length < columnCount) {
        row.add(null);
      }
    }
    return result;
  }

  /// `(rowCount, columnCount)` of the resolved [grid].
  (int, int) get gridSize {
    final g = grid;
    return (g.length, g.isEmpty ? 0 : g[0].length);
  }

  /// The cell occupying grid position ([row], [column]) — resolving spans —
  /// or `null` if out of bounds.
  TableCell? cellAt(int row, int column) {
    final g = grid;
    if (row < 0 || row >= g.length) return null;
    if (column < 0 || column >= g[row].length) return null;
    return g[row][column];
  }

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'rows': rows.map((r) => r.toJson()).toList(),
    'metadata': metadata,
  };

  factory TableNode.fromJson(Map<String, Object?> json) => TableNode(
    id: json['id'] as String,
    rows: (json['rows'] as List)
        .map((r) => TableRow.fromJson(r as Map<String, Object?>))
        .toList(),
    metadata: Map<String, Object?>.from(
      json['metadata'] as Map<String, Object?>? ?? const {},
    ),
  );
}

class HorizontalRuleNode extends DocumentNode {
  HorizontalRuleNode({required String id, Map<String, Object?>? metadata})
    : super(id, metadata: metadata);

  @override
  String get type => 'horizontalRule';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'metadata': metadata,
  };

  factory HorizontalRuleNode.fromJson(Map<String, Object?> json) =>
      HorizontalRuleNode(
        id: json['id'] as String,
        metadata: Map<String, Object?>.from(
          json['metadata'] as Map<String, Object?>? ?? const {},
        ),
      );
}
