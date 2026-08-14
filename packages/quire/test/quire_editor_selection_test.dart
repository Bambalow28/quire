import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

/// Mirrors `_handleKnobDiameter` in quire_editor.dart — the knob is drawn at
/// the very top of the start handle's rect, and that's where a finger lands.
const _handleKnobDiameter = 14.0;

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

      // A single-node, single-line selection paints exactly one overlay
      // rect — the field's own `selectionColor` is transparent, so the
      // overlay is the only thing drawing the highlight now.
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
      expect(singleNodePainter.rects, hasLength(1));
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
    'selection handles appear for any non-collapsed selection, single-node '
    'or multi-node, but not for no selection or a collapsed one',
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

      // Non-collapsed, confined to a single node — native handles are
      // disabled, so quire's own handles must cover this case too.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(0)),
          extent: DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(startHandle(), findsOneWidget);
      expect(endHandle(), findsOneWidget);

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

  /// Exact screen point for [modelOffset] within [renderEditable]'s node —
  /// robust against the eyeballed-pixel-offset approach used elsewhere in
  /// this file, needed here because the crossover test below depends on
  /// landing precisely on particular offsets partway through a drag. `+ 1`
  /// for the field's leading sentinel (see `_emptyNodeSentinel` in
  /// quire_editor.dart).
  Offset pointForOffset(RenderEditable renderEditable, int modelOffset) {
    final rect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: modelOffset + 1),
    );
    return renderEditable.localToGlobal(rect.center);
  }

  testWidgets(
    'dragging a SINGLE-NODE selection\'s start handle to a new offset widens '
    'the selection to that exact offset, leaving the end unchanged — then '
    'the end handle narrows the end, leaving the (new) start unchanged',
    (tester) async {
      // Regression test for root cause 1: before the fix, a non-collapsed
      // selection confined to one node had no quire-drawn handles at all
      // (native handles were used instead, which can never move
      // `composer.selection` — see the `selectionControls: null` comment in
      // quire_editor.dart), so this whole scenario had nothing to drag.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world'))],
        ),
      );
      await _pumpEditor(tester, controller);

      // Select "world" (offsets 6-11), confined to node 'a'.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(6)),
          extent: DocumentPosition('a', const TextNodePosition(11)),
        ),
      );
      controller.requestFocus('a');
      await tester.pump();
      expect(startHandle(), findsOneWidget);
      expect(endHandle(), findsOneWidget);

      final renderEditable = tester
          .state<EditableTextState>(find.byType(EditableText).first)
          .renderEditable;

      // Drag the start handle from offset 6 to offset 0 — widens the
      // selection to cover "hello world" entirely.
      final startGesture = await tester.startGesture(
        tester.getCenter(startHandle()),
      );
      await tester.pump();
      await startGesture.moveTo(pointForOffset(renderEditable, 0));
      await tester.pump();
      await startGesture.up();
      await tester.pump();

      var selection = controller.composer.selection;
      expect(selection, isNotNull);
      var (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos, DocumentPosition('a', const TextNodePosition(0)));
      expect(endPos, DocumentPosition('a', const TextNodePosition(11)));

      // Now drag the end handle from offset 11 to offset 8 — narrows the
      // selection's end, leaving the widened start (offset 0) untouched.
      expect(endHandle(), findsOneWidget);
      final endGesture = await tester.startGesture(
        tester.getCenter(endHandle()),
      );
      await tester.pump();
      await endGesture.moveTo(pointForOffset(renderEditable, 8));
      await tester.pump();
      await endGesture.up();
      await tester.pump();

      selection = controller.composer.selection;
      expect(selection, isNotNull);
      (startPos, endPos) = selection!.normalize(controller.document);
      expect(startPos, DocumentPosition('a', const TextNodePosition(0)));
      expect(endPos, DocumentPosition('a', const TextNodePosition(8)));
    },
  );

  testWidgets(
    'dragging a handle across several incremental moves that cross past the '
    'fixed endpoint keeps that endpoint anchored at its ORIGINAL offset, '
    'instead of drifting to wherever the selection happened to be after the '
    'previous move',
    (tester) async {
      // Regression test for root cause 2: the old implementation
      // re-derived "the fixed endpoint" from the CURRENT (already-mutated)
      // selection on every pointer move, so once the dragged point crossed
      // the original fixed endpoint, subsequent moves anchored against
      // whatever the selection had drifted to instead of the true original
      // fixed offset (8 here). A single big jump can't expose this — it
      // takes several moves that mutate the selection in between.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('hello world today'))],
        ),
      );
      await _pumpEditor(tester, controller);

      // base=3 (visual start — the handle being dragged), extent=8 (visual
      // end, must stay put for the whole drag).
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('a', const TextNodePosition(3)),
          extent: DocumentPosition('a', const TextNodePosition(8)),
        ),
      );
      controller.requestFocus('a');
      await tester.pump();
      expect(startHandle(), findsOneWidget);

      final renderEditable = tester
          .state<EditableTextState>(find.byType(EditableText).first)
          .renderEditable;

      final gesture = await tester.startGesture(
        tester.getCenter(startHandle()),
      );
      await tester.pump();
      // First two moves stay short of the fixed endpoint (8); the third
      // crosses past it and keeps going.
      for (final target in [6, 10, 12]) {
        await gesture.moveTo(pointForOffset(renderEditable, target));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      // Offset 8 was never itself dragged and must stay exactly there; the
      // dragged handle ends at the last move target, offset 12.
      expect(startPos, DocumentPosition('a', const TextNodePosition(8)));
      expect(endPos, DocumentPosition('a', const TextNodePosition(12)));
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

  testWidgets(
    'dragging a handle by the knob keeps the selection on the knob\'s own '
    'line, instead of snapping to the node the knob overlaps',
    (tester) async {
      // A real finger drags the KNOB, which is drawn deliberately off the
      // text line (above it for the start handle) so it doesn't cover the
      // glyphs it points at — so the finger stays off the line for the whole
      // drag. The earlier tests grabbed the knob but then moved to a point
      // back ON the text line, so they never exercised that. Here the finger
      // moves purely horizontally, staying at knob height: before the fix
      // `_positionAt` probed the raw finger position, which sits over the
      // PREVIOUS node, so the selection jumped out of node 'b' entirely.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('first paragraph here')),
            TextNode(id: 'b', text: AttributedText('second paragraph here')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      // Select "paragraph" (offsets 7-16) inside node 'b' only.
      controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition('b', const TextNodePosition(7)),
          extent: DocumentPosition('b', const TextNodePosition(16)),
        ),
      );
      controller.requestFocus('b');
      await tester.pump();
      expect(startHandle(), findsOneWidget);

      // Grab the KNOB — the circle at the very top of the handle, which is
      // what a finger actually lands on — not `getCenter` of the whole
      // handle rect, which sits down on the text line and so never
      // exercises this at all. With node 'a' occupying y 16-34 and 'b'
      // y 38-56, the knob's own centre lands inside node 'a'.
      final handleRect = tester.getRect(startHandle());
      final grab = Offset(
        handleRect.center.dx,
        handleRect.top + _handleKnobDiameter / 2,
      );
      final gesture = await tester.startGesture(grab);
      await tester.pump();
      for (final dx in [-15.0, -30.0, -45.0]) {
        await gesture.moveTo(grab + Offset(dx, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      // Still confined to 'b' — it must not have jumped into node 'a'.
      expect(startPos.nodeId, 'b');
      expect(endPos, DocumentPosition('b', const TextNodePosition(16)));
      // It genuinely widened leftward, and tracked the finger's actual
      // column — landing somewhere strictly inside the line. Probing the
      // raw finger position instead lands in the gap above this node, where
      // `_positionAt`'s nearest-node fallback returns offset 0 regardless of
      // how far the finger moved horizontally, so this is the assertion that
      // separates "tracked the drag" from "snapped to the node edge".
      final startOffset = (startPos.nodePosition as TextNodePosition).offset;
      expect(startOffset, lessThan(7));
      expect(startOffset, greaterThan(0));
    },
  );

  testWidgets(
    'holding a document-level drag at the bottom viewport edge autoscrolls '
    'and keeps extending the selection into content that was off-screen '
    'when the drag began',
    (tester) async {
      // Long-wrapping paragraphs so only a handful fit in the 600-tall
      // viewport — a short one-line-per-node document would fit 25+ nodes
      // and never need to scroll at all.
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: List.generate(
            25,
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

      final viewport = tester.getRect(find.byType(QuireEditor));
      final start =
          tester.getTopLeft(find.byType(EditableText).first) +
          const Offset(4, 4);
      // A few px above the very bottom edge — inside the autoscroll margin.
      final holdPoint = Offset(start.dx, viewport.bottom - 5);

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );

      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(holdPoint);
      await tester.pump();

      final offsetBeforeHold = scrollable.position.pixels;

      // Hold still at the edge — nothing else moves the finger from here,
      // so any further scrolling/selection growth must come from the
      // autoscroll ticker alone, not from a fresh pointer move.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(scrollable.position.pixels, greaterThan(offsetBeforeHold));

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (_, endPos) = selection!.normalize(controller.document);
      final endIndex = controller.document.getNodeIndexById(endPos.nodeId);
      // Well beyond what the initial 600pt viewport could show starting
      // from node 0 — proves the selection reached content that was
      // off-screen when the drag started, not just that the view scrolled.
      expect(endIndex, greaterThan(4));

      await gesture.up();
      await tester.pump();
    },
  );

  testWidgets(
    'holding a selection-handle drag at the bottom viewport edge '
    'autoscrolls too, and keeps widening the selection while the finger '
    'holds still',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: List.generate(
            25,
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
          extent: DocumentPosition('p1', const TextNodePosition(5)),
        ),
      );
      await tester.pump();
      expect(endHandle(), findsOneWidget);

      final viewport = tester.getRect(find.byType(QuireEditor));
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final offsetBeforeHold = scrollable.position.pixels;

      final grab = tester.getCenter(endHandle());
      final holdPoint = Offset(grab.dx, viewport.bottom - 5);
      final gesture = await tester.startGesture(grab);
      await tester.pump();
      await gesture.moveTo(holdPoint);
      await tester.pump();

      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(scrollable.position.pixels, greaterThan(offsetBeforeHold));

      final selection = controller.composer.selection;
      expect(selection, isNotNull);
      final (startPos, endPos) = selection!.normalize(controller.document);
      // The start handle was never touched.
      expect(startPos, DocumentPosition('p0', const TextNodePosition(0)));
      final endIndex = controller.document.getNodeIndexById(endPos.nodeId);
      expect(endIndex, greaterThan(4));

      await gesture.up();
      await tester.pump();
    },
  );

  testWidgets(
    'a long-press-then-drag extends the selection by whole words, snapping '
    'to word boundaries mid-drag rather than the exact character under the '
    'finger',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('alpha beta gamma delta')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      final renderEditable = tester
          .state<EditableTextState>(find.byType(EditableText).first)
          .renderEditable;
      Offset forOffset(int modelOffset) {
        final rect = renderEditable.getLocalRectForCaret(
          TextPosition(offset: modelOffset + 1),
        );
        return renderEditable.localToGlobal(rect.center);
      }

      // Long-press in the middle of "beta" (word boundaries 6-10).
      final gesture = await tester.startGesture(forOffset(8));
      await tester.pump(const Duration(milliseconds: 600));

      var selection = controller.composer.selection!;
      var (startPos, endPos) = selection.normalize(controller.document);
      expect((startPos.nodePosition as TextNodePosition).offset, 6);
      expect((endPos.nodePosition as TextNodePosition).offset, 10);

      // Drag to offset 13 — the middle of "gamma" (word boundaries 11-16),
      // not itself a word boundary.
      await gesture.moveTo(forOffset(13));
      await tester.pump();

      selection = controller.composer.selection!;
      (startPos, endPos) = selection.normalize(controller.document);
      // Snapped to "gamma"'s end (16), not the touched offset (13); "beta"'s
      // start (6) stays the fixed anchor.
      expect((startPos.nodePosition as TextNodePosition).offset, 6);
      expect((endPos.nodePosition as TextNodePosition).offset, 16);

      await gesture.up();
      await tester.pump();
    },
  );

  group('Select All shows the toolbar immediately, like Select does', () {
    Future<QuireEditorController> pumpMultiParagraphAndOpenMenu(
      WidgetTester tester,
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
      final target =
          tester.getTopLeft(find.byType(EditableText).first) +
          const Offset(20, 8);
      await tester.tapAt(target); // caret
      await tester.pumpAndSettle();
      await tester.tapAt(target); // caret again -> caret menu
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets(
      'tapping Select All opens the toolbar with Cut/Copy, no second '
      'long-press needed, and the cross-node document selection survives '
      'the toolbar appearing',
      (tester) async {
        final controller = await pumpMultiParagraphAndOpenMenu(tester);

        await tester.tap(find.text('Select all'));
        await tester.pumpAndSettle();

        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Cut'), findsOneWidget);

        // Showing the toolbar gives the focused field its own local
        // selection (see `_showToolbarForWholeField`) — this must not have
        // clobbered the document-wide selection back down to that one node.
        final selection = controller.composer.selection;
        expect(selection, isNotNull);
        expect(selection!.base.nodeId, isNot(selection.extent.nodeId));
        expect(selection.base.nodeId, 'a');
        expect(selection.extent.nodeId, 'b');
      },
    );

    testWidgets(
      'Copy after Select All puts the whole document on the clipboard, not '
      'just one paragraph',
      (tester) async {
        await pumpMultiParagraphAndOpenMenu(tester);

        await tester.tap(find.text('Select all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();

        final data = await Clipboard.getData('text/plain');
        expect(data?.text, 'first paragraph\nsecond paragraph');
      },
    );

    testWidgets(
      'Cut after Select All empties the whole document, not just one '
      'paragraph',
      (tester) async {
        final controller = await pumpMultiParagraphAndOpenMenu(tester);

        await tester.tap(find.text('Select all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cut'));
        await tester.pumpAndSettle();

        expect(controller.document.nodes.length, 1);
        final remaining = controller.document.nodes.single as TextNode;
        expect(remaining.text.text, isEmpty);

        final data = await Clipboard.getData('text/plain');
        expect(data?.text, 'first paragraph\nsecond paragraph');
      },
    );
  });
}
