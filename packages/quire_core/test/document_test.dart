import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _para(String id, String text) =>
    TextNode(id: id, text: AttributedText(text));

void main() {
  test('id index stays correct across insert/delete/replace/move', () {
    final doc = MutableDocument(nodes: [_para('a', 'A'), _para('b', 'B')]);

    doc.insertNodeAfter('a', _para('c', 'C'));
    expect(doc.nodes.map((n) => n.id), ['a', 'c', 'b']);
    expect(doc.getNodeById('c'), isNotNull);

    doc.deleteNode('c');
    expect(doc.nodes.map((n) => n.id), ['a', 'b']);
    expect(doc.getNodeById('c'), isNull);

    doc.insertNodeAt(0, _para('x', 'X'));
    expect(doc.nodes.map((n) => n.id), ['x', 'a', 'b']);

    expect(doc.getNodeIndexById('a'), 1);
    expect(doc.getNodeBefore('a')!.id, 'x');
    expect(doc.getNodeAfter('a')!.id, 'b');
    expect(doc.first.id, 'x');
    expect(doc.last.id, 'b');
    expect(doc.isEmpty, isFalse);
  });

  test('json round-trip of every node type', () {
    final doc = MutableDocument(
      nodes: [
        TextNode(
          id: 't1',
          text: AttributedText('hi', [
            AttributionSpan(const Attribution('bold'), 0, 2),
          ]),
          metadata: {'blockType': 'header1', 'indent': 2},
        ),
        ImageNode(id: 'i1', url: 'https://x/y.png', altText: 'alt'),
        HorizontalRuleNode(id: 'hr1'),
      ],
    );

    final restored = MutableDocument.fromJson(doc.toJson());
    expect(restored.nodes.length, 3);

    final t1 = restored.getNodeById('t1') as TextNode;
    expect(t1.text.text, 'hi');
    expect(t1.blockType, 'header1');
    expect(t1.indent, 2);
    expect(t1.text.attributionsAt(0), {const Attribution('bold')});

    final i1 = restored.getNodeById('i1') as ImageNode;
    expect(i1.url, 'https://x/y.png');
    expect(i1.altText, 'alt');

    expect(restored.getNodeById('hr1'), isA<HorizontalRuleNode>());
  });

  test('generateNodeId ids are unique, not just monotonic', () {
    // Regression test: a plain per-process counter (old `node-N`) restarts
    // from 'node-0' on every app launch, so reopening a persisted document
    // and creating a new node collides with an id already in that document.
    // A random component makes the sequence differ across "sessions" even
    // when the counter itself would otherwise restart from the same value.
    final ids = List.generate(200, (_) => generateNodeId());
    expect(ids.toSet().length, ids.length);
  });
}
