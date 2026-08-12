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
    },
  );
}
