import 'package:quire_core/quire_core.dart';

// ponytail: tables follow GFM, which has no merged cells and no per-cell
// blocks. Import gives one paragraph per cell; export writes the origin cell's
// text once and leaves the positions it spans empty, so a merged table
// round-trips as a flat one. Upgrade to HTML tables if merges must survive.

final _headingRegex = RegExp(r'^(#{1,6})\s+(.*)$');
final _hrRegex = RegExp(r'^ {0,3}([-*_])(?: *\1){2,} *$');
final _orderedRegex = RegExp(r'^( *)\d+\.\s+(.*)$');
final _bulletRegex = RegExp(r'^( *)[-*]\s+(.*)$');
final _taskRegex = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _blockquoteRegex = RegExp(r'^> ?(.*)$');
final _fenceRegex = RegExp(r'^ {0,3}```');

/// A link to another note round-trips as `[title](quire-note:ID)`.
const _noteLinkScheme = 'quire-note:';

/// Converts [markdown] text into a [MutableDocument].
///
/// Covers a CommonMark subset that maps directly onto Quire's existing node
/// types: headings, paragraphs, bullet/ordered/task lists, blockquotes,
/// fenced code blocks, horizontal rules, and the inline styles bold/italic/
/// strikethrough/code/links. Never throws — an unrecognized line just
/// becomes a paragraph, and an unterminated inline marker (e.g. a stray `*`)
/// is kept as literal text (see [markdownToQuireOrNull] for a wrapper that
/// also survives a non-String input upstream).
MutableDocument markdownToQuire(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final nodes = <DocumentNode>[];

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    if (_fenceRegex.hasMatch(line)) {
      final language = line.trim().substring(3).trim().toLowerCase();
      final buffer = StringBuffer();
      i++;
      while (i < lines.length && !_fenceRegex.hasMatch(lines[i])) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(lines[i]);
        i++;
      }
      i++; // consume the closing fence (or run off the end if unterminated)
      nodes.add(
        TextNode(
          id: generateNodeId(),
          text: AttributedText(buffer.toString()),
          metadata: {
            'blockType': 'code',
            if (language.isNotEmpty) 'language': language,
          },
        ),
      );
      continue;
    }

    final container = _containerOpen(line);
    if (container != null) {
      final inner = <String>[];
      i++;
      var depth = 1;
      while (i < lines.length) {
        if (_containerOpen(lines[i]) != null) {
          depth++;
        } else if (_anyClose.hasMatch(lines[i]) && --depth == 0) {
          break;
        }
        inner.add(lines[i]);
        i++;
      }
      i++; // consume the closing tag (or run off the end if unterminated)
      nodes.addAll(_containerNodes(container, inner));
      continue;
    }

    if (_hrRegex.hasMatch(line)) {
      nodes.add(HorizontalRuleNode(id: generateNodeId()));
      i++;
      continue;
    }

    final heading = _headingRegex.firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      nodes.add(_textNode(heading.group(2)!, {'blockType': 'header$level'}));
      i++;
      continue;
    }

    if (i + 1 < lines.length && _isTableStart(line, lines[i + 1])) {
      final rows = <List<String>>[_splitRow(line)];
      final width = rows.first.length;
      i += 2; // header and delimiter rows
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          lines[i].contains('|')) {
        rows.add(_splitRow(lines[i]));
        i++;
      }
      nodes.add(_tableNode(rows, width));
      continue;
    }

    final blockquote = _blockquoteRegex.firstMatch(line);
    if (blockquote != null) {
      nodes.add(_textNode(blockquote.group(1)!, {'blockType': 'blockquote'}));
      i++;
      continue;
    }

    final bullet = _bulletRegex.firstMatch(line);
    if (bullet != null) {
      final indent = bullet.group(1)!.length ~/ 2;
      final rest = bullet.group(2)!;
      final task = _taskRegex.firstMatch(rest);
      if (task != null) {
        final checked = task.group(1)!.toLowerCase() == 'x';
        nodes.add(
          _textNode(task.group(2)!, {
            'blockType': 'listItemTask',
            'checked': checked,
            if (indent > 0) 'indent': indent,
          }),
        );
      } else {
        nodes.add(
          _textNode(rest, {
            'blockType': 'listItemUnordered',
            if (indent > 0) 'indent': indent,
          }),
        );
      }
      i++;
      continue;
    }

    final ordered = _orderedRegex.firstMatch(line);
    if (ordered != null) {
      final indent = ordered.group(1)!.length ~/ 2;
      nodes.add(
        _textNode(ordered.group(2)!, {
          'blockType': 'listItemOrdered',
          if (indent > 0) 'indent': indent,
        }),
      );
      i++;
      continue;
    }

    nodes.add(_textNode(line, const {'blockType': 'paragraph'}));
    i++;
  }

  if (nodes.isEmpty) {
    nodes.add(_textNode('', const {'blockType': 'paragraph'}));
  }

  return MutableDocument(nodes: nodes);
}

// Notion copies a callout as `<aside>…</aside>` and a toggle as
// `<details><summary>…</summary>…</details>`. Both map onto a title node plus
// content indented one level deeper.
class _Container {
  _Container(this.blockType, this.close, [this.summary]);
  final String blockType;
  final RegExp close;
  final String? summary;
}

final _asideOpen = RegExp(r'^\s*<aside>\s*$');
final _detailsOpen = RegExp(
  r'^\s*<details>\s*(?:<summary>(.*?)</summary>)?\s*$',
);
final _anyClose = RegExp(r'^\s*</(?:aside|details)>\s*$');
final _summaryLine = RegExp(r'^\s*<summary>(.*?)</summary>\s*$');

_Container? _containerOpen(String line) {
  if (_asideOpen.hasMatch(line)) {
    return _Container('callout', RegExp(r'^\s*</aside>\s*$'));
  }
  final details = _detailsOpen.firstMatch(line);
  if (details != null) {
    return _Container(
      'toggleList',
      RegExp(r'^\s*</details>\s*$'),
      details.group(1),
    );
  }
  return null;
}

/// Stands in for an empty callout title so the content below isn't mistaken
/// for it on re-import.
const _emptyTitle = '\u200b';

/// No letters or digits — the lone icon line Notion puts above a callout.
bool _isIconOnly(String text) =>
    text != _emptyTitle &&
    !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text);

List<DocumentNode> _containerNodes(_Container c, List<String> inner) {
  var summary = c.summary;
  if (summary == null && c.blockType == 'toggleList') {
    final at = inner.indexWhere((l) => l.trim().isNotEmpty);
    final m = at < 0 ? null : _summaryLine.firstMatch(inner[at]);
    if (m != null) {
      summary = m.group(1);
      inner.removeAt(at);
    }
  }
  final body = markdownToQuire(inner.join('\n')).nodes.toList();
  // markdownToQuire pads an empty document with one empty paragraph.
  if (body.length == 1 && body.first is TextNode) {
    if ((body.first as TextNode).text.text.isEmpty) body.clear();
  }
  TextNode title;
  if (summary != null) {
    title = _textNode(summary, const {'blockType': 'toggleList'});
  } else {
    // A callout's icon sits on its own line; the title is the line after it.
    if (body.length > 1 &&
        body.first is TextNode &&
        _isIconOnly((body.first as TextNode).text.text)) {
      body.removeAt(0);
    }
    // Only a text line can be the title — a list item first means the title
    // is empty (our own export marks that with a lone ZWSP line).
    var first =
        body.isNotEmpty &&
            body.first is TextNode &&
            !(body.first as TextNode).blockType.startsWith('listItem')
        ? body.removeAt(0) as TextNode
        : null;
    if (first != null && first.text.text == _emptyTitle) first = null;
    title = TextNode(
      id: generateNodeId(),
      text: first?.text ?? AttributedText(''),
      metadata: {'blockType': c.blockType},
    );
  }
  for (final n in body) {
    n.metadata['indent'] = n.indent + 1;
  }
  return [title, ...body];
}

/// Same as [markdownToQuire] but returns `null` instead of throwing.
MutableDocument? markdownToQuireOrNull(String markdown) {
  try {
    return markdownToQuire(markdown);
  } catch (_) {
    return null;
  }
}

/// Converts a [MutableDocument] back into Markdown text.
///
/// [TextNode], [HorizontalRuleNode], [ImageNode] and [TableNode] (as a GFM
/// table, see the file-level comment) are rendered; anything else is skipped,
/// never thrown on.
String quireToMarkdown(MutableDocument doc) {
  return _renderNodes(doc.nodes.toList(), 0).join('\n');
}

/// Renders [nodes]; [base] is the indent that counts as the left margin, so a
/// container's content (one level deeper) comes out as top-level markdown.
List<String> _renderNodes(List<DocumentNode> nodes, int base) {
  final lines = <String>[];
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (node is HorizontalRuleNode) {
      lines.add('---');
    } else if (node is ImageNode) {
      lines.add('![${node.altText ?? ''}](${node.url})');
    } else if (node is TextNode) {
      final type = node.blockType;
      if (type != 'callout' && type != 'toggleList') {
        lines.add(_lineFor(node, base));
        continue;
      }
      var end = i + 1;
      while (end < nodes.length && nodes[end].indent > node.indent) {
        end++;
      }
      final inner = _renderNodes(nodes.sublist(i + 1, end), node.indent + 1);
      final rendered = _renderInline(node.text);
      final title = rendered.isEmpty && inner.isNotEmpty
          ? _emptyTitle
          : rendered;
      if (type == 'callout') {
        lines.addAll(['<aside>', title, '', ...inner, '</aside>']);
      } else {
        lines.addAll([
          '<details><summary>$title</summary>',
          '',
          ...inner,
          '</details>',
        ]);
      }
      i = end - 1;
    } else if (node is TableNode) {
      lines.addAll(_tableLines(node));
    }
  }
  return lines;
}

TextNode _textNode(String content, Map<String, Object?> metadata) {
  final segments = _parseInline(content);
  final buffer = StringBuffer();
  final spans = <AttributionSpan>[];
  var offset = 0;
  for (final seg in segments) {
    for (final a in seg.attributions) {
      spans.add(AttributionSpan(a, offset, offset + seg.text.length));
    }
    buffer.write(seg.text);
    offset += seg.text.length;
  }
  return TextNode(
    id: generateNodeId(),
    text: AttributedText(buffer.toString(), spans),
    metadata: Map<String, Object?>.from(metadata),
  );
}

String _lineFor(TextNode node, int base) {
  final prefix = _prefixFor(node, base);
  // Fenced code blocks are rendered verbatim (no inline markup inside code).
  if (node.blockType == 'code') {
    final language = node.metadata['language'] as String? ?? '';
    return '```$language\n${node.text.text}\n```';
  }
  return '$prefix${_renderInline(node.text)}';
}

String _prefixFor(TextNode node, int base) {
  final indent = '  ' * (node.indent - base);
  switch (node.blockType) {
    case 'header1':
      return '# ';
    case 'header2':
      return '## ';
    case 'header3':
      return '### ';
    case 'header4':
      return '#### ';
    case 'header5':
      return '##### ';
    case 'header6':
      return '###### ';
    case 'listItemUnordered':
      return '$indent- ';
    case 'listItemOrdered':
      // ponytail: always "1." — CommonMark only requires the list's first
      // marker to set the start number, later markers can repeat it, and
      // our own parser only checks for `digit+ '.' ' '` anyway.
      return '${indent}1. ';
    case 'listItemTask':
      return '$indent- [${node.isChecked ? 'x' : ' '}] ';
    case 'blockquote':
      return '> ';
    default:
      return '';
  }
}

// --- Inline markup ---------------------------------------------------------

class _InlineSegment {
  _InlineSegment(this.text, this.attributions);
  final String text;
  final Set<Attribution> attributions;
}

/// Recursive-descent inline scanner: code spans and links/strikethrough/bold
/// wrap arbitrary sub-content, so their insides are re-parsed rather than
/// treated as opaque text. Any delimiter without a matching close is kept as
/// literal text — this never throws.
List<_InlineSegment> _parseInline(String text) {
  final result = <_InlineSegment>[];
  final buffer = StringBuffer();
  var i = 0;

  void flushPlain() {
    if (buffer.isNotEmpty) {
      result.add(_InlineSegment(buffer.toString(), const {}));
      buffer.clear();
    }
  }

  void addWrapped(String inner, Attribution extra) {
    for (final seg in _parseInline(inner)) {
      result.add(_InlineSegment(seg.text, {...seg.attributions, extra}));
    }
  }

  while (i < text.length) {
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end != -1) {
        flushPlain();
        result.add(
          _InlineSegment(text.substring(i + 1, end), {
            const Attribution('code'),
          }),
        );
        i = end + 1;
        continue;
      }
    }

    if (text[i] == '[') {
      final closeBracket = _matchingCloseBracket(text, i + 1);
      if (closeBracket != -1 &&
          closeBracket + 1 < text.length &&
          text[closeBracket + 1] == '(') {
        final closeParen = text.indexOf(')', closeBracket + 2);
        if (closeParen != -1) {
          flushPlain();
          final inner = text.substring(i + 1, closeBracket);
          final url = text.substring(closeBracket + 2, closeParen);
          addWrapped(
            inner,
            url.startsWith(_noteLinkScheme)
                ? Attribution(
                    'noteLink',
                    value: {'id': url.substring(_noteLinkScheme.length)},
                  )
                : Attribution('link', value: {'url': url}),
          );
          i = closeParen + 1;
          continue;
        }
      }
    }

    if (text.startsWith('~~', i)) {
      final end = text.indexOf('~~', i + 2);
      if (end != -1 && end > i + 2) {
        flushPlain();
        addWrapped(
          text.substring(i + 2, end),
          const Attribution('strikethrough'),
        );
        i = end + 2;
        continue;
      }
    }

    if (text.startsWith('***', i)) {
      final end = text.indexOf('***', i + 3);
      if (end != -1 && end > i + 3) {
        flushPlain();
        for (final seg in _parseInline(text.substring(i + 3, end))) {
          result.add(
            _InlineSegment(seg.text, {
              ...seg.attributions,
              const Attribution('bold'),
              const Attribution('italic'),
            }),
          );
        }
        i = end + 3;
        continue;
      }
    }

    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end != -1 && end > i + 2) {
        flushPlain();
        addWrapped(text.substring(i + 2, end), const Attribution('bold'));
        i = end + 2;
        continue;
      }
    }

    if (text[i] == '*' || text[i] == '_') {
      final marker = text[i];
      final end = text.indexOf(marker, i + 1);
      // CommonMark: `_` emphasis requires non-word-character flanking (no
      // intraword matches like `foo_bar_baz`); `*` has no such restriction.
      final flanked =
          end == -1 ||
          marker != '_' ||
          (!_isWordChar(i > 0 ? text[i - 1] : null) &&
              !_isWordChar(end + 1 < text.length ? text[end + 1] : null));
      if (end != -1 && end > i + 1 && flanked) {
        flushPlain();
        addWrapped(text.substring(i + 1, end), const Attribution('italic'));
        i = end + 1;
        continue;
      }
    }

    buffer.write(text[i]);
    i++;
  }

  flushPlain();
  return result;
}

/// Coalesces [text]'s attribution spans into markdown, nesting markers in a
/// fixed order (code innermost — markdown doesn't nest markup inside a code
/// span, so any other attribution on that run is dropped — then bold/
/// italic, then strikethrough, then link outermost).
String _renderInline(AttributedText text) {
  if (text.text.isEmpty) return '';
  final breakpoints = <int>{0, text.text.length};
  for (final span in text.spans) {
    breakpoints.add(span.start);
    breakpoints.add(span.end);
  }
  final sorted = breakpoints.toList()..sort();

  final buffer = StringBuffer();
  for (var i = 0; i < sorted.length - 1; i++) {
    final start = sorted[i];
    final end = sorted[i + 1];
    if (start >= end) continue;
    final attrs = text.attributionsAt(start);
    buffer.write(_renderRun(text.text.substring(start, end), attrs));
  }
  return buffer.toString();
}

String _renderRun(String run, Set<Attribution> attrs) {
  if (attrs.any((a) => a.name == 'code')) {
    return '`$run`';
  }

  var rendered = run;
  final bold = attrs.any((a) => a.name == 'bold');
  final italic = attrs.any((a) => a.name == 'italic');
  if (bold && italic) {
    rendered = '***$rendered***';
  } else if (bold) {
    rendered = '**$rendered**';
  } else if (italic) {
    rendered = '*$rendered*';
  }

  if (attrs.any((a) => a.name == 'strikethrough')) {
    rendered = '~~$rendered~~';
  }

  final noteLink = attrs.where((a) => a.name == 'noteLink').firstOrNull;
  if (noteLink != null) {
    rendered = '[$rendered]($_noteLinkScheme${noteLink.value['id'] ?? ''})';
  }

  final link = attrs.where((a) => a.name == 'link').firstOrNull;
  if (link != null) {
    final url = link.value['url'] as String? ?? '';
    rendered = '[$rendered]($url)';
  }

  return rendered;
}

/// Finds the `]` pairing with the `[` that opened at `start - 1`, tolerating
/// nested `[...]` inside link text (e.g. `[a [b] c](url)`).
int _matchingCloseBracket(String text, int start) {
  var depth = 0;
  for (var j = start; j < text.length; j++) {
    if (text[j] == '[') {
      depth++;
    } else if (text[j] == ']') {
      if (depth == 0) return j;
      depth--;
    }
  }
  return -1;
}

bool _isWordChar(String? c) => c != null && RegExp(r'[A-Za-z0-9_]').hasMatch(c);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// --- GFM tables ------------------------------------------------------------

final _lineBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final _delimiterCell = RegExp(r'^\s*:?-+:?\s*$');

List<String> _splitRow(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|') && !text.endsWith(r'\|')) {
    text = text.substring(0, text.length - 1);
  }
  final cells = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == r'\' && i + 1 < text.length && text[i + 1] == '|') {
      buffer.write('|');
      i++;
    } else if (c == '|') {
      cells.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  cells.add(buffer.toString().trim());
  return cells;
}

bool _isTableStart(String header, String delimiter) {
  if (!header.contains('|') || !delimiter.contains('-')) return false;
  final head = _splitRow(header);
  final delim = _splitRow(delimiter);
  return head.length == delim.length && delim.every(_delimiterCell.hasMatch);
}

TableNode _tableNode(List<List<String>> rows, int width) => TableNode(
  id: generateNodeId(),
  rows: [
    for (final row in rows)
      TableRow(
        cells: [
          for (var c = 0; c < width; c++)
            TableCell(
              // Export joins a cell's paragraphs with <br>; split them back.
              nodes: [
                for (final part in (c < row.length ? row[c] : '').split(
                  _lineBreak,
                ))
                  _textNode(part.trim(), const {'blockType': 'paragraph'}),
              ],
            ),
        ],
      ),
  ],
);

List<String> _tableLines(TableNode table) {
  final grid = table.grid;
  if (grid.isEmpty || grid.first.isEmpty) return const [];
  final seen = <TableCell>{};
  String row(List<TableCell?> cells) {
    final out = <String>[];
    for (final cell in cells) {
      if (cell == null || !seen.add(cell)) {
        out.add('');
        continue;
      }
      out.add(
        cell.nodes
            .whereType<TextNode>()
            .map((n) => _renderInline(n.text))
            .join('<br>')
            .replaceAll('|', r'\|')
            .replaceAll('\n', ' '),
      );
    }
    return '| ${out.join(' | ')} |';
  }

  return [
    row(grid.first),
    '| ${List.filled(grid.first.length, '---').join(' | ')} |',
    for (final r in grid.skip(1)) row(r),
  ];
}
