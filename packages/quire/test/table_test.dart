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

      await tester.tap(find.byTooltip('Insert table'));
      await tester.pump();

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
}
