## 0.2.0

- `QuireEditorController(copyAsMarkdown: true)` puts Markdown on the system
  clipboard so formatting survives a paste into Notion and similar apps.
- Pasting Markdown now keeps tables, images and rules, not only text lines.
- Accessibility: headings, list items, tasks (with checked state), quotes,
  code, callouts, toggles, images and tables announce their role.
- Nodes this build does not know render as a labelled placeholder and are
  saved back untouched.
- Images, tables and rules nest inside toggles and callouts; a collapsed toggle
  hides them and a callout's border surrounds them.
- Golden tests for block rendering (tag `golden`, skipped in CI).

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
