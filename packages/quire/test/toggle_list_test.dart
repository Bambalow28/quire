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
}
