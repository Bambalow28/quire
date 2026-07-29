import 'package:quire_markdown/quire_markdown.dart';

void main() {
  const markdown = '''
# Title

Some **bold** and *italic* text.

- [ ] todo item
- [x] done item
''';

  final doc = markdownToQuire(markdown);
  print('Parsed ${doc.nodes.length} nodes.');

  final roundTripped = quireToMarkdown(doc);
  print('Round-tripped Markdown:\n$roundTripped');
}
