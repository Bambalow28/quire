import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

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

    final target =
        tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 8);

    await tester.tapAt(target); // places the caret + focuses
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(state.selectionOverlay?.toolbarIsVisible ?? false, isFalse);

    await tester.tapAt(target); // same spot again → options
    await tester.pumpAndSettle();
    expect(state.selectionOverlay?.toolbarIsVisible ?? false, isTrue);
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

      final start = tester.getTopLeft(find.byType(EditableText)) +
          const Offset(4, 8);
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
      // before this fix) and the toolbar comes up instead.
      expect(controller.composer.selection?.isCollapsed ?? true, isFalse);
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      expect(state.selectionOverlay?.toolbarIsVisible ?? false, isTrue);

      // Not just *a* toolbar — the field's own local selection (what
      // EditableText's built-in toolbar actually reads Cut/Copy/Paste
      // availability from) must also still be the real non-collapsed range,
      // or the toolbar that opens only offers Select/Select All, same as it
      // would for a collapsed caret.
      expect(state.textEditingValue.selection.isCollapsed, isFalse);
      expect(
        state.contextMenuButtonItems.map((i) => i.type),
        contains(ContextMenuButtonType.copy),
      );
    },
  );

  testWidgets(
    'tapping inside a selection that spans two paragraphs shows Copy/Cut '
    'without leaving the tapped node with a local selection to double-paint',
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

      final fieldAFinder = find.byType(EditableText).first;
      final fieldBFinder = find.byType(EditableText).at(1);
      final start = tester.getTopLeft(fieldAFinder) + const Offset(4, 8);
      final end = tester.getTopLeft(fieldBFinder) + const Offset(30, 8);

      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.base.nodeId, isNot(selection.extent.nodeId));

      final tapPoint = tester.getTopLeft(fieldAFinder) + const Offset(20, 8);
      await tester.tapAt(tapPoint);
      await tester.pumpAndSettle();

      // The document-wide selection survives, and node a's own local
      // selection stays collapsed — the fix that shows Copy/Cut here does
      // NOT do it by giving this field a real (or cosmetic) non-collapsed
      // local selection, which would double-paint against
      // SelectionOverlayPainter (see _computeOverlayRects).
      expect(controller.composer.selection?.isCollapsed ?? true, isFalse);
      final fieldA = tester.widget<EditableText>(fieldAFinder);
      expect(fieldA.controller.selection.isCollapsed, isTrue);

      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Cut'), findsOneWidget);
    },
  );
}
