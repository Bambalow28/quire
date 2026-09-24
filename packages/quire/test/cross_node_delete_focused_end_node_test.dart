import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Bug repro: a soft-keyboard backspace over a cross-node (drag-made)
// selection whose FOCUSED field is the selection's END node — the node
// `_DeleteSelectionCommand` disposes via `_syncControllers`, not the one it
// merges into. `_onControllerChanged`'s cross-node branch used to call
// `replaceSelectionWithText` synchronously, tearing down that very
// NodeTextController while it was still mid-notifyListeners (this callback
// IS that notification) — the delete silently failed to apply until
// something else (undo) forced a clean resync. See quire_editor.dart
// `_onControllerChanged`.

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

      // Focus lands on 'c' — the field the soft keyboard will talk to.
      await tester.tap(find.byType(EditableText).last);
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

      // Soft-keyboard backspace: the OS edits the focused field's ('c')
      // own text directly, one character shorter, with no key event at all.
      await tester.enterText(find.byType(EditableText).last, 'thre');
      await tester.pump();
      // The delete is deferred to a microtask (see `_onControllerChanged`) —
      // flush it.
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
