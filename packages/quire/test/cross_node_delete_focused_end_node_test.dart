import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

// Bug repro (pre-rewrite): a soft-keyboard backspace over a cross-node
// (drag-made) selection whose FOCUSED field was the selection's END node
// used to tear down that very node's NodeTextController while it was still
// mid-notifyListeners, silently failing to apply. There is no per-node
// controller any more — this now just asserts the end-to-end behaviour still
// holds with the new DeltaTextInputClient.

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
    'soft-keyboard backspace over a cross-node selection whose focused '
    'field is the selection\'s end node still deletes on the first try',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('one')),
            TextNode(id: 'b', text: AttributedText('two')),
            TextNode(id: 'c', text: AttributedText('three')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      // Focus lands on 'c' — the node the soft keyboard will talk to.
      await tester.tap(findNode('c'));
      await tester.pumpAndSettle();
      expect(controller.focusedNodeId, 'c');

      // A drag made a cross-node selection from partway into 'a' to partway
      // into 'c' — 'b' is fully covered and gets dropped entirely, 'c' (the
      // focused end node) is merged away, and 'a' (the start node) survives.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(1)),
          extent: DocumentPosition('c', const TextNodePosition(2)),
        ),
      );
      await tester.pump();
      expect(controller.focusedNodeId, 'c');

      await backspace(tester);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final remaining = controller.document.nodes.single as TextNode;
      expect(remaining.id, 'a');
      // 'a''s prefix (up to offset 1, "o") + 'c''s suffix from offset 2
      // ("ree").
      expect(remaining.text.text, 'oree');
    },
  );
}
