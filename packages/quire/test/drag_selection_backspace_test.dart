import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

// Bug repro: a drag-made selection is only ever written to
// `composer.selection` (see `_extendDocumentDragTo` in quire_editor.dart) —
// the focused field's own local TextEditingValue.selection never moves, so
// a physical Backspace with a same-node (not cross-node) drag selection
// active used to fall through to `_shortcutBindings`' collapsed-caret branch
// instead of deleting the highlighted range.

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
  testWidgets('physical Backspace with a same-node drag selection deletes the '
      'selected range, not just a stale collapsed caret', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();

    // Simulates a drag-select of "world" — same-node, non-collapsed,
    // written only to composer.selection (never the field's local one),
    // exactly like `_extendDocumentDragTo` does for a real drag gesture.
    controller.changeSelection(
      const DocumentSelection(
        base: DocumentPosition('a', TextNodePosition(6)),
        extent: DocumentPosition('a', TextNodePosition(11)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).text.text,
      'hello ',
    );
  });
}
