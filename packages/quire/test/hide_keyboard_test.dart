import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

void main() {
  testWidgets(
    'the hide-keyboard button removes focus and leaves composer.selection '
    'unchanged',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                QuireToolbar(controller: controller),
                Expanded(child: QuireEditor(controller: controller)),
              ],
            ),
          ),
        ),
      );

      await tester.tap(findNode('a'));
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(3)),
        ),
      );
      await tester.pump();

      // Capture the field's own FocusNode (not just "some primaryFocus"),
      // since `unfocus()` hands focus back up to the enclosing FocusScope —
      // which then reports itself as `primaryFocus` and `hasFocus: true`.
      final fieldFocus = FocusManager.instance.primaryFocus;
      expect(fieldFocus?.hasFocus, isTrue);
      final selectionBefore = controller.composer.selection;

      await tester.tap(find.byTooltip('Hide keyboard'));
      await tester.pump();

      expect(fieldFocus?.hasFocus, isFalse);
      expect(controller.composer.selection, selectionBefore);
    },
  );
}
