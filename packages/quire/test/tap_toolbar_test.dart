import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

import 'support/ime.dart';

void main() {
  testWidgets('tapping the caret again opens the selection toolbar', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuireEditor(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    final target = tester.getTopLeft(findNode('a')) + const Offset(20, 8);

    await tester.tapAt(target); // places the caret + focuses
    await tester.pumpAndSettle();
    expect(find.text('Select'), findsNothing);

    await tapAgain(tester, target); // same spot again → options
    await tester.pumpAndSettle();
    expect(find.text('Select'), findsOneWidget);
  });

  testWidgets(
    'tapping inside a drag-selected range opens the toolbar instead of collapsing it',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      final start = tester.getTopLeft(findNode('a')) + const Offset(4, 8);
      final end = start + const Offset(60, 0);

      // Touch drag-to-select starts from a long-press hold (see
      // `_touchHold` in quire_editor.dart), not an immediate drag.
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.isCollapsed, isFalse);

      final midpoint = Offset.lerp(start, end, 0.5)!;
      await tester.tapAt(midpoint);
      await tester.pumpAndSettle();

      // The selection survives the tap (would have collapsed to a caret
      // before this fix) and the toolbar comes up instead, with Copy/Cut
      // available (not just Select/Select All, which is what a collapsed
      // caret's menu would offer).
      expect(controller.composer.selection?.isCollapsed ?? true, isFalse);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Cut'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping inside a selection that spans two paragraphs shows Copy/Cut '
    'without collapsing the document-wide selection',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph here')),
            TextNode(id: 'b', text: AttributedText('second paragraph here')),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      final start = tester.getTopLeft(findNode('a')) + const Offset(4, 8);
      final end = tester.getTopLeft(findNode('b')) + const Offset(30, 8);

      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.base.nodeId, isNot(selection.extent.nodeId));

      final tapPoint = tester.getTopLeft(findNode('a')) + const Offset(20, 8);
      await tester.tapAt(tapPoint);
      await tester.pumpAndSettle();

      // The document-wide selection survives the tap.
      expect(controller.composer.selection?.isCollapsed ?? true, isFalse);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Cut'), findsOneWidget);
    },
  );
}
