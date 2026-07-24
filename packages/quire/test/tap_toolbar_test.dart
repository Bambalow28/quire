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
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
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
}
