import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

/// The editor no longer force-uppercases the first character of a node — the
/// soft keyboard comes up shifted instead (TextCapitalization.sentences), so a
/// deliberately lowercase first letter survives, exactly like a TextField.
/// That only works because the field's leading sentinel is a real space: a
/// zero-width space read as a word character to iOS/Android and killed the
/// auto-shift, which is why the forced uppercase existed in the first place.
void main() {
  testWidgets('the typed case of the first character is preserved', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
    );

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'hello');
    await tester.pump();

    final node = controller.document.getNodeById('a') as TextNode;
    expect(node.text.text, 'hello');
  });

  testWidgets('the field asks the keyboard for sentence case behind a space '
      'sentinel, and the sentinel never reaches the model', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText(''))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
    );

    expect(kEmptyNodeSentinel, ' ');
    final field = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(field.textCapitalization, TextCapitalization.sentences);
    expect(field.controller.text, kEmptyNodeSentinel);
    expect((controller.document.getNodeById('a') as TextNode).text.text, '');
  });
}
