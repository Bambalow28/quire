import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _para(String id, String text) =>
    TextNode(id: id, text: AttributedText(text));

void main() {
  final doc = MutableDocument(
    nodes: [_para('a', 'hello'), _para('b', 'world')],
  );

  test('normalize orders forward selections (same node)', () {
    final selection = DocumentSelection(
      base: DocumentPosition('a', const TextNodePosition(1)),
      extent: DocumentPosition('a', const TextNodePosition(4)),
    );
    final (start, end) = selection.normalize(doc);
    expect(start.nodePosition, const TextNodePosition(1));
    expect(end.nodePosition, const TextNodePosition(4));
  });

  test('normalize orders backward selections (same node)', () {
    final selection = DocumentSelection(
      base: DocumentPosition('a', const TextNodePosition(4)),
      extent: DocumentPosition('a', const TextNodePosition(1)),
    );
    final (start, end) = selection.normalize(doc);
    expect(start.nodePosition, const TextNodePosition(1));
    expect(end.nodePosition, const TextNodePosition(4));
  });

  test('normalize orders forward selections (cross node)', () {
    final selection = DocumentSelection(
      base: DocumentPosition('a', const TextNodePosition(2)),
      extent: DocumentPosition('b', const TextNodePosition(3)),
    );
    final (start, end) = selection.normalize(doc);
    expect(start.nodeId, 'a');
    expect(end.nodeId, 'b');
  });

  test('normalize orders backward selections (cross node)', () {
    final selection = DocumentSelection(
      base: DocumentPosition('b', const TextNodePosition(3)),
      extent: DocumentPosition('a', const TextNodePosition(2)),
    );
    final (start, end) = selection.normalize(doc);
    expect(start.nodeId, 'a');
    expect(end.nodeId, 'b');
  });

  test('collapseDownstream / collapseUpstream', () {
    final selection = DocumentSelection(
      base: DocumentPosition('b', const TextNodePosition(3)),
      extent: DocumentPosition('a', const TextNodePosition(2)),
    );
    final downstream = selection.collapseDownstream(doc);
    expect(downstream.isCollapsed, isTrue);
    expect(downstream.extent.nodeId, 'b');

    final upstream = selection.collapseUpstream(doc);
    expect(upstream.isCollapsed, isTrue);
    expect(upstream.extent.nodeId, 'a');
  });

  test('DocumentSelection.collapsed', () {
    final position = DocumentPosition('a', const TextNodePosition(2));
    final selection = DocumentSelection.collapsed(position);
    expect(selection.isCollapsed, isTrue);
    expect(selection.base, position);
    expect(selection.extent, position);
  });
}
