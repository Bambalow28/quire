// Core edit-pipeline timings on large documents:
//   dart run tool/benchmark.dart
import 'dart:convert';
import 'dart:math';

import 'package:quire_core/quire_core.dart';

MutableDocument build(int words) {
  final rng = Random(1);
  final nodes = <DocumentNode>[];
  var count = 0;
  var i = 0;
  while (count < words) {
    final n = 20 + rng.nextInt(60);
    final text = List.generate(n, (_) => 'word${rng.nextInt(999)}').join(' ');
    nodes.add(
      TextNode(
        id: 'n${i++}',
        text: AttributedText(text, [
          AttributionSpan(const Attribution('bold'), 0, 5),
        ]),
        metadata: i % 7 == 0 ? {'blockType': 'listItemUnordered'} : null,
      ),
    );
    count += n;
  }
  return MutableDocument(nodes: nodes);
}

T time<T>(String label, T Function() body, {int reps = 1}) {
  final sw = Stopwatch()..start();
  late T result;
  for (var i = 0; i < reps; i++) {
    result = body();
  }
  sw.stop();
  print(
    '  ${label.padRight(34)} ${(sw.elapsedMicroseconds / reps / 1000).toStringAsFixed(2).padLeft(9)} ms',
  );
  return result;
}

void main() {
  for (final words in [5000, 20000, 100000]) {
    final doc = build(words);
    final composer = DocumentComposer();
    final editor = Editor(
      doc,
      composer,
      requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
    );
    final history = EditHistory(editor);
    final mid = doc.nodes[doc.nodes.length ~/ 2].id;
    print('$words words, ${doc.nodes.length} nodes');
    final json = time(
      'snapshot (toJson+encode)',
      () => jsonEncode(doc.toJson()),
      reps: 5,
    );
    print(
      '  ${'snapshot size'.padRight(34)} ${(json.length / 1024).toStringAsFixed(0).padLeft(9)} KB',
    );
    time(
      'load (decode+loadDocument)',
      () => loadDocument(jsonDecode(json)),
      reps: 5,
    );
    time('type one char (undo-recorded)', () {
      history.execute([
        InsertTextRequest(
          DocumentPosition(mid, const TextNodePosition(3)),
          'x',
        ),
      ]);
    }, reps: 50);
    time('insert paragraph break', () {
      history.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            DocumentPosition(mid, const TextNodePosition(3)),
          ),
        ),
        InsertNewlineRequest(),
      ]);
    }, reps: 20);
    time('nodesInDocumentOrder after edit', () {
      doc.nodesInDocumentOrder;
    }, reps: 20);
    time('undo', history.undo, reps: 5);
    print(
      '  ${'undo stack entries'.padRight(34)} ${history.undoCount.toString().padLeft(9)}',
    );
    print('');
  }
}
