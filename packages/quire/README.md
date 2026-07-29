# quire

The Flutter widget layer for Quire — renders and edits a [`quire_core`](https://pub.dev/packages/quire_core)
`MutableDocument` as one `EditableText` per node, with cross-node selection,
a formatting toolbar, and find & replace built on top.

For the full rationale behind Quire's architecture, see the
[root README](https://github.com/Bambalow28/quire/blob/main/README.md).

## Features

- Tables, including spanning cells
- Checklists (task list items)
- Rich in-app copy/paste (preserves bold/italic/underline/strikethrough and
  block structure across nodes)
- Find & replace (`QuireFindBar`)
- Alignment and line-spacing controls, text-size menu

## Installation

```
flutter pub add quire
```

## Usage

```dart
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:quire/quire.dart';

class MyEditorPage extends StatefulWidget {
  const MyEditorPage({super.key});

  @override
  State<MyEditorPage> createState() => _MyEditorPageState();
}

class _MyEditorPageState extends State<MyEditorPage> {
  late final QuireEditorController _controller = QuireEditorController(
    document: MutableDocument(
      nodes: [
        TextNode(
          id: 'p1',
          text: AttributedText('Tap in and start typing.'),
          metadata: {'blockType': 'paragraph'},
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: QuireToolbar(controller: _controller),
      ),
    ),
    body: QuireEditor(controller: _controller),
  );
}
```

See `example/` for a fuller demo (headings, lists, blockquotes, code blocks,
and tables).

For the document model itself — nodes, attributed text, edit requests — see
[`quire_core`'s README](https://github.com/Bambalow28/quire/blob/main/packages/quire_core/README.md).

## Local development

This repo is a monorepo of sibling packages checked out side by side. The
`pubspec.yaml` here declares a normal hosted version constraint on
`quire_core` (what gets published and what consumers resolve), while
`pubspec_overrides.yaml` redirects that to the local `../quire_core` path
during development in this repo. It's excluded from what `pub publish`
ships and has no effect for consumers who install `quire` from pub.dev.
