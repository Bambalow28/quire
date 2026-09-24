import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: QuireEditor(controller: controller)),
    ),
  );
}

void main() {
  testWidgets('the callout button in the + panel sets blockType callout', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [TextNode(id: 'a', text: AttributedText('hi'))],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: QuireEditor(controller: controller)),
              QuireToolbar(controller: controller),
            ],
          ),
        ),
      ),
    );

    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Callout'));
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).blockType,
      'callout',
    );
  });

  testWidgets(
    'a brand-new (empty-title) callout shows an inline "Enter text..." '
    'placeholder and nothing else — no separate content line or hint',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'callout',
              text: AttributedText(''),
              metadata: const {'blockType': 'callout'},
            ),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      expect(find.text('Enter text...'), findsOneWidget);
      // Just the title field — pressing Enter is what reveals content, not
      // simply inserting the callout.
      expect(find.byType(EditableText), findsOneWidget);
    },
  );

  testWidgets(
    'once the title has text, the inline placeholder is gone — and no tap '
    'affordance for content replaces it',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'callout',
              text: AttributedText('Heads up'),
              metadata: const {'blockType': 'callout'},
            ),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      expect(find.text('Enter text...'), findsNothing);
      expect(find.byType(EditableText), findsOneWidget);
    },
  );

  testWidgets('pressing Enter on the title reveals the content line', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'callout',
            text: AttributedText('Heads up'),
            metadata: const {'blockType': 'callout'},
          ),
        ],
      ),
    );
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('callout', const TextNodePosition(8)),
      ),
    );
    await _pumpEditor(tester, controller);

    controller.insertNewline();
    await tester.pump();

    expect(find.byType(EditableText), findsNWidgets(2));
    final nodes = controller.document.nodesInDocumentOrder.toList();
    expect(nodes, hasLength(2));
    expect((nodes[1] as TextNode).indent, 1);
  });

  testWidgets('a callout with content does not show the hint', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'callout',
            text: AttributedText('Heads up'),
            metadata: const {'blockType': 'callout'},
          ),
          TextNode(
            id: 'child',
            text: AttributedText('already here'),
            metadata: const {'indent': 1},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    expect(find.text('Enter text...'), findsNothing);
  });

  testWidgets('callout content renders smaller than the callout title', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'callout',
            text: AttributedText('Heads up'),
            metadata: const {'blockType': 'callout'},
          ),
          TextNode(
            id: 'child',
            text: AttributedText('inside'),
            metadata: const {'indent': 1},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final titleField = tester.widget<EditableText>(
      find.byType(EditableText).first,
    );
    final contentField = tester.widget<EditableText>(
      find.byType(EditableText).at(1),
    );
    expect(contentField.style.fontSize, lessThan(titleField.style.fontSize!));
  });

  testWidgets('a callout with content renders a bordered container', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'callout',
            text: AttributedText('Heads up'),
            metadata: const {'blockType': 'callout'},
          ),
          TextNode(
            id: 'child',
            text: AttributedText('inside'),
            metadata: const {'indent': 1},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    final decorated = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => (c.decoration as BoxDecoration?)?.border != null)
        .toList();
    // One piece for the title, one for the content line — stitched
    // together by matching border sides (see quire_editor.dart).
    expect(decorated.length, 2);

    // The seam between the two pieces must be a single shared line, not a
    // double line (a stray bottom border on the title reads as a divider
    // sitting inside the box, not the box's own edge).
    final titleBorder = (decorated[0].decoration as BoxDecoration).border!;
    final contentBorder = (decorated[1].decoration as BoxDecoration).border!;
    expect(titleBorder.bottom.style, BorderStyle.none);
    expect(contentBorder.top.style, BorderStyle.none);
  });

  test(
    'pressing Enter on a callout title writes into it, not a sibling callout',
    () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'callout',
              text: AttributedText('Heads up'),
              metadata: const {'blockType': 'callout'},
            ),
          ],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('callout', const TextNodePosition(8)),
        ),
      );

      controller.insertNewline();

      final nodes = controller.document.nodesInDocumentOrder.toList();
      expect(nodes, hasLength(2));
      final child = nodes[1] as TextNode;
      expect(child.blockType, 'paragraph');
      expect(child.indent, 1);
    },
  );
}
