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

void main() {
  // A test-only clipboard: flutter_test doesn't wire up a real platform
  // clipboard, so Clipboard.setData/getData round-trip through this instead.
  setUp(() {
    var stored = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            stored = (call.arguments as Map)['text'] as String;
          } else if (call.method == 'Clipboard.getData') {
            return {'text': stored};
          }
          return null;
        });
  });

  testWidgets(
    'the first tap on an empty document focuses it and leaves a collapsed, '
    'valid selection',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText(''))],
        ),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byType(EditableText).first);
      await tester.pump();

      expect(controller.focusedNodeId, 'a');
      expect(controller.composer.selection, isNotNull);
      expect(controller.composer.selection!.isCollapsed, isTrue);
      expect(
        controller.composer.selection,
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      );
    },
  );

  testWidgets(
    'a tap in the middle of a paragraph places the caret at the tapped '
    'offset, not at 0 or at the end',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
        ),
      );
      await _pumpEditor(tester, controller);

      final topLeft = tester.getTopLeft(find.byType(EditableText).first);
      // A handful of characters in on the first (only) line — nowhere near
      // offset 0 or offset 11 for a plausible glyph width.
      await tester.tapAt(topLeft + const Offset(30, 8));
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.isCollapsed, isTrue);
      final position = selection.extent.nodePosition as TextNodePosition;
      expect(position.offset, greaterThan(0));
      expect(position.offset, lessThan('hello world'.length));
    },
  );

  testWidgets(
    'a drag from paragraph 1 into paragraph 3 produces a DocumentSelection '
    'spanning nodes, and the toolbar/typing/backspace/select-all-copy all '
    'reach across it',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
            TextNode(id: 'c', text: AttributedText('third paragraph')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      final start =
          tester.getTopLeft(find.byType(EditableText).at(0)) +
          const Offset(4, 8);
      // Far enough right that it lands past the last glyph on the line,
      // clamping to the end of paragraph 3's text (so the bold check below
      // can expect the whole node, not just part of it).
      final end =
          tester.getTopLeft(find.byType(EditableText).at(2)) +
          const Offset(300, 8);

      // A mouse drag selects immediately; a finger drag would scroll (see
      // the touch tests below).
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      expect(selection!.base.nodeId, isNot(selection.extent.nodeId));
      final (startPos, endPos) = selection.normalize(controller.document);
      expect(startPos.nodeId, 'a');
      expect(endPos.nodeId, 'c');

      // Bold applied to that selection marks all three nodes.
      controller.toggleBold();
      await tester.pump();
      for (final id in ['a', 'b', 'c']) {
        final node = controller.document.getNodeById(id) as TextNode;
        expect(
          node.text.hasAttributionThroughout(
            const Attribution('bold'),
            0,
            node.text.text.length,
          ),
          isTrue,
          reason: 'node $id should be bold',
        );
      }

      // A single-node selection paints no overlay rects.
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      );
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      final singleNodePainter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SelectionOverlayPainter>()
          .single;
      expect(singleNodePainter.rects, isEmpty);
    },
  );

  testWidgets('typing with a cross-node selection active leaves one node '
      'containing the typed text', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('first paragraph')),
          TextNode(id: 'b', text: AttributedText('second paragraph')),
          TextNode(id: 'c', text: AttributedText('third paragraph')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);
    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition('a', const TextNodePosition(0)),
        extent: DocumentPosition('c', const TextNodePosition(5)),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(EditableText).first, 'X');
    await tester.pump();

    expect(controller.document.nodes.length, 1);
    expect(
      (controller.document.getNodeAt(0) as TextNode).text.text,
      'X paragraph',
    );
  });

  testWidgets(
    'Backspace with a cross-node selection active deletes across the nodes',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
            TextNode(id: 'c', text: AttributedText('third paragraph')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('c', const TextNodePosition(5)),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      expect(
        (controller.document.getNodeAt(0) as TextNode).text.text,
        ' paragraph',
      );
    },
  );

  testWidgets('Cmd+A then Cmd+C puts the whole document\'s text on the '
      'clipboard', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('first')),
          TextNode(id: 'b', text: AttributedText('second')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(controller.composer.selection!.base.nodeId, 'a');
    expect(controller.composer.selection!.extent.nodeId, 'b');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    // Clipboard.setData is async.
    await tester.pumpAndSettle();

    final clipboard = await Clipboard.getData('text/plain');
    expect(clipboard!.text, 'first\nsecond');
  });

  testWidgets('a finger drag scrolls instead of selecting', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('first paragraph')),
          TextNode(id: 'b', text: AttributedText('second paragraph')),
          TextNode(id: 'c', text: AttributedText('third paragraph')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final start =
        tester.getTopLeft(find.byType(EditableText).at(0)) + const Offset(4, 8);
    final end =
        tester.getTopLeft(find.byType(EditableText).at(2)) +
        const Offset(100, 8);

    final gesture = await tester.startGesture(start); // touch by default
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.composer.selection;
    expect(selection == null || selection.isCollapsed, isTrue);
  });

  testWidgets('a long-press then drag selects across nodes by touch', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('first paragraph')),
          TextNode(id: 'b', text: AttributedText('second paragraph')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final start =
        tester.getTopLeft(find.byType(EditableText).at(0)) + const Offset(4, 8);
    final end =
        tester.getTopLeft(find.byType(EditableText).at(1)) +
        const Offset(100, 8);

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600)); // hold
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.composer.selection;
    expect(selection, isNotNull);
    expect(selection!.base.nodeId, isNot(selection.extent.nodeId));
  });
}
