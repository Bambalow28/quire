import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

TextNode _para(String id, String text) =>
    TextNode(id: id, text: AttributedText(text));

TableCell _cell(String id, [String text = '']) =>
    TableCell(nodes: [_para(id, text)]);

/// A plain rows x columns grid, cell ids `r<row>c<col>`.
TableNode _grid(String id, int rows, int columns) => TableNode(
  id: id,
  rows: List.generate(
    rows,
    (r) => TableRow(
      cells: List.generate(columns, (c) => _cell('${id}_r${r}c$c', 'r${r}c$c')),
    ),
  ),
);

Editor _editor(MutableDocument doc, DocumentComposer composer) =>
    Editor(doc, composer, requestHandlers: defaultRequestHandlers);

void main() {
  group('TableNode model', () {
    test('json round-trip preserves spans and nested nodes', () {
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_para('a', 'A')], rowSpan: 2, colSpan: 1),
              TableCell(nodes: [_para('b', 'B'), _para('c', 'C')]),
            ],
          ),
          TableRow(cells: [_cell('d', 'D')]),
        ],
        metadata: {
          'columnWidths': [0.5, 0.5],
        },
      );

      final restored = TableNode.fromJson(table.toJson());
      expect(restored.rows.length, 2);
      expect(restored.rows[0].cells[0].rowSpan, 2);
      expect(restored.rows[0].cells[0].colSpan, 1);
      expect(
        (restored.rows[0].cells[0].nodes.single as TextNode).text.text,
        'A',
      );
      expect(restored.rows[0].cells[1].nodes.length, 2);
      expect(restored.rows[1].cells.single.nodes.single is TextNode, isTrue);
      expect(restored.columnWidths, [0.5, 0.5]);
    });

    test('gridSize and cellAt resolve a merged cell', () {
      // 2x2 grid where (0,0) spans 2 rows and 2 columns, covering the
      // whole table; rows[0] has one cell, rows[1] is empty.
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_para('a', 'A')], rowSpan: 2, colSpan: 2),
            ],
          ),
          TableRow(cells: []),
        ],
      );
      expect(table.gridSize, (2, 2));
      final origin = table.cellAt(0, 0)!;
      expect(table.cellAt(0, 1), same(origin));
      expect(table.cellAt(1, 0), same(origin));
      expect(table.cellAt(1, 1), same(origin));
    });

    test('gridSize and cellAt on a plain 2x3 grid', () {
      final table = _grid('t', 2, 3);
      expect(table.gridSize, (2, 3));
      expect(
        ((table.cellAt(1, 2))!.nodes.single as TextNode).text.text,
        'r1c2',
      );
    });
  });

  group('document tree', () {
    test('getNodeById reaches nodes nested inside table cells', () {
      final table = _grid('t', 2, 2);
      final doc = MutableDocument(nodes: [_para('before', 'x'), table]);
      expect(doc.getNodeById('t_r0c0'), isNotNull);
      expect(doc.getNodeById('t_r1c1'), isNotNull);
    });

    test('nodesInDocumentOrder visits a table\'s cells row-major in place', () {
      final table = _grid('t', 2, 2);
      final doc = MutableDocument(
        nodes: [_para('before', 'x'), table, _para('after', 'y')],
      );
      expect(doc.nodesInDocumentOrder.map((n) => n.id), [
        'before',
        't',
        't_r0c0',
        't_r0c1',
        't_r1c0',
        't_r1c1',
        'after',
      ]);
    });

    test(
      'getNodeIndexById is a document-order index with a table in the middle',
      () {
        final table = _grid('t', 1, 2);
        final doc = MutableDocument(
          nodes: [_para('before', 'x'), table, _para('after', 'y')],
        );
        expect(doc.getNodeIndexById('before'), 0);
        expect(doc.getNodeIndexById('t'), 1);
        expect(doc.getNodeIndexById('t_r0c0'), 2);
        expect(doc.getNodeIndexById('t_r0c1'), 3);
        expect(doc.getNodeIndexById('after'), 4);
        expect(doc.getNodeAt(3).id, 't_r0c1');
        expect(doc.getNodeAfter('t_r0c1')!.id, 'after');
        expect(doc.getNodeBefore('t_r0c0')!.id, 't');
      },
    );

    test('existing commands work unmodified on a node inside a table cell', () {
      final table = _grid('t', 1, 1);
      final doc = MutableDocument(nodes: [table]);
      final composer = DocumentComposer(
        selection: DocumentSelection.collapsed(
          DocumentPosition('t_r0c0', const TextNodePosition(4)),
        ),
      );
      final editor = _editor(doc, composer);

      editor.execute([
        InsertTextRequest(
          DocumentPosition('t_r0c0', const TextNodePosition(4)),
          '!',
        ),
      ]);
      expect(
        ((table.cellAt(0, 0))!.nodes.single as TextNode).text.text,
        'r0c0!',
      );

      const bold = Attribution('bold');
      editor.execute([
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition('t_r0c0', const TextNodePosition(0)),
            extent: DocumentPosition('t_r0c0', const TextNodePosition(3)),
          ),
        ),
        ToggleAttributionRequest(bold),
      ]);
      final text = (table.cellAt(0, 0)!.nodes.single as TextNode).text;
      expect(text.hasAttributionThroughout(bold, 0, 3), isTrue);

      // Pressing Enter inside the cell splits into two nodes, both still
      // reachable inside the same cell.
      editor.execute([InsertNewlineRequest()]);
      expect(table.cellAt(0, 0)!.nodes.length, 2);
      expect(doc.getNodeById('t_r0c0'), isNotNull);
    });
  });

  group('table commands', () {
    test(
      'InsertTableRequest inserts a table and places the caret in the first cell',
      () {
        final doc = MutableDocument(nodes: [_para('a', 'x')]);
        final composer = DocumentComposer();
        final editor = _editor(doc, composer);

        editor.execute([
          InsertTableRequest(rows: 2, columns: 3, afterNodeId: 'a'),
        ]);

        final table = doc.getNodeAt(1) as TableNode;
        expect(table.gridSize, (2, 3));
        final firstCellNode = table.cellAt(0, 0)!.nodes.single as TextNode;
        expect(
          composer.selection,
          DocumentSelection.collapsed(
            DocumentPosition(firstCellNode.id, const TextNodePosition(0)),
          ),
        );
      },
    );

    test('InsertTableRowRequest without a crossing span adds a plain row', () {
      final table = _grid('t', 2, 2);
      final doc = MutableDocument(nodes: [table]);
      final editor = _editor(doc, DocumentComposer());

      editor.execute([InsertTableRowRequest('t', atRow: 1)]);

      expect(table.gridSize, (3, 2));
      expect(table.rows[1].cells.length, 2);
      // Original row 1 shifted down to row 2, untouched.
      expect((table.cellAt(2, 0)!.nodes.single as TextNode).text.text, 'r1c0');
    });

    test('InsertTableRowRequest grows a span crossing the insertion line', () {
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_para('a', 'A')], rowSpan: 2),
            ],
          ),
          TableRow(cells: []),
        ],
      );
      final doc = MutableDocument(nodes: [table]);
      final editor = _editor(doc, DocumentComposer());

      // Insert a row strictly inside the span (between the two rows).
      editor.execute([InsertTableRowRequest('t', atRow: 1)]);

      expect(table.gridSize, (3, 1));
      expect(table.rows[0].cells.single.rowSpan, 3);
      expect(table.rows[1].cells, isEmpty);
      expect(table.rows[2].cells, isEmpty);
      expect(table.cellAt(0, 0), same(table.cellAt(1, 0)));
      expect(table.cellAt(0, 0), same(table.cellAt(2, 0)));
    });

    test('DeleteTableRowRequest removes a plain row', () {
      final table = _grid('t', 3, 2);
      final doc = MutableDocument(nodes: [table]);
      final editor = _editor(doc, DocumentComposer());

      editor.execute([DeleteTableRowRequest('t', row: 1)]);

      expect(table.gridSize, (2, 2));
      expect((table.cellAt(1, 0)!.nodes.single as TextNode).text.text, 'r2c0');
      // Deleted row's nested node ids are no longer reachable.
      expect(doc.getNodeById('t_r1c0'), isNull);
    });

    test('DeleteTableRowRequest shrinks a span crossing the deleted line', () {
      final table = TableNode(
        id: 't',
        rows: [
          TableRow(
            cells: [
              TableCell(nodes: [_para('a', 'A')], rowSpan: 3),
            ],
          ),
          TableRow(cells: []),
          TableRow(cells: []),
        ],
      );
      final doc = MutableDocument(nodes: [table]);
      final editor = _editor(doc, DocumentComposer());

      editor.execute([DeleteTableRowRequest('t', row: 1)]);

      expect(table.gridSize, (2, 1));
      expect(table.rows[0].cells.single.rowSpan, 2);
      expect(table.cellAt(0, 0), same(table.cellAt(1, 0)));
    });

    test(
      'DeleteTableRowRequest moves a cell originating in the deleted row down',
      () {
        final table = TableNode(
          id: 't',
          rows: [
            TableRow(cells: [_cell('x', 'X')]),
            TableRow(
              cells: [
                TableCell(nodes: [_para('a', 'A')], rowSpan: 2),
              ],
            ),
            TableRow(cells: []),
          ],
        );
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());

        editor.execute([DeleteTableRowRequest('t', row: 1)]);

        expect(table.gridSize, (2, 1));
        expect(table.rows[1].cells.single.rowSpan, 1);
        expect((table.cellAt(1, 0)!.nodes.single as TextNode).text.text, 'A');
      },
    );

    test(
      'DeleteTableRowRequest does not throw when the next row has its own '
      'origin cell beside a cell moving down into it',
      () {
        // 3-column table. Row 0: A(colSpan1,rowSpan2) covers col0 rows0-1,
        // B(colSpan2,rowSpan1) covers cols1-2 row0. Row 1 has its own origin
        // cell C(colSpan2) at columns 1-2 (col0 of row1 is covered by A).
        final table = TableNode(
          id: 't',
          rows: [
            TableRow(
              cells: [
                TableCell(nodes: [_para('a', 'A')], rowSpan: 2),
                TableCell(nodes: [_para('b', 'B')], colSpan: 2),
              ],
            ),
            TableRow(
              cells: [
                TableCell(nodes: [_para('c', 'C')], colSpan: 2),
              ],
            ),
          ],
        );
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());

        editor.execute([DeleteTableRowRequest('t', row: 0)]);

        expect(table.gridSize, (1, 3));
        expect((table.cellAt(0, 0)!.nodes.single as TextNode).text.text, 'A');
        expect(table.cellAt(0, 0)!.rowSpan, 1);
        expect((table.cellAt(0, 1)!.nodes.single as TextNode).text.text, 'C');
        expect(table.cellAt(0, 1), same(table.cellAt(0, 2)));
      },
    );

    test('DeleteTableRowRequest on the last row deletes the whole table', () {
      final table = _grid('t', 1, 2);
      final doc = MutableDocument(nodes: [_para('a', 'x'), table]);
      final editor = _editor(doc, DocumentComposer());

      editor.execute([DeleteTableRowRequest('t', row: 0)]);

      expect(doc.getNodeById('t'), isNull);
      expect(doc.nodes.length, 1);
    });

    test(
      'InsertTableColumnRequest and DeleteTableColumnRequest round-trip',
      () {
        final table = _grid('t', 2, 2);
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());

        editor.execute([InsertTableColumnRequest('t', atColumn: 1)]);
        expect(table.gridSize, (2, 3));
        expect(
          (table.cellAt(0, 2)!.nodes.single as TextNode).text.text,
          'r0c1',
        );

        editor.execute([DeleteTableColumnRequest('t', column: 1)]);
        expect(table.gridSize, (2, 2));
        expect(
          (table.cellAt(0, 1)!.nodes.single as TextNode).text.text,
          'r0c1',
        );
      },
    );

    test(
      'DeleteTableColumnRequest shrinks a span crossing the deleted column',
      () {
        final table = TableNode(
          id: 't',
          rows: [
            TableRow(
              cells: [
                TableCell(nodes: [_para('a', 'A')], colSpan: 3),
              ],
            ),
          ],
        );
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());

        editor.execute([DeleteTableColumnRequest('t', column: 1)]);

        expect(table.gridSize, (1, 2));
        expect(table.rows[0].cells.single.colSpan, 2);
      },
    );

    test(
      'DeleteTableColumnRequest on the last column deletes the whole table',
      () {
        final table = _grid('t', 2, 1);
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());

        editor.execute([DeleteTableColumnRequest('t', column: 0)]);

        expect(doc.getNodeById('t'), isNull);
      },
    );

    test(
      'MergeTableCellsRequest rejects a range whose corner is a covered '
      'position rather than a true cell origin',
      () {
        // 3x3 grid where (0,0) already spans 2x2, covering (0,0),(0,1),
        // (1,0),(1,1). A merge request anchored at (1,0) — a covered
        // position, not that cell's true origin (0,0) — must not corrupt
        // the grid.
        final table = TableNode(
          id: 't',
          rows: [
            TableRow(
              cells: [
                TableCell(nodes: [_para('a', 'A')], rowSpan: 2, colSpan: 2),
                _cell('c', 'C'),
              ],
            ),
            TableRow(cells: [_cell('f', 'F')]),
            TableRow(cells: [_cell('g', 'G'), _cell('h', 'H'), _cell('i', 'I')]),
          ],
        );
        final doc = MutableDocument(nodes: [table]);
        final editor = _editor(doc, DocumentComposer());
        final beforeJson = doc.toJson();

        editor.execute([
          MergeTableCellsRequest(
            't',
            fromRow: 1,
            fromColumn: 0,
            toRow: 1,
            toColumn: 2,
          ),
        ]);

        // Rejected: nothing changed, and the grid stays internally
        // consistent (every cell's span correctly reflects its footprint,
        // gridSize reachable, no exceptions).
        expect(doc.toJson(), beforeJson);
        expect(table.gridSize, (3, 3));
        final origin = table.cellAt(0, 0)!;
        expect(origin.rowSpan, 2);
        expect(origin.colSpan, 2);
        expect(table.cellAt(1, 0), same(origin));
        expect(table.cellAt(1, 1), same(origin));
      },
    );

    test('merge then split returns to the original grid shape', () {
      final table = _grid('t', 3, 3);
      final doc = MutableDocument(nodes: [table]);
      final editor = _editor(doc, DocumentComposer());
      final originalIds = table.grid
          .expand((row) => row)
          .map((c) => c!.nodes.first.id)
          .toSet();

      editor.execute([
        MergeTableCellsRequest(
          't',
          fromRow: 0,
          fromColumn: 0,
          toRow: 1,
          toColumn: 1,
        ),
      ]);

      expect(table.gridSize, (3, 3));
      final merged = table.cellAt(0, 0)!;
      expect(merged.rowSpan, 2);
      expect(merged.colSpan, 2);
      expect(table.cellAt(1, 1), same(merged));
      // The absorbed cells' nodes survive, just moved into the target cell.
      expect(
        merged.nodes.map((n) => n.id).toSet(),
        originalIds.intersection({'t_r0c0', 't_r0c1', 't_r1c0', 't_r1c1'}),
      );
      for (final id in ['t_r0c1', 't_r1c0', 't_r1c1']) {
        expect(
          doc.getNodeById(id),
          isNotNull,
        ); // still reachable, just nested under merged
      }

      editor.execute([SplitTableCellRequest('t', row: 0, column: 0)]);

      expect(table.gridSize, (3, 3));
      expect(table.cellAt(0, 0)!.rowSpan, 1);
      expect(table.cellAt(0, 0)!.colSpan, 1);
      expect(table.cellAt(0, 1), isNot(same(table.cellAt(0, 0))));
      expect(table.cellAt(1, 0), isNot(same(table.cellAt(0, 0))));
      expect(table.cellAt(1, 1), isNot(same(table.cellAt(0, 0))));
      // The un-merged cells are freshly empty (split, not restored content).
      expect((table.cellAt(0, 1)!.nodes.single as TextNode).text.text, '');
    });
  });

  group('undo', () {
    test('undo restores a table edit exactly', () {
      final table = _grid('t', 2, 2);
      final doc = MutableDocument(nodes: [table]);
      final originalJson = doc.toJson();
      final composer = DocumentComposer();
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor);

      history.execute([InsertTableRowRequest('t', atRow: 1)]);
      history.execute([
        MergeTableCellsRequest(
          't',
          fromRow: 0,
          fromColumn: 0,
          toRow: 1,
          toColumn: 0,
        ),
      ]);
      expect(doc.toJson(), isNot(originalJson));

      history.undo();
      history.undo();

      expect(doc.toJson(), originalJson);
    });
  });
}
