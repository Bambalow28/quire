import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

TextNode _para(String id, String text) =>
    TextNode(id: id, text: AttributedText(text));

TableCell _cell(String id, [String text = '']) =>
    TableCell(nodes: [_para(id, text)]);

TableNode _grid(String id, int rows, int columns) => TableNode(
  id: id,
  rows: List.generate(
    rows,
    (r) => TableRow(
      cells: List.generate(columns, (c) => _cell('${id}_r${r}c$c', 'r${r}c$c')),
    ),
  ),
);

Finder _horizontalScrollView() => find.byWidgetPredicate(
  (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
);

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
  testWidgets('a table renders one EditableText per cell', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 2, 2)]),
    );
    await _pumpEditor(tester, controller);

    expect(find.byType(EditableText), findsNWidgets(4));
  });

  testWidgets('typing in a cell updates that cell\'s node in the model', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 2, 2)]),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).at(1), 'edited');
    await tester.pump();

    final table = controller.document.getNodeById('t') as TableNode;
    expect((table.cellAt(0, 1)!.nodes.single as TextNode).text.text, 'edited');
  });

  testWidgets('Tab moves focus to the next cell', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 2, 2)]),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('t_r0c0', const TextNodePosition(0)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.focusedNodeId, 't_r0c1');
    expect(
      controller.composer.selection,
      DocumentSelection.collapsed(
        DocumentPosition('t_r0c1', const TextNodePosition(0)),
      ),
    );
  });

  testWidgets('Tab in the last cell appends a row', (tester) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 1, 1)]),
    );
    await _pumpEditor(tester, controller);

    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition('t_r0c0', const TextNodePosition(0)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final table = controller.document.getNodeById('t') as TableNode;
    expect(table.gridSize, (2, 1));
    expect(controller.focusedNodeId, isNot('t_r0c0'));
  });

  testWidgets(
    'the toolbar\'s insert-table button inserts a table at the caret',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(nodes: [_para('a', 'hello')]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                QuireToolbar(controller: controller),
                Expanded(child: QuireEditor(controller: controller)),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition('a', const TextNodePosition(5)),
        ),
      );
      await tester.pump();

      // Table now lives in the toolbar's `+` panel, not the bar itself.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byIcon(Icons.table_chart_outlined),
        100,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(find.byIcon(Icons.table_chart_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.table_chart_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(controller.document.nodes.whereType<TableNode>().length, 1);
    },
  );

  testWidgets('a merged cell renders once and spans the right width', (
    tester,
  ) async {
    final table = TableNode(
      id: 't',
      rows: [
        TableRow(
          cells: [
            TableCell(nodes: [_para('a', 'A')], colSpan: 2),
          ],
        ),
        TableRow(cells: [_cell('b', 'B'), _cell('c', 'C')]),
      ],
    );
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [table]),
    );
    await _pumpEditor(tester, controller);

    // 3 cells total (one merged spanning row 0, two plain in row 1).
    expect(find.byType(EditableText), findsNWidgets(3));

    final mergedSize = tester.getSize(find.byType(TableGrid));
    final bottomRowCellSize = tester.getSize(find.byType(EditableText).at(1));
    // The merged cell's row spans the full table width; a single bottom-row
    // cell is roughly half of it (minus its own padding).
    expect(bottomRowCellSize.width, lessThan(mergedSize.width));
  });

  testWidgets(
    'a table with more columns than fit scrolls horizontally and is wider '
    'than the viewport',
    (tester) async {
      // 10 columns * the 96pt minimum > the ~768pt the default 800pt test
      // surface leaves after the editor's default padding.
      final controller = QuireEditorController(
        document: MutableDocument(nodes: [_grid('t', 1, 10)]),
      );
      await _pumpEditor(tester, controller);

      expect(_horizontalScrollView(), findsOneWidget);
      final gridWidth = tester.getSize(find.byType(TableGrid)).width;
      final viewportWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(gridWidth, greaterThan(viewportWidth));
      expect(gridWidth, moreOrLessEquals(10 * TableGrid.defaultMinColumnWidth));
    },
  );

  testWidgets('a table that fits renders with no horizontal Scrollable', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 1, 2)]),
    );
    await _pumpEditor(tester, controller);

    expect(_horizontalScrollView(), findsNothing);
  });

  testWidgets('the settings button appears once per table and opens the menu', (
    tester,
  ) async {
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [_grid('t', 2, 2)]),
    );
    await _pumpEditor(tester, controller);

    expect(find.byTooltip('Table settings'), findsOneWidget);

    await tester.tap(find.byTooltip('Table settings'));
    await tester.pumpAndSettle();

    expect(find.text('Add row at end'), findsOneWidget);
    expect(find.text('Delete table'), findsOneWidget);
  });

  testWidgets(
    'with the caret outside the table, Delete row is disabled and Add row '
    'at end is enabled',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(
          nodes: [_para('a', 'hello'), _grid('t', 2, 2)],
        ),
      );
      await _pumpEditor(tester, controller);
      // Nothing focused: focusedNodeId starts out null.

      await tester.tap(find.byTooltip('Table settings'));
      await tester.pumpAndSettle();

      final deleteRow = tester.widget<PopupMenuItem<VoidCallback>>(
        find.widgetWithText(PopupMenuItem<VoidCallback>, 'Delete row'),
      );
      expect(deleteRow.enabled, isFalse);

      final addRow = tester.widget<PopupMenuItem<VoidCallback>>(
        find.widgetWithText(PopupMenuItem<VoidCallback>, 'Add row at end'),
      );
      expect(addRow.enabled, isTrue);
    },
  );

  testWidgets(
    'Add row at end adds a row; Delete table (after confirming) removes '
    'the node',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(nodes: [_grid('t', 1, 2)]),
      );
      await _pumpEditor(tester, controller);

      await tester.tap(find.byTooltip('Table settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add row at end'));
      await tester.pumpAndSettle();

      final table = controller.document.getNodeById('t') as TableNode;
      expect(table.gridSize, (2, 2));

      await tester.tap(find.byTooltip('Table settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete table'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(controller.document.getNodeById('t'), isNull);
    },
  );

  testWidgets(
    'a horizontal drag inside a wide table does not produce a text selection',
    (tester) async {
      final controller = QuireEditorController(
        document: MutableDocument(nodes: [_grid('t', 1, 10)]),
      );
      await _pumpEditor(tester, controller);
      expect(_horizontalScrollView(), findsOneWidget);

      final cellCenter = tester.getCenter(find.byType(EditableText).first);
      final gesture = await tester.startGesture(
        cellCenter,
        kind: PointerDeviceKind.touch,
      );
      // Move immediately (well within the 500ms touch-hold that would
      // promote this into a selection drag) — this must read as a scroll.
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pumpAndSettle();

      // A scroll must not turn into a cross-cell *range* selection. A caret
      // is only placed on pointer-up when the finger didn't move, so a
      // scroll legitimately leaves no selection at all — either way there is
      // no range.
      final selection = controller.composer.selection;
      expect(selection == null || selection.isCollapsed, isTrue);
    },
  );
}
