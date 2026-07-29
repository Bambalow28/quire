# quire_markdown

Converts Markdown text into a Quire `MutableDocument`, and back again. Pure
Dart, no Flutter dependency — useful for importing existing Markdown notes
into a Quire-backed editor, or exporting a Quire document as Markdown.

## Installation

```
dart pub add quire_markdown
```

## Usage

```dart
import 'package:quire_markdown/quire_markdown.dart';

void main() {
  const markdown = '''
# Title

Some **bold** and *italic* text with a [link](https://example.com).

- [ ] todo item
- [x] done item
''';

  final doc = markdownToQuire(markdown);

  // Round-trip back to Markdown.
  final roundTripped = quireToMarkdown(doc);
  print(roundTripped);
}
```

`markdownToQuire` never throws — unrecognized lines become plain paragraphs,
and unterminated inline markers (a stray `*`, an unclosed code span) are kept
as literal text. If you're converting untrusted or non-String input upstream,
use `markdownToQuireOrNull`, which returns `null` instead of throwing.

## Supported Markdown

Maps onto the CommonMark subset that has a direct equivalent in Quire's node
types:

- Headings, levels 1-6
- Paragraphs
- Bullet, ordered, and task lists, with indentation
- Blockquotes
- Fenced code blocks
- Horizontal rules
- Inline styles: bold, italic, bold+italic, strikethrough, code spans, links

## Out of scope

- **Tables** — a GFM extension, not core Markdown, and Quire's table model
  (a nested row/cell grid) isn't a natural fit for a textual round trip.
- **Images** — `ImageNode` is skipped by `quireToMarkdown` rather than
  guessed at; `markdownToQuire` never produces one.
- **Footnotes** — not part of CommonMark.
