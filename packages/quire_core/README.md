# quire_core

Pure-Dart document model and edit pipeline for the Quire rich text editor.
No Flutter dependency — the whole model, edit pipeline, and undo/redo run
on a server or inside a plain `dart test`, with no widget tree required.
[`quire`](https://github.com/Bambalow28/quire/tree/main/packages/quire) is
the Flutter widget layer built on top of it.

## Why

`flutter_quill`'s Quill Delta format is a flat list of operations, so nested
structures — tables with merged cells, nested lists, footnotes — can't be
represented cleanly. Quire's canonical model is a node tree with stable ids
instead; Delta (and Markdown) are import/export converters, not the storage
format. See the root
[README](https://github.com/Bambalow28/quire#readme) and
[RICHTEXT_PACKAGE_PLAN.md](https://github.com/Bambalow28/quire/blob/main/RICHTEXT_PACKAGE_PLAN.md)
for the full design rationale.

## Install

```
dart pub add quire_core
```

### Development

Inside this monorepo, sibling packages resolve `quire_core` via a path
dependency (see a sibling package's `pubspec_overrides.yaml`, if present) —
`quire_core` itself has no sibling dependencies.

## Usage

Every mutation goes through a single `Editor.execute` funnel:

```dart
import 'package:quire_core/quire_core.dart';

void main() {
  final document = MutableDocument(
    nodes: [TextNode(id: 'a', text: AttributedText('hello'))],
  );
  final composer = DocumentComposer();
  final editor = Editor(
    document,
    composer,
    requestHandlers: [...defaultRequestHandlers, historyRequestHandler],
  );

  editor.execute([
    InsertTextRequest(
      DocumentPosition('a', const TextNodePosition(5)),
      ' world',
    ),
  ]);

  print((document.getNodeById('a') as TextNode).text.text); // "hello world"
}
```

Wrap the editor in an `EditHistory` for undo/redo:

```dart
final history = EditHistory(editor);
history.execute([DeleteSelectionRequest()]);
history.undo();
history.redo();
```

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

## Development

```
dart pub get
dart analyze
dart test
```
