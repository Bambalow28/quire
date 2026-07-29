# quire_delta

Converts [Quill Delta](https://quilljs.com/docs/delta/) documents — the JSON
`List` of ops that `flutter_quill` saves — into Quire `MutableDocument`s.

Useful if you're migrating an app off `flutter_quill` onto Quire and need to
convert existing saved notes, or you need to import Delta JSON from another
source into a Quire document.

## Install

```
dart pub add quire_delta
```

## Usage

```dart
import 'package:quire_delta/quire_delta.dart';

void main() {
  // A Quill Delta ops list, e.g. loaded from storage as JSON.
  final delta = [
    {
      'insert': 'Meeting Notes\n',
      'attributes': {'header': 2},
    },
    {'insert': 'This is '},
    {
      'insert': 'important',
      'attributes': {'bold': true},
    },
    {'insert': ' context.\n'},
    {
      'insert': 'Buy milk\n',
      'attributes': {'list': 'checked'},
    },
  ];

  final doc = deltaToQuire(delta);
  for (final node in doc.nodesInDocumentOrder) {
    print(node);
  }

  // Or convert straight from a JSON string:
  // final doc = deltaJsonToQuire(jsonString);

  // Non-throwing variant, for callers that want to fall back to the
  // original note untouched if conversion fails:
  // final doc = deltaToQuireOrNull(delta);
}
```

`deltaToQuire` never throws on a malformed individual op — a bad op is
skipped and the rest of the document still converts; corrupt formatting or
a corrupt embed payload falls back to plain text rather than losing content.
It only throws if `delta` itself isn't a JSON list of ops, in which case use
`deltaToQuireOrNull` for a non-throwing wrapper.

There's also `plainTextOfQuireJson(String json)`, which flattens an already-
converted Quire document's own JSON into plain text (one line per text node)
for use in list previews or search indexing.

## What converts

- **Inline formatting**: bold, italic, underline, strikethrough, code, link,
  color, background color, font family, font size.
- **Block types**: headers (1-6), ordered/bullet lists, checked/unchecked
  task list items, blockquotes, code blocks, indent, and text alignment.
- **Embeds**: images, video links, and legacy JSON-encoded tables (ragged
  rows are padded to a rectangle).

## Out of scope

- No Quire-to-Delta conversion — this package only converts *into* Quire.
- Unrecognized inline attributes and embed types are not converted; text is
  kept but formatting/embed structure is dropped (unknown embeds are
  preserved as their raw JSON text so no data is lost).
- Only `image`, `video`, and legacy `table` embeds get dedicated node types;
  everything else falls back to plain text.

See `CHANGELOG.md` for the exact attribute/block mapping.
