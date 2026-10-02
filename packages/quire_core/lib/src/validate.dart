import 'document.dart';
import 'nodes.dart';
import 'selection.dart';

/// Structural problems in [document] (and, if given, [selection]); empty when
/// the document is sound. Checks the invariants the editor relies on and
/// never throws, so it is safe to run on freshly loaded or corrupt data.
List<String> validateDocument(
  MutableDocument document, [
  DocumentSelection? selection,
]) {
  final problems = <String>[];
  final seen = <String>{};

  void checkNode(DocumentNode node) {
    if (!seen.add(node.id)) problems.add('duplicate id ${node.id}');
    if (document.getNodeById(node.id) == null) {
      problems.add('node ${node.id} missing from id index');
    }
    if (node is TextNode) {
      final length = node.text.text.length;
      for (final span in node.text.spans) {
        if (span.start < 0 || span.end > length || span.end <= span.start) {
          problems.add(
            'node ${node.id}: span ${span.start}-${span.end} outside 0-$length',
          );
        }
      }
    } else if (node is TableNode) {
      if (node.rows.isEmpty) problems.add('table ${node.id} has no rows');
      for (final row in node.rows) {
        for (final cell in row.cells) {
          if (cell.rowSpan < 1 || cell.colSpan < 1) {
            problems.add('table ${node.id}: span below 1');
          }
          if (cell.nodes.isEmpty) {
            problems.add('table ${node.id}: cell with no nodes');
          }
          cell.nodes.forEach(checkNode);
        }
      }
      if (node.rows.isNotEmpty &&
          node.grid.any((row) => row.any((cell) => cell == null))) {
        problems.add('table ${node.id}: grid has an uncovered position');
      }
    }
  }

  document.nodes.forEach(checkNode);

  void checkPosition(String label, DocumentPosition position) {
    final node = document.getNodeById(position.nodeId);
    if (node == null) {
      problems.add('$label points at missing node ${position.nodeId}');
      return;
    }
    final at = position.nodePosition;
    if (at is TextNodePosition) {
      if (node is! TextNode) {
        problems.add('$label has a text position in non-text ${node.id}');
      } else if (at.offset < 0 || at.offset > node.text.text.length) {
        problems.add('$label offset ${at.offset} outside node ${node.id}');
      }
    } else if (node is TextNode) {
      problems.add('$label has a block position in text node ${node.id}');
    }
  }

  if (selection != null) {
    checkPosition('selection base', selection.base);
    checkPosition('selection extent', selection.extent);
  }
  return problems;
}
