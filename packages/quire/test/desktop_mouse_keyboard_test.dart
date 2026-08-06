import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(height: 600, child: QuireEditor(controller: controller)),
      ),
    ),
  );
}

Future<void> _mouseClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('double mouse-click selects the word under the cursor', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world again'))],
      ),
    );
    await _pumpEditor(tester, controller);
    final at =
        tester.getTopLeft(find.byType(EditableText).first) +
        const Offset(40, 8);

    await _mouseClick(tester, at);
    await _mouseClick(tester, at);

    final selection = controller.composer.selection;
    expect(selection, isNotNull);
    expect(selection!.isCollapsed, isFalse);
    final (start, end) = selection.normalize(controller.document);
    expect((start.nodePosition as TextNodePosition).offset, 0);
    expect((end.nodePosition as TextNodePosition).offset, 5); // "hello"
  });

  testWidgets('triple mouse-click selects the whole paragraph', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world again'))],
      ),
    );
    await _pumpEditor(tester, controller);
    final at =
        tester.getTopLeft(find.byType(EditableText).first) +
        const Offset(40, 8);

    await _mouseClick(tester, at);
    await _mouseClick(tester, at);
    await _mouseClick(tester, at);

    final selection = controller.composer.selection;
    expect(selection, isNotNull);
    final (start, end) = selection!.normalize(controller.document);
    expect((start.nodePosition as TextNodePosition).offset, 0);
    expect(
      (end.nodePosition as TextNodePosition).offset,
      'hello world again'.length,
    );
  });

  testWidgets('a plain single mouse click still just places a caret', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);

    await _mouseClick(
      tester,
      tester.getTopLeft(find.byType(EditableText).first) + const Offset(30, 8),
    );

    final selection = controller.composer.selection;
    expect(selection, isNotNull);
    expect(selection!.isCollapsed, isTrue);
  });

  testWidgets('two clicks far apart do not count as a double-click', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
      ),
    );
    await _pumpEditor(tester, controller);
    final topLeft = tester.getTopLeft(find.byType(EditableText).first);

    await _mouseClick(tester, topLeft + const Offset(4, 8));
    await _mouseClick(tester, topLeft + const Offset(70, 8));

    final selection = controller.composer.selection;
    expect(selection, isNotNull);
    expect(selection!.isCollapsed, isTrue);
  });

  testWidgets(
    'pressing Right at the end of a paragraph moves the caret into the '
    'start of the next paragraph',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first')),
            TextNode(id: 'b', text: AttributedText('second')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      controller.requestFocus('a');
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)), // end of "first"
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
    },
  );

  testWidgets(
    'pressing Left at the start of a paragraph moves the caret to the end '
    'of the previous paragraph',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first')),
            TextNode(id: 'b', text: AttributedText('second')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      controller.requestFocus('b');
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('b', const TextNodePosition(0)),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
    },
  );

  testWidgets(
    'pressing Right in the middle of a paragraph moves within it, not to '
    'the next node',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first')),
            TextNode(id: 'b', text: AttributedText('second')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      controller.requestFocus('a');
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(2)),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(controller.composer.selection!.extent.nodeId, 'a');
      expect(
        (controller.composer.selection!.extent.nodePosition as TextNodePosition)
            .offset,
        3,
      );
    },
  );
}
