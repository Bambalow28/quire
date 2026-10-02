import 'dart:math';

import 'package:quire_core/quire_core.dart';
import 'package:quire_markdown/quire_markdown.dart';
import 'package:test/test.dart';

const _pieces = [
  '# ',
  '## ',
  '- ',
  '1. ',
  '[ ] ',
  '> ',
  '```\n',
  '---\n',
  '\n',
  '\n\n',
  '**',
  '*',
  '_',
  '`',
  '~~',
  '[a](http://x.test)',
  '![i](u)',
  'text',
  ' ',
  '😀',
  '  ',
  '\t',
  '|',
  '<b>',
  '\\',
  'é',
];

void main() {
  test(
    'arbitrary markdown never throws and always yields a valid document',
    () {
      for (var seed = 0; seed < 500; seed++) {
        final rng = Random(seed);
        final source = [
          for (var i = 0; i < 1 + rng.nextInt(30); i++)
            _pieces[rng.nextInt(_pieces.length)],
        ].join();
        final doc = markdownToQuire(source);
        expect(validateDocument(doc), isEmpty, reason: 'seed $seed: "$source"');
        // Export must also cope with whatever import produced.
        quireToMarkdown(doc);
      }
    },
  );

  test('exporting then re-importing keeps every line of text', () {
    for (var seed = 0; seed < 200; seed++) {
      final rng = Random(seed);
      final source = [
        for (var i = 0; i < 1 + rng.nextInt(12); i++)
          [
            '# Title $i',
            '- item $i',
            '1. step $i',
            '> quote $i',
            'plain $i',
            '**bold** $i',
          ][rng.nextInt(6)],
      ].join('\n');
      String texts(MutableDocument d) => d.nodesInDocumentOrder
          .whereType<TextNode>()
          .map((n) => n.text.text)
          .join('\n');
      final once = markdownToQuire(source);
      final twice = markdownToQuire(quireToMarkdown(once));
      expect(texts(twice), texts(once), reason: 'seed $seed: "$source"');
    }
  });
}
