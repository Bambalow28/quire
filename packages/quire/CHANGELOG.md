## 0.1.0

- `QuireEditor`: renders a `MutableDocument` as one `EditableText` per node,
  with editor-level cross-node selection, copy, and paste layered on top.
  Supports tables (including spanning cells), images, checklists, headings,
  lists, blockquotes, code blocks, and horizontal rules.
- `QuireEditorController`: owns the document, composer, editor, and undo/redo
  history; exposes formatting toggles, block-type and alignment/line-spacing
  changes, table editing (insert/delete row/column, merge/split cells), task
  checkbox toggling, and find & replace.
- `QuireToolbar`: formatting toolbar with a text-size menu (title/heading/
  subheading/body), alignment and line-spacing controls, table insertion
  (drag-to-size grid picker), and an expandable options panel for less
  frequent actions.
- `QuireFindBar`: an inline find & replace bar driven by
  `QuireEditorController`.
- Rich in-app copy/paste that preserves attributed text (bold, italic,
  underline, strikethrough) and block structure across nodes.
