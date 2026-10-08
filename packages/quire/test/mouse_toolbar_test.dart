import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';
import 'support/ime.dart';

// Desktop (mouse) rules: clicking only moves the caret; the options appear
// after a double-click or when a drag highlights text.

Future<QuireEditorController> _pump(WidgetTester tester) async {
  final controller = QuireEditorController(
    document: MutableDocument(
      nodes: [TextNode(id: 'a', text: AttributedText('hello world today'))],
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: controller)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _click(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await g.up();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('clicking the caret again does not open the options', (
    tester,
  ) async {
    await _pump(tester);
    final at = tester.getTopLeft(findNode('a')) + const Offset(20, 8);
    await tester.tapAt(at); // touch: places the caret
    await tester.pumpAndSettle();
    await _click(tester, at); // mouse on the caret that is already there
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Select All'), findsNothing);
  });

  testWidgets('double-click selects the word and opens the options', (
    tester,
  ) async {
    final c = await _pump(tester);
    final at = tester.getTopLeft(findNode('a')) + const Offset(20, 8);
    final g1 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 80));
    final g2 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await g2.up();
    await tester.pumpAndSettle();
    expect(c.composer.selection!.isCollapsed, isFalse);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('dragging a highlight opens the options on release', (
    tester,
  ) async {
    final c = await _pump(tester);
    final start = tester.getTopLeft(findNode('a')) + const Offset(4, 8);
    final g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await g.moveTo(start + const Offset(80, 0));
    await g.up();
    await tester.pumpAndSettle();
    expect(c.composer.selection!.isCollapsed, isFalse);
    expect(find.text('Copy'), findsOneWidget);
  });
}
