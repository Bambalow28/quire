# quire_core

Pure-Dart document model and edit pipeline for the Quire rich text editor.
No Flutter dependency. Phase 1: document model + edit pipeline.

## Tables

`TableNode` holds a grid of `TableRow`/`TableCell`s, stored sparsely the way
HTML tables are: a cell covered by another cell's `rowSpan`/`colSpan` is not
present in the grid at all. Resolve the full grid with `TableNode.grid`,
`gridSize`, or `cellAt(row, column)` rather than reinventing span
resolution. A cell holds a list of block nodes (not just text), so it can
contain more than one paragraph.

Documents address every node — including nodes nested inside table cells —
by id via `MutableDocument`, so the existing text-editing commands work
inside a cell unmodified. Table-specific structure changes go through
`InsertTableRequest`, `InsertTableRowRequest`/`DeleteTableRowRequest`,
`InsertTableColumnRequest`/`DeleteTableColumnRequest`, and
`MergeTableCellsRequest`/`SplitTableCellRequest`, all routed through the
same `Editor.execute` funnel as everything else.
