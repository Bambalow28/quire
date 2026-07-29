## 0.1.0

- Initial release.
- `deltaToQuire` / `deltaJsonToQuire` / `deltaToQuireOrNull`: convert a Quill
  Delta ops list (as saved by `flutter_quill`) into a Quire `MutableDocument`.
  - Inline attributes: `bold`, `italic`, `underline`, `strike`, `code`,
    `link`, `color`, `background`, `font`, `size` map to `bold`, `italic`,
    `underline`, `strikethrough`, `code`, `link`, `color`, `backgroundColor`,
    `fontFamily`, `fontSize` attributions respectively.
  - Block attributes: `header` (1-6) maps to `header1`-`header6`; `list`
    (`ordered`/`bullet`/`checked`/`unchecked`) maps to `listItemOrdered`,
    `listItemUnordered`, or `listItemTask` (with `checked` metadata);
    `blockquote` maps to `blockquote`; `code-block` maps to `code`; `indent`
    and `align` are carried over as node metadata.
  - Embeds: `image` becomes an `ImageNode`; `video` becomes a `TextNode`
    linkified with the video URL; legacy `table` (JSON-encoded `cells` grid)
    becomes a `TableNode`, padded to a rectangle if ragged.
  - Malformed ops, corrupt attributes, corrupt table payloads, and unknown
    embed/inline-attribute types are never dropped silently: content is
    preserved (as plain text where structure can't be recovered) rather than
    losing the user's note.
- `plainTextOfQuireJson`: flattens a Quire document's JSON into plain text
  (one line per text node) for list previews/search.
