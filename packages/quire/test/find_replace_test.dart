import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

void main() {
  group('QuireEditorController find & replace', () {
    test('find populates matches across multiple nodes and sets the counter', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('the cat sat')),
            TextNode(id: 'b', text: AttributedText('on the mat')),
          ],
        ),
      );

      controller.find('the');

      expect(controller.matches.length, 2);
      expect(controller.matches[0].nodeId, 'a');
      expect(controller.matches[0].start, 0);
      expect(controller.matches[0].end, 3);
      expect(controller.matches[1].nodeId, 'b');
      expect(controller.matches[1].start, 3);
      expect(controller.matches[1].end, 6);
      expect(controller.currentMatchIndex, 0);
    });

    test('find is case-insensitive', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('Hello HELLO hello'))],
        ),
      );

      controller.find('hello');

      expect(controller.matches.length, 3);
    });

    test('find with no matches sets currentMatchIndex to -1', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('nothing here'))],
        ),
      );

      controller.find('xyz');

      expect(controller.matches, isEmpty);
      expect(controller.currentMatchIndex, -1);
    });

    test('findNext/findPrevious cycle and wrap around', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('a a a'))],
        ),
      );

      controller.find('a');
      expect(controller.currentMatchIndex, 0);

      controller.findNext();
      expect(controller.currentMatchIndex, 1);
      controller.findNext();
      expect(controller.currentMatchIndex, 2);
      controller.findNext();
      expect(controller.currentMatchIndex, 0); // wraps forward

      controller.findPrevious();
      expect(controller.currentMatchIndex, 2); // wraps backward
    });

    test('replaceCurrent replaces just the current match and preserves the rest', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('cat cat cat'))],
        ),
      );

      controller.find('cat');
      controller.replaceCurrent('dog');

      final node = controller.document.getNodeById('a') as TextNode;
      expect(node.text.text, 'dog cat cat');
      // Remaining occurrences of the query are still tracked.
      expect(controller.matches.length, 2);
    });

    test('replaceAll replaces every occurrence, including multiple matches in '
        'the same node', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(id: 'a', text: AttributedText('cat cat cat')),
            TextNode(id: 'b', text: AttributedText('a cat sat')),
          ],
        ),
      );

      controller.replaceAll('cat', 'dog');

      final a = controller.document.getNodeById('a') as TextNode;
      final b = controller.document.getNodeById('b') as TextNode;
      expect(a.text.text, 'dog dog dog');
      expect(b.text.text, 'a dog sat');
      expect(controller.matches, isEmpty);
    });

    test(
      'replaceAll terminates when the replacement contains the query',
      () {
        final controller = QuireEditorController(
          document: MutableDocument(
            nodes: [TextNode(id: 'a', text: AttributedText('Bob and Bob'))],
          ),
        );

        controller.replaceAll('Bob', 'Bobby');

        final a = controller.document.getNodeById('a') as TextNode;
        // Terminates (no infinite loop) rather than repeatedly matching the
        // "Bob" inside the "Bobby" it just inserted. The final re-find
        // legitimately reports "Bob" as still present, since it's a real
        // substring of "Bobby" — this asserts termination, not zero matches.
        expect(a.text.text, 'Bobby and Bobby');
      },
    );

    test('closeFind clears query, matches, and index', () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('cat cat'))],
        ),
      );

      controller.openFind();
      controller.find('cat');
      expect(controller.findBarOpen, isTrue);
      expect(controller.matches, isNotEmpty);

      controller.closeFind();

      expect(controller.findBarOpen, isFalse);
      expect(controller.findQuery, isNull);
      expect(controller.matches, isEmpty);
      expect(controller.currentMatchIndex, -1);
    });
  });

  group('QuireFindBar', () {
    testWidgets('hides when findBarOpen is false and shows when true', (
      tester,
    ) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('cat cat'))],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireFindBar(controller: controller)),
        ),
      );

      expect(find.byType(TextField), findsNothing);

      controller.openFind();
      await tester.pump();

      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('reflects the match counter as the controller finds matches', (
      tester,
    ) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [TextNode(id: 'a', text: AttributedText('cat cat cat'))],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuireFindBar(controller: controller)),
        ),
      );

      controller.openFind();
      controller.find('cat');
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);

      controller.findNext();
      await tester.pump();

      expect(find.text('2/3'), findsOneWidget);
    });
  });
}
