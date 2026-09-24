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

    expect(
      FocusManager.instance.primaryFocus?.hasFocus,
      isTrue,
      reason: 'bottom tap should focus',
    );
    expect(controller.composer.selection, isNotNull);
    expect(controller.focusedNodeId, 'a');
  });

  testWidgets('focus genuinely leaving the editor for another field clears '
      'focusedNodeId', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
      ),
    );
    final outsideFocus = FocusNode();
    addTearDown(outsideFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: outsideFocus),
              Expanded(child: QuireEditor(controller: controller)),
            ],
          ),
        ),
      ),
    );

    final editorNode = find.descendant(
      of: find.byType(QuireEditor),
      matching: find.byKey(const ValueKey('quire-node-a')),
    );
    await tester.tap(editorNode.first);
    await tester.pumpAndSettle();
    expect(controller.focusedNodeId, 'a');

    outsideFocus.requestFocus();
    await tester.pumpAndSettle();

    expect(controller.focusedNodeId, isNull);
  });
}
