import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets('tapping low in an empty document focuses the editor', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 60), // stand-in for the title field
              Expanded(child: QuireEditor(controller: controller)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorRect = tester.getRect(find.byType(QuireEditor));
    // Near the bottom of the editor area — far below the single empty line.
    await tester.tapAt(Offset(editorRect.center.dx, editorRect.bottom - 20));
    await tester.pumpAndSettle();

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue, reason: 'bottom tap should focus');
    expect(controller.composer.selection, isNotNull);
  });
}
