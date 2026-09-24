import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

List<String> _texts(QuireEditorController c) =>
    c.document.nodes.whereType<TextNode>().map((n) => n.text.text).toList();

Future<void> _pumpFocusStart(
  WidgetTester t,
  QuireEditorController c,
  String nodeId,
) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: c)),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(findNode(nodeId));
  await t.pumpAndSettle();
  c.changeSelection(
    DocumentSelection.collapsed(
      DocumentPosition(nodeId, const TextNodePosition(0)),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('soft-keyboard backspace merges a non-empty paragraph up', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'p1', text: AttributedText('one')),
          TextNode(id: 'p2', text: AttributedText('two')),
        ],
      ),
    );
    await _pumpFocusStart(t, c, 'p2');
    // The delta actually deletes the sentinel only, not any of "two" — see
    // `document_input_client.dart`'s `_applyDeletion`.
    await backspace(t);
    await t.pumpAndSettle();
    expect(_texts(c), ['onetwo']);
  });

  testWidgets(
    'soft-keyboard backspace on an empty paragraph deletes the image above',
    (t) async {
      final c = QuireEditorController(
        document: MutableDocument(
          nodes: [
            ImageNode(id: 'img', url: '/tmp/x.png'),
            TextNode(id: 'p', text: AttributedText('')),
          ],
        ),
      );
      await _pumpFocusStart(t, c, 'p');
      await backspace(t);
      await t.pumpAndSettle();
      expect(c.document.getNodeById('img'), isNull);
    },
  );

  testWidgets('typing after the sentinel produces clean model text, no ZWSP', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'p', text: AttributedText(''))],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(findNode('p'));
    await t.pumpAndSettle();
    await replaceEntireText(t, 'hello');
    await t.pumpAndSettle();
    // Exact equality is the sentinel check: a leaked sentinel would show up
    // as a leading space here.
    expect((c.document.getNodeById('p')! as TextNode).text.text, 'hello');
  });

  testWidgets('select-all then delete empties the node, does not merge', (
    t,
  ) async {
    final c = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'p1', text: AttributedText('one')),
          TextNode(id: 'p2', text: AttributedText('two')),
        ],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: c)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(findNode('p2'));
    await t.pumpAndSettle();
    // Select this node's own text (not the sentinel) and delete it — a full
    // clear, not a backspace-at-start merge.
    c.changeSelection(
      DocumentSelection(
        base: DocumentPosition('p2', const TextNodePosition(0)),
        extent: DocumentPosition('p2', const TextNodePosition(3)),
      ),
    );
    await t.pumpAndSettle();
    await backspace(t);
    await t.pumpAndSettle();
    expect(c.document.getNodeById('p2'), isNotNull);
    expect((c.document.getNodeById('p2')! as TextNode).text.text, '');
  });
}
