## 0.1.0

- Initial release.
- `markdownToQuire` / `markdownToQuireOrNull`: converts Markdown text into a
  Quire `MutableDocument`. Covers headings (levels 1-6), paragraphs,
  bullet/ordered/task lists (with indentation), blockquotes, fenced code
  blocks, horizontal rules, and the inline styles bold, italic,
  bold+italic, strikethrough, code spans, and links.
- `quireToMarkdown`: converts a `MutableDocument` back into Markdown text,
  rendering `TextNode` and `HorizontalRuleNode`.
- Out of scope: GFM tables (Quire's table model is a nested row/cell grid,
  not a fit for CommonMark's table extension) and images — `TableNode` and
  `ImageNode` are skipped by `quireToMarkdown` rather than guessed at, and
  `markdownToQuire` never produces either. Footnotes are not part of
  CommonMark and are not handled either.
