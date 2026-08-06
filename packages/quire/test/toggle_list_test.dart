import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

Future<void> _pumpEditor(
  WidgetTester tester,
  QuireEditorController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: QuireEditor(controller: controller))),
  );
}

/// Node text renders inside `EditableText` fields, not plain `Text` widgets
/// — `find.text()` can't see it, so collapse/expand is verified against each
/// live field's own controller text instead.
bool _isRendered(WidgetTester tester, String text) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .any((w) => w.controller.text.contains(text));

void main() {
  testWidgets(
    'collapsing a toggle list hides its indented content; expanding shows it again',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'toggle',
              text: AttributedText('Section'),
              metadata: const {'blockType': 'toggleList'},
            ),
            TextNode(
              id: 'child1',
              text: AttributedText('inside 1'),
              metadata: const {'indent': 1},
            ),
            TextNode(
              id: 'child2',
              text: AttributedText('inside 2'),
              metadata: const {'indent': 1},
            ),
            TextNode(id: 'after', text: AttributedText('after, not nested')),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      expect(_isRendered(tester, 'inside 1'), isTrue);
      expect(_isRendered(tester, 'inside 2'), isTrue);
      expect(_isRendered(tester, 'after, not nested'), isTrue);

      controller.toggleCollapsed('toggle');
      await tester.pump();

      expect(_isRendered(tester, 'Section'), isTrue);
      expect(_isRendered(tester, 'inside 1'), isFalse);
      expect(_isRendered(tester, 'inside 2'), isFalse);
      // A sibling back at indent 0 is not the toggle's content and must
      // stay visible even while collapsed.
      expect(_isRendered(tester, 'after, not nested'), isTrue);

      controller.toggleCollapsed('toggle');
      await tester.pump();

      expect(_isRendered(tester, 'inside 1'), isTrue);
      expect(_isRendered(tester, 'inside 2'), isTrue);
    },
  );

  testWidgets('a nested toggle inside a collapsed toggle stays hidden too', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'outer',
            text: AttributedText('Outer'),
            metadata: const {'blockType': 'toggleList'},
          ),
          TextNode(
            id: 'inner',
            text: AttributedText('Inner'),
            metadata: const {'blockType': 'toggleList', 'indent': 1},
          ),
          TextNode(
            id: 'innerChild',
            text: AttributedText('deep'),
            metadata: const {'indent': 2},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    controller.toggleCollapsed('outer');
    await tester.pump();

    expect(_isRendered(tester, 'Outer'), isTrue);
    expect(_isRendered(tester, 'Inner'), isFalse);
    expect(_isRendered(tester, 'deep'), isFalse);
  });

  testWidgets('the toggle button in the + panel sets blockType toggleList', (
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
    await tester.tap(find.text('Toggle list'));
    await tester.pump();

    expect(
      (controller.document.getNodeById('a') as TextNode).blockType,
      'toggleList',
    );
  });

  test('pressing Enter on a toggle line writes into it, not a sibling toggle', () {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'toggle',
            text: AttributedText('Section'),
            metadata: const {'blockType': 'toggleList'},
          ),
        ],
      ),
    );
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('toggle', const TextNodePosition(7)),
      ),
    );

    controller.insertNewline();

    final nodes = controller.document.nodesInDocumentOrder.toList();
    expect(nodes, hasLength(2));
    final child = nodes[1] as TextNode;
    expect(child.blockType, 'paragraph');
    expect(child.indent, 1);
  });

  test(
    'pressing Enter on a collapsed toggle line moves to a sibling line, not hidden content',
    () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'toggle',
              text: AttributedText('Section'),
              metadata: const {'blockType': 'toggleList', 'collapsed': true},
            ),
          ],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('toggle', const TextNodePosition(7)),
        ),
      );

      controller.insertNewline();

      final nodes = controller.document.nodesInDocumentOrder.toList();
      expect(nodes, hasLength(2));
      final sibling = nodes[1] as TextNode;
      expect(sibling.blockType, 'paragraph');
      expect(sibling.indent, 0);
      final toggle = nodes[0] as TextNode;
      expect(toggle.isCollapsed, isTrue);
    },
  );

  test(
    'pressing Enter on a collapsed toggle with content lands the new line after that content, not before it',
    () {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'toggle',
              text: AttributedText('Section'),
              metadata: const {'blockType': 'toggleList', 'collapsed': true},
            ),
            TextNode(
              id: 'content',
              text: AttributedText('Hidden content'),
              metadata: const {'indent': 1},
            ),
          ],
        ),
      );
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('toggle', const TextNodePosition(7)),
        ),
      );

      controller.insertNewline();

      final nodes = controller.document.nodesInDocumentOrder.toList();
      expect(nodes, hasLength(3));
      expect(nodes[0].id, 'toggle');
      // The hidden content stays right after the toggle, not shoved behind
      // the newly-inserted sibling line.
      expect(nodes[1].id, 'content');
      final sibling = nodes[2] as TextNode;
      expect(sibling.blockType, 'paragraph');
      expect(sibling.indent, 0);
    },
  );

  testWidgets(
    'an empty expanded toggle shows an "Empty toggle" hint; tapping it starts content',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [
            TextNode(
              id: 'toggle',
              text: AttributedText('Section'),
              metadata: const {'blockType': 'toggleList'},
            ),
          ],
        ),
      );
      await _pumpEditor(tester, controller);

      expect(find.text('Empty toggle'), findsOneWidget);

      await tester.tap(find.text('Empty toggle'));
      await tester.pump();

      final nodes = controller.document.nodesInDocumentOrder.toList();
      expect(nodes, hasLength(2));
      final child = nodes[1] as TextNode;
      expect(child.indent, 1);
      expect(child.text.text, isEmpty);
      expect(controller.focusedNodeId, child.id);

      // The hint disappears once the toggle actually has content.
      await tester.pump();
      expect(find.text('Empty toggle'), findsNothing);
    },
  );

  testWidgets('a collapsed empty toggle does not show the hint', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'toggle',
            text: AttributedText('Section'),
            metadata: const {'blockType': 'toggleList', 'collapsed': true},
          ),
        ],
      ),
    );
    await _pumpEditor(tester, controller);

    expect(find.text('Empty toggle'), findsNothing);
  });

  testWidgets('a toggle that already has content does not show the hint', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'toggle',
            text: AttributedText('Section'),
            metadata: const {'blockType': 'toggleList'},
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

    expect(find.text('Empty toggle'), findsNothing);
  });

  testWidgets('toggle content renders smaller than the toggle title', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(
        nodes: [
          TextNode(
            id: 'toggle',
            text: AttributedText('Section'),
            metadata: const {'blockType': 'toggleList'},
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
    expect(
      contentField.style.fontSize,
      lessThan(titleField.style.fontSize!),
    );
  });
}
