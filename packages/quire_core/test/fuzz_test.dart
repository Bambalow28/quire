import 'dart:convert';
import 'dart:math';

import 'package:quire_core/quire_core.dart';
import 'package:test/test.dart';

const _blockTypes = [
  'paragraph',
  'header1',
  'header2',
  'listItemUnordered',
  'listItemOrdered',
  'listItemTask',
  'blockquote',
  'code',
  'callout',
  'toggleList',
];
const _words = ['a', 'hello', ' ', 'wörld', '😀', '👨‍👩‍👧', 'é', 'x y', '‏'];

MutableDocument _seedDoc() => MutableDocument(
  nodes: [
    TextNode(id: 'n0', text: AttributedText('hello world')),
    TextNode(
      id: 'n1',
      text: AttributedText('second line', [
        AttributionSpan(const Attribution('bold'), 0, 6),
      ]),
      metadata: {'blockType': 'listItemUnordered'},
    ),
    TextNode(id: 'n2', text: AttributedText('')),
  ],
);

List<TextNode> _textNodes(MutableDocument d) =>
    d.nodesInDocumentOrder.whereType<TextNode>().toList();

DocumentPosition _randomPosition(Random rng, MutableDocument d) {
  final nodes = d.nodesInDocumentOrder.where((n) => n is! TableNode).toList();
  final node = nodes[rng.nextInt(nodes.length)];
  if (node is TextNode) {
    return DocumentPosition(
      node.id,
      TextNodePosition(rng.nextInt(node.text.text.length + 1)),
    );
  }
  return DocumentPosition(
    node.id,
    rng.nextBool()
        ? const UpstreamDownstreamNodePosition.upstream()
        : const UpstreamDownstreamNodePosition.downstream(),
  );
}

List<EditRequest> _randomRequests(
  Random rng,
  MutableDocument d,
  DocumentComposer c,
) {
  final texts = _textNodes(d);
  final text = texts[rng.nextInt(texts.length)];
  switch (rng.nextInt(16)) {
    case 0:
    case 1:
    case 2:
      return [
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(
              text.id,
              TextNodePosition(rng.nextInt(text.text.text.length + 1)),
            ),
          ),
        ),
        InsertTextRequest(
          DocumentPosition(
            text.id,
            TextNodePosition(rng.nextInt(text.text.text.length + 1)),
          ),
          _words[rng.nextInt(_words.length)],
        ),
      ];
    case 3:
      return [
        ChangeSelectionRequest(
          DocumentSelection(
            base: _randomPosition(rng, d),
            extent: _randomPosition(rng, d),
          ),
        ),
        DeleteSelectionRequest(),
      ];
    case 4:
      return [
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(
              text.id,
              TextNodePosition(rng.nextInt(text.text.text.length + 1)),
            ),
          ),
        ),
        InsertNewlineRequest(),
      ];
    case 5:
      final len = text.text.text.length;
      final a = rng.nextInt(len + 1);
      final b = rng.nextInt(len + 1);
      return [
        ChangeSelectionRequest(
          DocumentSelection(
            base: DocumentPosition(text.id, TextNodePosition(a)),
            extent: DocumentPosition(text.id, TextNodePosition(b)),
          ),
        ),
        ToggleAttributionRequest(
          rng.nextBool()
              ? const Attribution('bold')
              : Attribution('link', value: {'url': 'https://x.test'}),
        ),
      ];
    case 6:
      return [
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(text.id, const TextNodePosition(0)),
          ),
        ),
        ChangeBlockTypeRequest(_blockTypes[rng.nextInt(_blockTypes.length)]),
      ];
    case 7:
      return [
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(text.id, const TextNodePosition(0)),
          ),
        ),
        ChangeIndentRequest(rng.nextBool() ? 1 : -1),
      ];
    case 8:
      return [MergeWithPreviousNodeRequest(text.id)];
    case 9:
      return [
        InsertNodeRequest(
          rng.nextBool()
              ? HorizontalRuleNode(id: generateNodeId())
              : ImageNode(id: generateNodeId(), url: 'file:///x.png'),
          afterNodeId: text.id,
        ),
      ];
    case 10:
      return [
        InsertTableRequest(
          rows: 1 + rng.nextInt(3),
          columns: 1 + rng.nextInt(3),
          afterNodeId: d.nodes[rng.nextInt(d.nodes.length)].id,
        ),
      ];
    case 11:
      final tables = d.nodes.whereType<TableNode>().toList();
      if (tables.isEmpty) return [ToggleTaskCheckedRequest(text.id)];
      final t = tables[rng.nextInt(tables.length)];
      final (rows, cols) = t.gridSize;
      switch (rng.nextInt(4)) {
        case 0:
          return [InsertTableRowRequest(t.id, atRow: rng.nextInt(rows + 1))];
        case 1:
          return rows > 1
              ? [DeleteTableRowRequest(t.id, row: rng.nextInt(rows))]
              : [ToggleTaskCheckedRequest(text.id)];
        case 2:
          return [
            InsertTableColumnRequest(t.id, atColumn: rng.nextInt(cols + 1)),
          ];
        default:
          return cols > 1
              ? [DeleteTableColumnRequest(t.id, column: rng.nextInt(cols))]
              : [ToggleTaskCheckedRequest(text.id)];
      }
    case 12:
      return [ToggleTaskCheckedRequest(text.id)];
    case 13:
      return [ToggleCollapsedRequest(text.id)];
    case 14:
      return [
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(text.id, const TextNodePosition(0)),
          ),
        ),
        InsertRichContentRequest([
          TextNode(
            id: generateNodeId(),
            text: AttributedText('pasted', [
              AttributionSpan(const Attribution('italic'), 1, 4),
            ]),
          ),
          TextNode(id: generateNodeId(), text: AttributedText('two')),
        ]),
      ];
    default:
      return [
        ChangeSelectionRequest(
          DocumentSelection(
            base: _randomPosition(rng, d),
            extent: _randomPosition(rng, d),
          ),
        ),
      ];
  }
}

String _json(MutableDocument d) => jsonEncode(d.toJson());

void main() {
  for (var seed = 0; seed < 60; seed++) {
    test('seed $seed keeps the document valid and undo/redo exact', () {
      final rng = Random(seed);
      final doc = _seedDoc();
      final composer = DocumentComposer();
      final editor = Editor(
        doc,
        composer,
        requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
      );
      final history = EditHistory(editor, maxEntries: 100000);
      final initial = _json(doc);
      final log = <String>[];

      for (var step = 0; step < 150; step++) {
        final requests = _randomRequests(rng, doc, composer);
        log.add(requests.map((r) => r.runtimeType).join('+'));
        try {
          history.execute(requests);
        } catch (e, st) {
          fail('seed $seed step $step ${log.last} threw $e\n$st');
        }
        final problems = validateDocument(doc, composer.selection);
        expect(
          problems,
          isEmpty,
          reason: 'seed $seed step $step after ${log.last}',
        );
      }

      final finalJson = _json(doc);
      expect(MutableDocument.fromJson(doc.toJson()).toJson(), doc.toJson());

      while (history.canUndo) {
        history.undo();
      }
      expect(_json(doc), initial, reason: 'seed $seed: undo-all != initial');
      while (history.canRedo) {
        history.redo();
      }
      expect(_json(doc), finalJson, reason: 'seed $seed: redo-all != final');
    });
  }
}
