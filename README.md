<h1 align="center">Quire</h1>

<p align="center">A rich text editor for Flutter, built from scratch for Word and Google Docs completeness.</p>

<p align="center"><sub>Dart · Flutter · the editor inside <a href="https://github.com/Bambalow28/notesync">NoteSync</a></sub></p>

## Packages

- **`packages/quire_core`**: pure-Dart document model and edit pipeline. No
  Flutter dependency, so it runs on a server and tests without a widget tree.
  Includes tables (`TableNode`), with merged cells (row/column spans).
- **`packages/quire`**: the Flutter editor widget, including a custom
  `RenderBox` (`TableGrid`) for rendering tables with spanning cells.
- **`packages/quire_delta`**: Quill Delta import and export.
- **`packages/quire_markdown`**: markdown import and export.

Why not `flutter_quill`: its Quill Delta format is a flat list of operations, so
nested structures (tables with merged cells, nested lists, footnotes) cannot be
represented cleanly. Quire's canonical model is a node tree with stable ids;
Delta is an import/export converter instead of the storage format.

## Status

In daily use as NoteSync's editor: checklists, tables with merged cells,
callouts, toggles, links, emoji, markdown shortcuts and paste, auto-linking,
and its own text input client for hardware keyboards and IME. Not yet published
to pub.dev.

## Loading stored documents

Use `loadDocument` rather than `MutableDocument.fromJson` for anything read
from disk or a server. It never throws, keeps content it does not understand
(`UnknownNode`), repairs broken structure and reports what it did. If
`fromNewerVersion` is true, open the document read-only: saving from an older
build could drop content it cannot see.

## Development

```bash
cd packages/quire_core && dart pub get && dart analyze && dart test
dart run tool/benchmark.dart   # edit/undo timings on 5k to 100k word documents
```

Run `docs/MANUAL_TEST_CHECKLIST.md` on a device before releasing changes to
input handling. Golden tests (`flutter test --tags golden`) are regenerated
with `--update-goldens` and are only valid on the machine that made them.
