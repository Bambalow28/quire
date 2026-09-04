import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Bug repro: a drag-select that starts at the very beginning of a node's
// text (the natural way to select "from the top" of a checklist) leaves
// that node's own field-local caret collapsed right after the leading
// sentinel (see `_pushModelToControllers`). A soft-keyboard delete there
// looks identical to "backspace at start of paragraph" — the sentinel is
// gone, text otherwise unchanged — so `_onControllerChanged` routed it to
// `mergeWithPrevious` instead of deleting the real, visible cross-node
// selection, silently doing nothing when that node has no previous sibling
// to merge into.

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
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

      final start =
          tester.getTopLeft(find.byType(EditableText).at(0)) +
          const Offset(2, 8);
      final end =
          tester.getTopLeft(find.byType(EditableText).at(2)) +
          const Offset(4, 8);

      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.base.nodeId, isNot(selection.extent.nodeId));

      final focusedId = controller.focusedNodeId!;
      final idx = controller.document.nodesInDocumentOrder
          .toList()
          .indexWhere((n) => n.id == focusedId);
      final fieldFinder = find.byType(EditableText).at(idx);
      final fieldController = tester
          .widget<EditableText>(fieldFinder)
          .controller;
      final localSel = fieldController.selection;

      // The real OS backspace with a collapsed local caret: removes ONE
      // char before it — no key event, just a text diff.
      final fieldText = fieldController.text;
      final newFieldText = fieldText.replaceRange(
        localSel.start - 1,
        localSel.start,
        '',
      );
      await tester.enterText(fieldFinder, newFieldText);
      await tester.pump();

      expect(
        controller.document.nodes.length,
        lessThan(3),
        reason: 'the visible cross-node selection should have been deleted',
      );
    },
  );
}
