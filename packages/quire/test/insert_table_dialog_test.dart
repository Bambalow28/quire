import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:quire/quire.dart';

/// Holds the `Future` [showInsertTableDialog] returns. A plain field (not a
/// direct `return` of the pending future) — returning a still-pending Future
/// from an `async` function makes Dart implicitly await it, which would
/// deadlock every test here that doesn't close the dialog.
class _DialogHandle {
  Future<({int rows, int columns})?>? future;
}

Future<_DialogHandle> _pumpAndShow(WidgetTester tester) async {
  final handle = _DialogHandle();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => handle.future = showInsertTableDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return handle;
}

/// The rendered size of one grid cell, derived from the grid's own box so a
/// change to the cell constants doesn't silently move every tap target.
double _stride(WidgetTester tester) =>
    tester.getSize(find.byKey(const ValueKey('quireTableSizeGrid'))).width / 10;

void main() {
  testWidgets('defaults to a 3 x 3 selection', (tester) async {
    await _pumpAndShow(tester);
    expect(find.text('3 × 3 Table'), findsOneWidget);
  });

  testWidgets('tapping a cell selects that size', (tester) async {
    await _pumpAndShow(tester);

    // Grid top-left is at the dialog's content origin; tap the cell at
    // column 5, row 4 (cells are 1-indexed; stride comes from the grid).
    final gridTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('quireTableSizeGrid')),
    );
    await tester.tapAt(
      gridTopLeft + Offset(4 * _stride(tester) + 4, 3 * _stride(tester) + 4),
    );
    await tester.pump();

    expect(find.text('5 × 4 Table'), findsOneWidget);
  });

  testWidgets('dragging across the grid selects the dragged size', (
    tester,
  ) async {
    await _pumpAndShow(tester);

    final gridTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('quireTableSizeGrid')),
    );
    final start = gridTopLeft + const Offset(4, 4);
    final end =
        gridTopLeft + Offset(6 * _stride(tester) + 4, 2 * _stride(tester) + 4);
    await tester.dragFrom(start, end - start);
    await tester.pump();

    expect(find.text('7 × 3 Table'), findsOneWidget);
  });

  testWidgets('Create returns the picked size', (tester) async {
    final handle = await _pumpAndShow(tester);

    final gridTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('quireTableSizeGrid')),
    );
    await tester.tapAt(
      gridTopLeft + Offset(3 * _stride(tester) + 4, 1 * _stride(tester) + 4),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(await handle.future, (rows: 2, columns: 4));
  });

  testWidgets('Cancel returns null', (tester) async {
    final handle = await _pumpAndShow(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await handle.future, isNull);
  });

  testWidgets('the grid\'s semantics label reflects the selection', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpAndShow(tester);

    expect(find.bySemanticsLabel('3 by 3 table'), findsOneWidget);

    final gridTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('quireTableSizeGrid')),
    );
    await tester.tapAt(gridTopLeft + Offset(4 * _stride(tester) + 4, 4));
    await tester.pump();

    expect(find.bySemanticsLabel('5 by 1 table'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the table-settings menu disables Split on an unmerged cell', (
    tester,
  ) async {
    final table = TableNode(
      id: 't',
      rows: [
        TableRow(
          cells: [
            TableCell(
              nodes: [TextNode(id: 'a', text: AttributedText('A'))],
            ),
            TableCell(
              nodes: [TextNode(id: 'b', text: AttributedText('B'))],
            ),
          ],
        ),
      ],
    );
    final controller = QuireEditorController(
      document: MutableDocument(nodes: [table]),
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
        DocumentPosition('a', const TextNodePosition(0)),
      ),
    );
    await tester.pump();

    // Two "Table settings" buttons now exist — the toolbar's and the
    // table's own — so disambiguate to the toolbar's (the first one built).
    await tester.tap(find.byTooltip('Table settings').first);
    await tester.pumpAndSettle();

    final splitItem = tester.widget<PopupMenuItem<VoidCallback>>(
      find.widgetWithText(PopupMenuItem<VoidCallback>, 'Split cell'),
    );
    expect(splitItem.enabled, isFalse);

    final mergeItem = tester.widget<PopupMenuItem<VoidCallback>>(
      find.widgetWithText(
        PopupMenuItem<VoidCallback>,
        'Merge with cell to the right',
      ),
    );
    expect(mergeItem.enabled, isTrue);
  });
}
