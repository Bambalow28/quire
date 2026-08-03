import 'package:quire_core/quire_core.dart';

// ponytail: tables are out of scope (Quire's table model is a nested
// row/cell grid; CommonMark tables are a GFM extension, not core Markdown).
// [markdownToQuire] never produces a TableNode, and [quireToMarkdown] skips
// any TableNode it encounters rather than throwing or guessing at a textual
// representation.

final _headingRegex = RegExp(r'^(#{1,6})\s+(.*)$');
final _hrRegex = RegExp(r'^ {0,3}([-*_])(?: *\1){2,} *$');
final _orderedRegex = RegExp(r'^( *)\d+\.\s+(.*)$');
final _bulletRegex = RegExp(r'^( *)[-*]\s+(.*)$');
final _taskRegex = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _blockquoteRegex = RegExp(r'^> ?(.*)$');
final _fenceRegex = RegExp(r'^ {0,3}```');

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
          metadata: {'blockType': 'code'},
        ),
      );
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
      nodes.add(
        _textNode(heading.group(2)!, {'blockType': 'header$level'}),
      );
      i++;
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
/// [TextNode], [HorizontalRuleNode], and [ImageNode] are rendered —
/// [TableNode] is out of scope (see the file-level comment) and is simply
/// skipped, never thrown on.
String quireToMarkdown(MutableDocument doc) {
  final lines = <String>[];
  for (final node in doc.nodes) {
    if (node is HorizontalRuleNode) {
      lines.add('---');
    } else if (node is ImageNode) {
      lines.add('![${node.altText ?? ''}](${node.url})');
    } else if (node is TextNode) {
      lines.add(_lineFor(node));
    }
    // TableNode: unsupported (GFM extension, out of scope), skipped.
  }
  return lines.join('\n');
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

String _lineFor(TextNode node) {
  final prefix = _prefixFor(node);
  // Fenced code blocks are rendered verbatim (no inline markup inside code).
  if (node.blockType == 'code') {
    return '```\n${node.text.text}\n```';
  }
  return '$prefix${_renderInline(node.text)}';
}

String _prefixFor(TextNode node) {
  final indent = '  ' * node.indent;
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
          _InlineSegment(
            text.substring(i + 1, end),
            {const Attribution('code')},
          ),
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
          addWrapped(inner, Attribution('link', value: {'url': url}));
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
      final flanked = end == -1 ||
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

bool _isWordChar(String? c) =>
    c != null && RegExp(r'[A-Za-z0-9_]').hasMatch(c);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
