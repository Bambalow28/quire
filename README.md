# Quire

A rich text editor for Flutter, built from scratch, aiming at Word/Google-Docs
completeness rather than the lowest common denominator.

- **`packages/quire_core`** — pure-Dart document model and edit pipeline. No
  Flutter dependency, so it runs on a server and tests without a widget tree.
  Includes tables (`TableNode`), with merged cells (row/column spans).
- **`packages/quire`** — the Flutter editor widget, including a custom
  `RenderBox` (`TableGrid`) for rendering tables with spanning cells.

Why not `flutter_quill`: its Quill Delta format is a flat list of operations, so
nested structures (tables with merged cells, nested lists, footnotes) cannot be
represented cleanly. Quire's canonical model is a node tree with stable ids;
Delta is an import/export converter instead of the storage format.

See [RICHTEXT_PACKAGE_PLAN.md](../RICHTEXT_PACKAGE_PLAN.md) for the design
research and the phase plan.

## Status

Phase 1 (document model, single-funnel edit pipeline, undo/redo) is done and
tested. Not yet publishable — there is no UI.

## Development

```
export PATH="/Users/supremo/Documents/FlutterVersions/flutter/bin:$PATH"
cd packages/quire_core && dart pub get && dart analyze && dart test
```
