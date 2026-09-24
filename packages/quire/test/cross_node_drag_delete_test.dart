import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

// Bug repro (pre-rewrite): a drag-select that starts at the very beginning
// of a node's text (the natural way to select "from the top" of a
// checklist) left that node's own field-local caret collapsed right after
// the leading sentinel. A soft-keyboard delete there looked identical to
// "backspace at start of paragraph", so it merged instead of deleting the
// real, visible cross-node selection. The new DeltaTextInputClient tracks
// cross-node mode explicitly (see `document_input_client.dart`), so this is
// now just "does a cross-node selection delete correctly".

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
  testWidgets(
    'a drag-select spanning multiple checklist items, started at the first '
    'item\'s very first character, is deleted by a soft-keyboard delete',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText('first item'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(
              id: 'b',
              text: AttributedText('second item'),
              metadata: {'blockType': 'listItemTask'},
            ),
            TextNode(
              id: 'c',
              text: AttributedText('third item'),
              metadata: {'blockType': 'listItemTask'},
            ),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      final start = tester.getTopLeft(findNode('a')) + const Offset(2, 8);
      final end = tester.getTopLeft(findNode('c')) + const Offset(4, 8);

      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.base.nodeId, isNot(selection.extent.nodeId));

      // A soft-keyboard delete over the (visible, cross-node) selection.
      await backspace(tester);
      await tester.pump();

      expect(
        controller.document.nodes.length,
        lessThan(3),
        reason: 'the visible cross-node selection should have been deleted',
      );
    },
  );
}
