import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  testWidgets('caret menu offers Select, and Select unlocks cut/copy', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': 'clip'};
          }
          return null;
        });
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
    await tester.tapAt(target); // caret
    await tester.pumpAndSettle();
    await tester.tapAt(target); // caret again -> menu
    await tester.pumpAndSettle();

    expect(find.text('Select'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    final sel = controller.composer.selection!;
    expect(sel.isCollapsed, isFalse);
    final base = (sel.base.nodePosition as TextNodePosition).offset;
    final ext = (sel.extent.nodePosition as TextNodePosition).offset;
    expect('hello world'.substring(base, ext), 'hello');
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(
      state.contextMenuButtonItems.map((i) => i.type),
      containsAll([ContextMenuButtonType.cut, ContextMenuButtonType.copy]),
    );
  });

  testWidgets(
    "caret menu's Select All selects the whole document, not just one node",
    (tester) async {
      // Regression test: EditableText's own default "Select All" button
      // (spread in via state.contextMenuButtonItems) only selects within
      // that one field's own text. Touch users have no other way to reach
      // controller.selectAll() (Cmd/Ctrl+A needs a hardware keyboard), so
      // this button must be the document-wide one, not the field-local one.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      final target =
          tester.getTopLeft(find.byType(EditableText).first) +
          const Offset(20, 8);
      await tester.tapAt(target); // caret
      await tester.pumpAndSettle();
      await tester.tapAt(target); // caret again -> menu
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos, DocumentPosition('a', const TextNodePosition(0)));
      expect(endPos.nodeId, 'b');
    },
  );
}
