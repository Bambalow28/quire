/// A deliberately small tokenizer for the code block's language label: enough
/// to colour keywords, strings, numbers, comments and type names in the
/// languages people paste into notes. It is not a parser — it never fails,
/// and unknown text just stays plain.
enum SyntaxToken { keyword, string, number, comment, type, literal }

typedef SyntaxRun = ({int start, int end, SyntaxToken token});

/// The languages the code block's picker offers, as `(id, label)`. The id is
/// what lands in the node's `language` metadata and in a Markdown fence.
const kCodeLanguages = <(String, String)>[
  ('plain', 'Plain text'),
  ('dart', 'Dart'),
  ('swift', 'Swift'),
  ('kotlin', 'Kotlin'),
  ('java', 'Java'),
  ('javascript', 'JavaScript'),
  ('typescript', 'TypeScript'),
  ('python', 'Python'),
  ('go', 'Go'),
  ('rust', 'Rust'),
  ('c', 'C'),
  ('cpp', 'C++'),
  ('csharp', 'C#'),
  ('ruby', 'Ruby'),
  ('php', 'PHP'),
  ('sql', 'SQL'),
  ('json', 'JSON'),
  ('yaml', 'YAML'),
  ('html', 'HTML'),
  ('css', 'CSS'),
  ('bash', 'Shell'),
];

const _aliases = {
  'js': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'kt': 'kotlin',
  'cs': 'csharp',
  'c++': 'cpp',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'yml': 'yaml',
  'text': 'plain',
  'txt': 'plain',
};

/// The canonical id for a label typed in a fence (`js`, `Python`), or null
/// when it names nothing this editor knows.
String? canonicalLanguage(String? raw) {
  if (raw == null) return null;
  final key = raw.trim().toLowerCase();
  if (key.isEmpty) return null;
  final id = _aliases[key] ?? key;
  return kCodeLanguages.any((l) => l.$1 == id) ? id : null;
}

String languageLabel(String? raw) {
  final id = canonicalLanguage(raw);
  for (final l in kCodeLanguages) {
    if (l.$1 == id) return l.$2;
  }
  return 'Plain text';
}

class _Grammar {
  const _Grammar({
    required this.keywords,
    this.literals = const {},
    this.line = const ['//'],
    this.block = false,
    this.quotes = '"\'`',
    this.types = true,
    this.caseInsensitive = false,
  });
  final Set<String> keywords;
  final Set<String> literals;
  final List<String> line;
  final bool block;
  final String quotes;
  final bool types;
  final bool caseInsensitive;
}

const _cLike = {
  'if',
  'else',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'new',
  'class',
  'struct',
  'enum',
  'static',
  'const',
  'try',
  'catch',
  'finally',
  'throw',
  'import',
  'public',
  'private',
  'void',
};

final _grammars = <String, _Grammar>{
  'dart': _Grammar(
    keywords: {
      ..._cLike,
      'abstract',
      'as',
      'async',
      'await',
      'covariant',
      'extends',
      'extension',
      'external',
      'factory',
      'final',
      'implements',
      'in',
      'is',
      'late',
      'library',
      'mixin',
      'on',
      'part',
      'required',
      'rethrow',
      'set',
      'get',
      'super',
      'this',
      'typedef',
      'var',
      'with',
      'yield',
      'show',
      'hide',
      'export',
      'sealed',
      'base',
      'interface',
      'when',
    },
    literals: {'true', 'false', 'null'},
    block: true,
  ),
  'swift': _Grammar(
    keywords: {
      ..._cLike,
      'func',
      'let',
      'var',
      'guard',
      'in',
      'is',
      'as',
      'self',
      'super',
      'init',
      'deinit',
      'protocol',
      'extension',
      'where',
      'defer',
      'async',
      'await',
      'actor',
      'some',
      'any',
      'inout',
      'throws',
      'rethrows',
      'internal',
      'fileprivate',
      'open',
      'override',
      'final',
      'lazy',
      'weak',
      'typealias',
      'associatedtype',
      'subscript',
      'operator',
      'repeat',
    },
    literals: {'true', 'false', 'nil'},
    block: true,
  ),
  'kotlin': _Grammar(
    keywords: {
      ..._cLike,
      'fun',
      'val',
      'var',
      'when',
      'in',
      'is',
      'as',
      'object',
      'interface',
      'override',
      'open',
      'data',
      'sealed',
      'companion',
      'init',
      'this',
      'super',
      'suspend',
      'lateinit',
      'by',
      'where',
      'typealias',
      'package',
      'internal',
      'protected',
      'inline',
      'abstract',
      'final',
    },
    literals: {'true', 'false', 'null'},
    block: true,
  ),
  'java': _Grammar(
    keywords: {
      ..._cLike,
      'abstract',
      'extends',
      'implements',
      'interface',
      'final',
      'instanceof',
      'package',
      'protected',
      'synchronized',
      'this',
      'super',
      'throws',
      'volatile',
      'transient',
      'native',
      'assert',
      'var',
      'record',
    },
    literals: {'true', 'false', 'null'},
    block: true,
  ),
  'javascript': _Grammar(
    keywords: {
      ..._cLike,
      'function',
      'let',
      'var',
      'async',
      'await',
      'of',
      'in',
      'typeof',
      'instanceof',
      'extends',
      'super',
      'this',
      'export',
      'from',
      'yield',
      'delete',
      'with',
      'debugger',
      'get',
      'set',
      'static',
    },
    literals: {'true', 'false', 'null', 'undefined', 'NaN', 'Infinity'},
    block: true,
  ),
  'typescript': _Grammar(
    keywords: {
      ..._cLike,
      'function',
      'let',
      'var',
      'async',
      'await',
      'of',
      'in',
      'typeof',
      'instanceof',
      'extends',
      'implements',
      'interface',
      'type',
      'super',
      'this',
      'export',
      'from',
      'yield',
      'readonly',
      'abstract',
      'declare',
      'namespace',
      'as',
      'is',
      'keyof',
      'protected',
      'satisfies',
    },
    literals: {'true', 'false', 'null', 'undefined', 'NaN', 'Infinity'},
    block: true,
  ),
  'python': _Grammar(
    keywords: {
      'and',
      'as',
      'assert',
      'async',
      'await',
      'break',
      'class',
      'continue',
      'def',
      'del',
      'elif',
      'else',
      'except',
      'finally',
      'for',
      'from',
      'global',
      'if',
      'import',
      'in',
      'is',
      'lambda',
      'nonlocal',
      'not',
      'or',
      'pass',
      'raise',
      'return',
      'try',
      'while',
      'with',
      'yield',
      'match',
      'case',
      'self',
    },
    literals: {'True', 'False', 'None'},
    line: ['#'],
    quotes: '"\'',
  ),
  'go': _Grammar(
    keywords: {
      'break',
      'case',
      'chan',
      'const',
      'continue',
      'default',
      'defer',
      'else',
      'fallthrough',
      'for',
      'func',
      'go',
      'goto',
      'if',
      'import',
      'interface',
      'map',
      'package',
      'range',
      'return',
      'select',
      'struct',
      'switch',
      'type',
      'var',
    },
    literals: {'true', 'false', 'nil', 'iota'},
    block: true,
  ),
  'rust': _Grammar(
    keywords: {
      'as',
      'async',
      'await',
      'break',
      'const',
      'continue',
      'crate',
      'dyn',
      'else',
      'enum',
      'extern',
      'fn',
      'for',
      'if',
      'impl',
      'in',
      'let',
      'loop',
      'match',
      'mod',
      'move',
      'mut',
      'pub',
      'ref',
      'return',
      'self',
      'Self',
      'static',
      'struct',
      'super',
      'trait',
      'type',
      'unsafe',
      'use',
      'where',
      'while',
    },
    literals: {'true', 'false'},
    block: true,
    quotes: '"',
  ),
  'c': _Grammar(
    keywords: {
      ..._cLike,
      'typedef',
      'union',
      'extern',
      'sizeof',
      'goto',
      'register',
      'volatile',
      'inline',
      'signed',
      'unsigned',
      'include',
      'define',
    },
    literals: {'NULL', 'true', 'false'},
    block: true,
    quotes: '"\'',
  ),
  'cpp': _Grammar(
    keywords: {
      ..._cLike,
      'typedef',
      'union',
      'extern',
      'sizeof',
      'namespace',
      'using',
      'template',
      'typename',
      'virtual',
      'override',
      'final',
      'auto',
      'constexpr',
      'nullptr',
      'this',
      'delete',
      'operator',
      'protected',
      'include',
      'define',
      'friend',
      'explicit',
      'noexcept',
    },
    literals: {'NULL', 'true', 'false', 'nullptr'},
    block: true,
    quotes: '"\'',
  ),
  'csharp': _Grammar(
    keywords: {
      ..._cLike,
      'abstract',
      'as',
      'async',
      'await',
      'base',
      'bool',
      'event',
      'extends',
      'foreach',
      'in',
      'interface',
      'internal',
      'is',
      'lock',
      'namespace',
      'null',
      'override',
      'params',
      'readonly',
      'ref',
      'out',
      'sealed',
      'this',
      'using',
      'var',
      'virtual',
      'yield',
      'record',
      'get',
      'set',
      'protected',
      'partial',
    },
    literals: {'true', 'false', 'null'},
    block: true,
    quotes: '"\'',
  ),
  'ruby': _Grammar(
    keywords: {
      'alias',
      'and',
      'begin',
      'break',
      'case',
      'class',
      'def',
      'defined?',
      'do',
      'else',
      'elsif',
      'end',
      'ensure',
      'for',
      'if',
      'in',
      'module',
      'next',
      'not',
      'or',
      'redo',
      'rescue',
      'retry',
      'return',
      'self',
      'super',
      'then',
      'undef',
      'unless',
      'until',
      'when',
      'while',
      'yield',
      'require',
      'attr_accessor',
      'attr_reader',
    },
    literals: {'true', 'false', 'nil'},
    line: ['#'],
    quotes: '"\'',
  ),
  'php': _Grammar(
    keywords: {
      ..._cLike,
      'function',
      'echo',
      'foreach',
      'as',
      'namespace',
      'use',
      'extends',
      'implements',
      'interface',
      'abstract',
      'final',
      'protected',
      'fn',
      'match',
      'trait',
      'global',
      'isset',
      'unset',
      'empty',
      'array',
    },
    literals: {'true', 'false', 'null', 'TRUE', 'FALSE', 'NULL'},
    line: ['//', '#'],
    block: true,
    quotes: '"\'',
  ),
  'sql': _Grammar(
    keywords: {
      'select',
      'from',
      'where',
      'and',
      'or',
      'not',
      'insert',
      'into',
      'values',
      'update',
      'set',
      'delete',
      'create',
      'table',
      'alter',
      'drop',
      'index',
      'join',
      'inner',
      'left',
      'right',
      'outer',
      'full',
      'on',
      'as',
      'group',
      'by',
      'order',
      'having',
      'limit',
      'offset',
      'distinct',
      'union',
      'all',
      'in',
      'is',
      'like',
      'between',
      'exists',
      'case',
      'when',
      'then',
      'else',
      'end',
      'primary',
      'key',
      'foreign',
      'references',
      'default',
      'constraint',
      'unique',
      'with',
      'asc',
      'desc',
      'view',
      'begin',
      'commit',
      'rollback',
    },
    literals: {'null', 'true', 'false'},
    line: ['--'],
    block: true,
    quotes: '"\'',
    types: false,
    caseInsensitive: true,
  ),
  'json': _Grammar(
    keywords: {},
    literals: {'true', 'false', 'null'},
    line: [],
    quotes: '"',
    types: false,
  ),
  'yaml': _Grammar(
    keywords: {},
    literals: {'true', 'false', 'null', 'yes', 'no'},
    line: ['#'],
    quotes: '"\'',
    types: false,
  ),
  'bash': _Grammar(
    keywords: {
      'if',
      'then',
      'else',
      'elif',
      'fi',
      'for',
      'while',
      'do',
      'done',
      'case',
      'esac',
      'function',
      'in',
      'return',
      'exit',
      'export',
      'local',
      'echo',
      'cd',
      'source',
      'set',
      'unset',
      'readonly',
      'select',
      'until',
    },
    literals: {'true', 'false'},
    line: ['#'],
    quotes: '"\'',
    types: false,
  ),
  'html': _Grammar(keywords: {}, line: [], quotes: '"\'', types: false),
  'css': _Grammar(
    keywords: {
      'important',
      'media',
      'import',
      'keyframes',
      'font-face',
      'supports',
    },
    line: [],
    block: true,
    quotes: '"\'',
    types: false,
  ),
};

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x24;
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isIdentPart(int c) => _isIdentStart(c) || _isDigit(c);

/// Highlight runs for [text] in [language] (an id from [kCodeLanguages]).
/// Empty for plain text or an unknown language. Runs never overlap and are
/// in order; anything between them is plain.
List<SyntaxRun> highlight(String text, String? language) {
  final id = canonicalLanguage(language);
  final grammar = id == null ? null : _grammars[id];
  if (grammar == null || text.isEmpty) return const [];
  final runs = <SyntaxRun>[];
  final n = text.length;
  var i = 0;

  bool startsWithAt(String s, int at) => text.startsWith(s, at);

  while (i < n) {
    final c = text.codeUnitAt(i);

    // Comments.
    String? lineMarker;
    for (final m in grammar.line) {
      if (startsWithAt(m, i)) {
        lineMarker = m;
        break;
      }
    }
    if (lineMarker != null) {
      var end = text.indexOf('\n', i);
      if (end < 0) end = n;
      runs.add((start: i, end: end, token: SyntaxToken.comment));
      i = end;
      continue;
    }
    if (grammar.block && startsWithAt('/*', i)) {
      var end = text.indexOf('*/', i + 2);
      end = end < 0 ? n : end + 2;
      runs.add((start: i, end: end, token: SyntaxToken.comment));
      i = end;
      continue;
    }

    // Strings: a quote runs to its twin, honouring backslash escapes, and
    // stops at a newline unless it's a backtick template.
    final ch = text[i];
    if (grammar.quotes.contains(ch)) {
      var j = i + 1;
      while (j < n) {
        final cj = text[j];
        if (cj == '\\') {
          j += 2;
          continue;
        }
        if (cj == ch) {
          j++;
          break;
        }
        if (cj == '\n' && ch != '`') break;
        j++;
      }
      if (j > n) j = n;
      runs.add((start: i, end: j, token: SyntaxToken.string));
      i = j;
      continue;
    }

    // Numbers (not the tail of an identifier).
    if (_isDigit(c)) {
      var j = i + 1;
      while (j < n) {
        final cj = text.codeUnitAt(j);
        if (_isDigit(cj) || cj == 0x2E || cj == 0x5F || _isIdentStart(cj)) {
          j++;
        } else {
          break;
        }
      }
      runs.add((start: i, end: j, token: SyntaxToken.number));
      i = j;
      continue;
    }

    // Identifiers: keyword, literal, or a capitalised type name.
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < n && _isIdentPart(text.codeUnitAt(j))) {
        j++;
      }
      final word = text.substring(i, j);
      final lookup = grammar.caseInsensitive ? word.toLowerCase() : word;
      SyntaxToken? token;
      if (grammar.keywords.contains(lookup)) {
        token = SyntaxToken.keyword;
      } else if (grammar.literals.contains(word) ||
          (grammar.caseInsensitive && grammar.literals.contains(lookup))) {
        token = SyntaxToken.literal;
      } else if (grammar.types &&
          c >= 0x41 &&
          c <= 0x5A &&
          word.length > 1 &&
          word != word.toUpperCase()) {
        token = SyntaxToken.type;
      }
      if (token != null) runs.add((start: i, end: j, token: token));
      i = j;
      continue;
    }
    i++;
  }
  return runs;
}
