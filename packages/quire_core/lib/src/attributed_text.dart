/// A named style/marker attached to a text range (e.g. bold, a link).
///
/// `value` carries JSON-safe data (e.g. `{'url': '...'}` for a link); it is
/// empty for boolean flags like bold/italic. Two attributions "conflict"
/// (cannot coexist on overlapping text) when their [name] matches, regardless
/// of [value] — applying `link(a)` over `link(b)` replaces it.
class Attribution {
  const Attribution(this.name, {this.value = const {}});

  final String name;
  final Map<String, Object?> value;

  bool conflictsWith(Attribution other) => name == other.name;

  @override
  bool operator ==(Object other) =>
      other is Attribution &&
      other.name == name &&
      _mapEquals(other.value, value);

  @override
  int get hashCode => Object.hash(
    name,
    Object.hashAllUnordered(
      value.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  Map<String, Object?> toJson() => {'name': name, 'value': value};

  factory Attribution.fromJson(Map<String, Object?> json) => Attribution(
    json['name'] as String,
    value: Map<String, Object?>.from(
      json['value'] as Map<String, Object?>? ?? const {},
    ),
  );

  @override
  String toString() => 'Attribution($name, $value)';
}

bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// A single attribution applied to `[start, end)` of some text.
class AttributionSpan {
  const AttributionSpan(this.attribution, this.start, this.end);

  final Attribution attribution;
  final int start;
  final int end;

  AttributionSpan copyWith({int? start, int? end}) =>
      AttributionSpan(attribution, start ?? this.start, end ?? this.end);

  Map<String, Object?> toJson() => {
    'attribution': attribution.toJson(),
    'start': start,
    'end': end,
  };

  factory AttributionSpan.fromJson(Map<String, Object?> json) =>
      AttributionSpan(
        Attribution.fromJson(json['attribution'] as Map<String, Object?>),
        json['start'] as int,
        json['end'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is AttributionSpan &&
      other.attribution == attribution &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(attribution, start, end);

  @override
  String toString() => 'AttributionSpan($attribution, $start, $end)';
}

/// Immutable plain text plus a normalized set of attribution spans.
class AttributedText {
  AttributedText(this.text, [List<AttributionSpan> spans = const []])
    : spans = _normalize(spans) {
    assert(_checkInvariant(this.spans), 'spans must be normalized');
  }

  final String text;
  final List<AttributionSpan> spans;

  /// Sorts by (name, start), merges adjacent/overlapping spans with equal
  /// attribution, drops empty spans.
  static List<AttributionSpan> _normalize(List<AttributionSpan> input) {
    final nonEmpty = input.where((s) => s.end > s.start).toList()
      ..sort((a, b) {
        final byName = a.attribution.name.compareTo(b.attribution.name);
        if (byName != 0) return byName;
        return a.start.compareTo(b.start);
      });

    final merged = <AttributionSpan>[];
    for (final span in nonEmpty) {
      if (merged.isNotEmpty &&
          merged.last.attribution == span.attribution &&
          span.start <= merged.last.end) {
        final last = merged.removeLast();
        merged.add(
          last.copyWith(end: span.end > last.end ? span.end : last.end),
        );
      } else {
        merged.add(span);
      }
    }
    return merged;
  }

  static bool _checkInvariant(List<AttributionSpan> spans) {
    for (var i = 1; i < spans.length; i++) {
      final prev = spans[i - 1];
      final cur = spans[i];
      if (prev.attribution == cur.attribution && cur.start <= prev.end) {
        return false;
      }
    }
    return true;
  }

  AttributedText insert(
    int offset,
    String inserted, {
    Set<Attribution> attributions = const {},
  }) {
    final newText = text.replaceRange(offset, offset, inserted);
    final len = inserted.length;
    final newSpans = <AttributionSpan>[];
    for (final span in spans) {
      if (offset <= span.start) {
        newSpans.add(
          span.copyWith(start: span.start + len, end: span.end + len),
        );
      } else if (offset >= span.end) {
        // Ends exactly at or before offset: does not extend over insertion.
        newSpans.add(span);
      } else {
        // Straddles the offset: extends over inserted text.
        newSpans.add(span.copyWith(end: span.end + len));
      }
    }
    for (final a in attributions) {
      newSpans.add(AttributionSpan(a, offset, offset + len));
    }
    return AttributedText(newText, newSpans);
  }

  AttributedText remove(int start, int end) {
    final newText = text.replaceRange(start, end, '');
    final removedLen = end - start;
    final newSpans = <AttributionSpan>[];
    for (final span in spans) {
      int s;
      int e;
      if (span.start >= end) {
        // entirely after removed range: shift left
        s = span.start - removedLen;
        e = span.end - removedLen;
      } else if (span.end <= start) {
        // entirely before removed range: unaffected
        s = span.start;
        e = span.end;
      } else {
        // Overlaps removed range: the part before `start` and the part
        // after `end` survive, joined together at `start`.
        final before = span.start < start ? start - span.start : 0;
        final after = span.end > end ? span.end - end : 0;
        s = span.start < start ? span.start : start;
        e = s + before + after;
      }
      newSpans.add(span.copyWith(start: s, end: e));
    }
    return AttributedText(newText, newSpans);
  }

  AttributedText copyRange(int start, int end) {
    final newText = text.substring(start, end);
    final newSpans = <AttributionSpan>[];
    for (final span in spans) {
      final s = span.start > start ? span.start : start;
      final e = span.end < end ? span.end : end;
      if (e > s) {
        newSpans.add(span.copyWith(start: s - start, end: e - start));
      }
    }
    return AttributedText(newText, newSpans);
  }

  /// Adds [a] over `[start, end)`. Any existing attribution with the same
  /// [Attribution.name] in that range is replaced first (see
  /// [Attribution.conflictsWith]) — e.g. `link(a)` over `link(b)` replaces it.
  AttributedText addAttribution(Attribution a, int start, int end) {
    if (end <= start) return this;
    final withoutConflicts = <AttributionSpan>[];
    for (final span in spans) {
      if (!span.attribution.conflictsWith(a) ||
          span.end <= start ||
          span.start >= end) {
        withoutConflicts.add(span);
        continue;
      }
      if (span.start < start) withoutConflicts.add(span.copyWith(end: start));
      if (span.end > end) withoutConflicts.add(span.copyWith(start: end));
    }
    return AttributedText(text, [
      ...withoutConflicts,
      AttributionSpan(a, start, end),
    ]);
  }

  AttributedText removeAttribution(Attribution a, int start, int end) {
    if (end <= start) return this;
    final newSpans = <AttributionSpan>[];
    for (final span in spans) {
      if (span.attribution != a || span.end <= start || span.start >= end) {
        newSpans.add(span);
        continue;
      }
      if (span.start < start) {
        newSpans.add(span.copyWith(end: start));
      }
      if (span.end > end) {
        newSpans.add(span.copyWith(start: end));
      }
    }
    return AttributedText(text, newSpans);
  }

  AttributedText toggleAttribution(Attribution a, int start, int end) {
    if (hasAttributionThroughout(a, start, end)) {
      return removeAttribution(a, start, end);
    }
    return addAttribution(a, start, end);
  }

  Set<Attribution> attributionsAt(int offset) {
    return spans
        .where((s) => offset >= s.start && offset < s.end)
        .map((s) => s.attribution)
        .toSet();
  }

  bool hasAttributionThroughout(Attribution a, int start, int end) {
    if (end <= start) return false;
    var covered = start;
    final matching = spans.where((s) => s.attribution == a).toList()
      ..sort((x, y) => x.start.compareTo(y.start));
    for (final span in matching) {
      if (span.start > covered) break;
      if (span.end > covered) covered = span.end;
      if (covered >= end) return true;
    }
    return covered >= end;
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'spans': spans.map((s) => s.toJson()).toList(),
  };

  factory AttributedText.fromJson(Map<String, Object?> json) => AttributedText(
    json['text'] as String,
    (json['spans'] as List)
        .map((s) => AttributionSpan.fromJson(s as Map<String, Object?>))
        .toList(),
  );

  @override
  bool operator ==(Object other) =>
      other is AttributedText &&
      other.text == text &&
      _listEquals(other.spans, spans);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(spans));

  @override
  String toString() => 'AttributedText("$text", $spans)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
