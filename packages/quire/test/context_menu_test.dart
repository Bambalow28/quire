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

    expect(controller.composer.selection!.isCollapsed, isFalse);
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(state.textEditingValue.selection.textInside('hello world'), 'hello');
    expect(
      state.contextMenuButtonItems.map((i) => i.type),
      containsAll([ContextMenuButtonType.cut, ContextMenuButtonType.copy]),
    );
  });
}
