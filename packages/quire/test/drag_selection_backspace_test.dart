import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

// Bug repro (pre-rewrite): a drag-made selection was only ever written to
// `composer.selection` — the focused field's own local TextEditingValue
// selection never moved, so a physical Backspace with a same-node
// (not cross-node) drag selection active fell through to a collapsed-caret
// branch instead of deleting the highlighted range. There is no per-node
// field/local selection any more — `composer.selection` is the only
// selection there is — so this is now just "does a same-node drag selection
// delete correctly" through the real delta path a soft keyboard uses.

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('backspace with a same-node drag selection deletes the '
      'selected range, not just a stale collapsed caret', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(findNode('a'));
    await tester.pumpAndSettle();

    // Simulates a drag-select of "world".
    controller.changeSelection(
      const DocumentSelection(
        base: DocumentPosition('a', TextNodePosition(6)),
        extent: DocumentPosition('a', TextNodePosition(11)),
      ),
    );
    await tester.pump();

    await backspace(tester);
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello ',
    );
  });
}
