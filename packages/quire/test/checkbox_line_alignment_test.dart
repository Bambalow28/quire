import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 300, child: QuireEditor(controller: controller)),
      ),
    ),
  );
  // The checkbox's box is refined post-frame from the field's real
  // RenderEditable (see `_scheduleChecklistBoxMeasurement`) — one more pump
  // lets that measurement's `setState` land before a test inspects it.
  await tester.pump();
}

/// The real vertical extent of the first line of text inside the node's
/// `EditableText` — measured via `RenderEditable.getBoxesForSelection` (real
/// layout), never derived from `fontSize`.
(double top, double bottom) _firstLineExtent(WidgetTester tester) {
  final state = tester.state<EditableTextState>(
    find.byType(EditableText).first,
  );
  final renderEditable = state.renderEditable;
  // Two characters starting just past the leading sentinel stay within line 1
  // regardless of wrapping, and a TextBox's height for any run within one line
  // equals that line's own box height. Skipping the sentinel matters: it is a
  // hairline style run of its own, and measuring it here as well as in the
  // editor would move this expectation in step with the bug it exists to
  // catch.
  final boxes = renderEditable
      .getBoxesForSelection(const TextSelection(baseOffset: 1, extentOffset: 3))
      .where((b) => b.bottom - b.top > 1)
      .toList();
  final box = boxes.first;
  final topLeft = renderEditable.localToGlobal(Offset(box.left, box.top));
  final bottomLeft = renderEditable.localToGlobal(Offset(box.left, box.bottom));
  return (topLeft.dy, bottomLeft.dy);
}

/// Where the alphabetic baseline falls inside a line box, as a fraction of
/// that box's height — read off the very [TextStyle] the editor handed its
/// `EditableText`, so this uses the font's real ascent rather than assuming
/// one. A fraction, not a distance, because it gets applied to the real
/// rendered line, which at a line spacing above 1 is not always as tall as a
/// lone synthetic one.
double _baselineFraction(WidgetTester tester) {
  final style = tester
      .widget<EditableText>(find.byType(EditableText).first)
      .style;
  final painter = TextPainter(
    text: TextSpan(text: 'x', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final fraction =
      painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) /
      painter.height;
  painter.dispose();
  return fraction;
}

void main() {
  // The checkbox's mark must centre on the first rendered line's cap-height
  // band — baseline up to the top of a capital — not on its line box, which
  // runs far above the letters (see `_prefixFor` in quire_editor.dart). Half
  // a pixel of tolerance is tight enough that it only passes when the line
  // and its baseline both come from real layout, not a same-ballpark guess.
  const tolerance = 0.5;

  Future<void> expectCentered(
    WidgetTester tester, {
    required String text,
    double? lineSpacing,
  }) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'a',
            text: AttributedText(text),
            metadata: {
              'blockType': 'listItemTask',
              if (lineSpacing != null) 'lineSpacing': lineSpacing,
            },
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final checkboxRect = tester.getRect(find.byType(Checkbox));
    final (lineTop, lineBottom) = _firstLineExtent(tester);
    final ascent = (lineBottom - lineTop) * _baselineFraction(tester);
    final baseline = lineTop + ascent;
    final capBandCentre = baseline - ascent * kCapHeightOfAscent / 2;
    // Checkbox fills the box it is given and paints its fixed-size mark in
    // the middle of it, so the mark's centre is that box's centre — the box's
    // own edges say nothing about where the mark landed.
    final markCentre = checkboxRect.center.dy;

    expect(
      markCentre,
      closeTo(capBandCentre, tolerance),
      reason:
          'checkbox mark centre=$markCentre vs first-line cap-band centre='
          '$capBandCentre (line $lineTop..$lineBottom, baseline $baseline)',
    );
  }

  testWidgets(
    'single-line checklist item at the default line spacing: checkbox centres on the line cap band',
    (tester) async {
      await expectCentered(tester, text: 'buy milk');
    },
  );

  testWidgets(
    'wrapped checklist item at the default line spacing: checkbox centres on the first line cap band, not the whole paragraph',
    (tester) async {
      const text =
          'this is a long checklist item that will wrap across more than '
          'one line inside the narrow editor width used by this test so '
          'the paragraph spans several lines';
      await expectCentered(tester, text: text);
      // Sanity check that the item actually wrapped, or this test proves
      // nothing about "first line, not whole paragraph".
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'a',
              text: AttributedText(text),
              metadata: {'blockType': 'listItemTask'},
            ),
          ],
        ),
      );
      await _pumpEditor(tester, controller);
      final fieldRect = tester.getRect(find.byType(EditableText).first);
      final (lineTop, lineBottom) = _firstLineExtent(tester);
      expect(
        fieldRect.height,
        greaterThan(lineBottom - lineTop + 4),
        reason: 'item must wrap for this test to be meaningful',
      );
    },
  );

  testWidgets(
    'single-line checklist item at 1.5x line spacing: checkbox still centres on the line cap band',
    (tester) async {
      await expectCentered(tester, text: 'buy milk', lineSpacing: 1.5);
    },
  );

  testWidgets(
    'wrapped checklist item at 1.5x line spacing: checkbox still centres on the first line cap band',
    (tester) async {
      const text =
          'this is a long checklist item that will wrap across more than '
          'one line inside the narrow editor width used by this test so '
          'the paragraph spans several lines';
      await expectCentered(tester, text: text, lineSpacing: 1.5);
    },
  );
}
