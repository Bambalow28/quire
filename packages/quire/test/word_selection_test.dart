import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

QuireEditorController _controller() => QuireEditorController(
  document: MutableDocument(
    nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
  ),
);

Future<Offset> _pump(WidgetTester tester, QuireEditorController c) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: c)),
    ),
  );
  await tester.pumpAndSettle();
  return tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 8);
}

void main() {
  testWidgets('long-press selects the word under the finger', (tester) async {
    final controller = _controller();
    final target = await _pump(tester, controller);

    final gesture = await tester.startGesture(target);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
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
