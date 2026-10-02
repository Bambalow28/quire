## 0.2.0

- `loadDocument`: loads stored JSON without ever throwing. Unreadable or
  unknown nodes are kept as `UnknownNode` and written back unchanged, duplicate
  ids are reissued, empty table cells and empty documents get a paragraph.
  Returns the repairs made and whether the JSON came from a newer schema.
- `MutableDocument.toJson` stamps `version` (`documentSchemaVersion`, now 1).
  Documents without one still load.
- `validateDocument`: lists structural problems (ids, spans, table grids,
  selection positions); never throws.
- `AttributedText.fromJson` clamps or drops spans that lie outside the text.
- Fix: deleting a selection that crossed a table crashed or left cells with no
  nodes. Text in different cells is no longer merged.
- Fix: toggling a style on a bare caret threw after a selection change.
- Undo history shares unchanged text nodes between snapshots, so a long
  document no longer costs a full copy per undo step.
- Non-text nodes carry `indent`, so images and tables can live inside a toggle
  or callout; `InsertNodeRequest` and `InsertTableRequest` inherit the depth of
  the line they follow.
- `MutableDocument.containerOf` and `isTopLevel`.
- Randomised edit/undo fuzz tests and `tool/benchmark.dart`.

## 0.1.0

Initial release: pure-Dart document model and edit pipeline for Quire, with
no Flutter dependency.

- **Document model**: `MutableDocument` addresses every node — including
  nodes nested inside table cells — by id, in document order.
- **Node types**: `TextNode` (paragraphs, headings, list items, blockquotes,
  code blocks, task items — distinguished by `blockType` metadata, with
  `indent`, `textAlign`, `lineSpacing`, and `checked`), `ImageNode`,
  `HorizontalRuleNode`, and `TableNode`.
- **Tables**: sparse grid storage (`TableRow`/`TableCell`) with merged cells
  via `rowSpan`/`colSpan`, resolved through `TableNode.grid`/`gridSize`/
  `cellAt`. Structural edits via `InsertTableRequest`,
  `InsertTableRowRequest`/`DeleteTableRowRequest`,
  `InsertTableColumnRequest`/`DeleteTableColumnRequest`, and
  `MergeTableCellsRequest`/`SplitTableCellRequest`.
- **Attributed text**: `AttributedText`/`Attribution`/`AttributionSpan` for
  inline styles and links, with normalized, non-overlapping spans per
  attribution name.
- **Edit pipeline**: a single `Editor.execute` funnel for all mutations,
  built on `EditRequest`/`EditCommand`/`EditReaction`/`EditListener`, with
  batched `EditEvent`s (`DocumentEdited`, `SelectionChanged`,
  `ComposingAttributionsChanged`) delivered once per outermost `execute` call.
- **Built-in commands**: text insert/delete, selection changes, newline
  splitting, toggling inline attributions, changing block type/indent/text
  alignment/line spacing, node insert/delete, merging with the previous
  node, and toggling a task item's checked state.
- **Undo/redo**: `EditHistory` wraps an `Editor` with snapshot-based
  undo/redo, coalescing runs of single-character inserts into one undo step.
- **Selection**: `DocumentSelection`/`DocumentPosition`/`DocumentComposer`,
  plus `flattenSelectionText` and `extractSelectionNodes` for copy.
- **Clipboard**: `QuireClipboard` — an in-memory rich clipboard that pairs
  plain text with the original `TextNode`s, for same-app formatted paste.
