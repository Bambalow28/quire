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

  testWidgets(
    'deleteSelection with a cross-node selection refocuses the surviving '
    'node, not the deleted one',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      // Focus starts in node 'b', the node the selection's extent will end
      // up removed along with — proves focus is re-derived from the
      // surviving selection afterward rather than left pointing at 'b'.
      await tester.tap(find.byType(EditableText).at(1));
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('b', const TextNodePosition(6)),
        ),
      );
      await tester.pump();

      controller.deleteSelection();
      await tester.pump();

      expect(controller.document.nodes.length, 1);
      final survivorId = controller.document.nodes.first.id;
      expect(controller.focusedNodeId, survivorId);
      expect(controller.focusedNodeId, isNot('b'));
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
    // Focus is deferred until the gesture is confirmed as a tap — right
    // after pointer-down (before the move that turns this into a scroll)
    // nothing should have been focused or popped a keyboard yet.
    expect(controller.focusedNodeId, isNull);
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final selection = controller.composer.selection;
    expect(selection == null || selection.isCollapsed, isTrue);
    // A pure scroll never resolves into a tap, so it must never have
    // requested focus on any node either.
    expect(controller.focusedNodeId, isNull);
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

  Finder startHandle() => find.byKey(const ValueKey('quire-start-handle'));
  Finder endHandle() => find.byKey(const ValueKey('quire-end-handle'));

  testWidgets(
    'selection handles only appear for a non-collapsed multi-node selection',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      // No selection at all.
      expect(startHandle(), findsNothing);
      expect(endHandle(), findsNothing);

      // Collapsed, single-node selection.
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(0)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsNothing);
      expect(endHandle(), findsNothing);

      // Non-collapsed, but confined to a single node.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsNothing);
      expect(endHandle(), findsNothing);

      // Non-collapsed and multi-node: both handles show up.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('b', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsOneWidget);
      expect(endHandle(), findsOneWidget);
    },
  );

  testWidgets('selectAll() on a multi-paragraph document shows both handles', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(id: 'a', text: AttributedText('first')),
          TextNode(id: 'b', text: AttributedText('second')),
          TextNode(id: 'c', text: AttributedText('third')),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    controller.selectAll();
    await tester.pump();

    expect(startHandle(), findsOneWidget);
    expect(endHandle(), findsOneWidget);
  });

  testWidgets(
    'dragging the start handle moves the selection start and leaves the end '
    'unchanged',
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

      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('c', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsOneWidget);

      // Drag the start handle down into paragraph 'b'.
      final target =
          tester.getTopLeft(find.byType(EditableText).at(1)) +
          const Offset(4, 8);
      final gesture = await tester.startGesture(
        tester.getCenter(startHandle()),
      );
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos.nodeId, 'b');
      expect(endPos, DocumentPosition('c', const TextNodePosition(5)));
    },
  );

  testWidgets(
    'dragging the end handle moves the selection end and leaves the start '
    'unchanged',
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

      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('c', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(endHandle(), findsOneWidget);

      // Drag the end handle up into paragraph 'b'.
      final target =
          tester.getTopLeft(find.byType(EditableText).at(1)) +
          const Offset(4, 8);
      final gesture = await tester.startGesture(tester.getCenter(endHandle()));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos, DocumentPosition('a', const TextNodePosition(0)));
      expect(endPos.nodeId, 'b');
    },
  );

  testWidgets(
    'dragging a handle in a genuinely scrollable document still updates the '
    'selection, not swallowed by the ancestor CustomScrollView drag',
    (tester) async {
      // Enough long paragraphs that the document overflows the 600-tall
      // viewport _pumpEditor uses — a real ancestor Scrollable with nonzero
      // scroll extent, competing in the gesture arena, is what a plain
      // GestureDetector.onPanUpdate handle loses to. The first three nodes
      // still lay out within the initial (unscrolled) viewport, so the drag
      // itself doesn't need to cross a scroll boundary to reproduce it.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: List.generate(
            30,
            (i) => TextNode(
              id: 'p$i',
              text: AttributedText(
                'paragraph number $i with enough extra text in it to wrap '
                'across multiple lines and add real height to the document',
              ),
            ),
          ),
        ),
      );
      await _pumpEditor(tester, controller);

      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('p0', const TextNodePosition(0)),
          extent: DocumentPosition('p2', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsOneWidget);

      // Drag the start handle down into paragraph 'p1', in small incremental
      // steps (like a real finger) rather than one teleporting jump — that's
      // what actually engages the ScrollView's own drag recognizer in the
      // gesture arena.
      final target =
          tester.getTopLeft(find.byType(EditableText).at(1)) +
          const Offset(4, 8);
      final start = tester.getCenter(startHandle());
      final gesture = await tester.startGesture(start);
      await tester.pump();
      const steps = 10;
      for (var i = 1; i <= steps; i++) {
        await gesture.moveTo(
          Offset.lerp(start, target, i / steps)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos.nodeId, 'p1');
      expect(endPos, DocumentPosition('p2', const TextNodePosition(5)));
    },
  );

  testWidgets(
    'a touch that lands on a single-node selection\'s native start handle '
    'is left alone instead of long-press jumping the selection to a '
    'different word',
    (tester) async {
      // Regression test for a bug found live: with a single word selected
      // within one paragraph, a touch near the selection's edge (where the
      // native EditableText handle sits) used to be treated as an ordinary
      // document-level touch, whose "nearest node above" fallback and
      // long-press-hold word-select timer would jump the selection to an
      // unrelated word (offset 0 of the same node) instead of leaving the
      // native handle's own drag alone.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('First paragraph here')),
            TextNode(id: 'b', text: AttributedText('second paragraph')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      // Select "paragraph" (offsets 6-15) — non-collapsed, confined to a
      // single node, so its handles are Flutter's own native ones.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(6)),
          extent: DocumentPosition('a', const TextNodePosition(15)),
        ),
      );
      controller.requestFocus('a');
      await tester.pump();

      final state = tester.state<EditableTextState>(
        find.byType(EditableText).first,
      );
      final renderEditable = state.renderEditable;
      // Fields render a leading zero-width sentinel char (see
      // `_emptyNodeSentinel`) ahead of the real text, so a field-space
      // TextPosition is one ahead of the model offset.
      final caretRect = renderEditable.getLocalRectForCaret(
        const TextPosition(offset: 6 + 1),
      );
      final caretTopGlobal = renderEditable.localToGlobal(caretRect.topLeft);
      // A few px above the caret's top: inside the start handle's hit
      // region (which reaches above the line for its knob) but above the
      // field's own render rect — exactly the touch that used to fall
      // through to the "nearest node above" fallback.
      final handlePoint = caretTopGlobal + const Offset(0, -5);

      final gesture = await tester.startGesture(handlePoint);
      // Long enough to fire the old word-select-on-hold timer were this
      // touch not recognised as landing on the native handle.
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection!;
      final (startPos, endPos) = selection.normalize(controller.document);
      expect(startPos, DocumentPosition('a', const TextNodePosition(6)));
      expect(endPos, DocumentPosition('a', const TextNodePosition(15)));
    },
  );

  testWidgets(
    'the same native-handle exemption holds regardless of document length '
    '(not just a short single-paragraph document)',
    (tester) async {
      final nodes = List.generate(
        20,
        (i) => TextNode(id: 'p$i', text: AttributedText('paragraph number $i')),
      );
      final controller = QuireEditorController(
        document: MutableDocument(nodes: nodes),
      );
      await _pumpEditor(tester, controller);

      // Select "number" within the first node — single-node selection deep
      // in a long, scrollable document.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('p0', const TextNodePosition(10)),
          extent: DocumentPosition('p0', const TextNodePosition(16)),
        ),
      );
      controller.requestFocus('p0');
      await tester.pump();

      final state = tester.state<EditableTextState>(
        find.byType(EditableText).first,
      );
      final renderEditable = state.renderEditable;
      final caretRect = renderEditable.getLocalRectForCaret(
        const TextPosition(offset: 10 + 1),
      );
      final handlePoint =
          renderEditable.localToGlobal(caretRect.topLeft) +
          const Offset(0, -5);

      final gesture = await tester.startGesture(handlePoint);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection!;
      final (startPos, endPos) = selection.normalize(controller.document);
      expect(startPos, DocumentPosition('p0', const TextNodePosition(10)));
      expect(endPos, DocumentPosition('p0', const TextNodePosition(16)));
    },
  );
}
