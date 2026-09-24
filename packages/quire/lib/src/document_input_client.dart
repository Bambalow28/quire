import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quire_core/quire_core.dart';

import 'quire_editor_controller.dart';

/// What [DocumentInputClient] needs from `_QuireEditorState` to do its job,
/// kept as a narrow interface rather than a raw reference to the state class
/// so the input-handling code doesn't reach back into private editor
/// internals it doesn't need.
abstract class DocumentInputHost {
  QuireEditorController get controller;

  /// Whether the editor's own single `FocusNode` currently has focus — the
  /// IME connection only exists while this is true.
  bool get hasFocus;

  Brightness get keyboardAppearance;

  /// Called after the client pushes a new editing state to the platform (or
  /// adopts a merged one) — the caret may have moved, so the editor should
  /// reset its blink and keep the caret on screen.
  void onEditingStatePushed();

  /// The on-screen rect (global coordinates) of the caret at [position], or
  /// `null` if that node isn't laid out right now.
  Rect? caretGlobalRect(DocumentPosition position);

  /// The focused node's own render size and its transform to the global
  /// coordinate space — what `setEditableSizeAndTransform` needs.
  ({Size size, Matrix4 transform})? editableGeometry(String nodeId);

  void insertNewline();

  void requestKeepCaretVisible();

  /// The document position under [globalOffset] — used by
  /// `updateFloatingCursor` to place the caret under the trackpad-style
  /// floating cursor gesture (iOS space-bar cursor drag).
  DocumentPosition? resolveGlobalOffset(Offset globalOffset);

  /// Opens quire's own selection toolbar (Select/Select all/Cut/Copy/Paste)
  /// at the current selection — the IME's `showToolbar()` request routes
  /// here since there is no `EditableText` of its own to ask any more.
  void showContextMenu();
}

/// The one soft-keyboard-visible character every IME editing value carries,
/// so backspace-at-start-of-an-empty-node is observable — a soft keyboard
/// sends no deletion delta at all when there's nothing left to delete. It is
/// a real space, not a zero-width one, on purpose: iOS/Android apply their
/// `TextCapitalization.sentences` auto-shift by looking at the characters
/// before the caret, and a zero-width space reads to them as a word
/// character, which kills shift-on at the start of a paragraph. A leading
/// space still reads as "start of sentence".
///
/// This is a platform/IME-facing concept, separate from
/// `text_span_builder.dart`'s private render placeholder (the
/// placeholder for a genuinely empty node) — the two never appear together;
/// this one exists only inside the value the keyboard sees, never on screen.
const _imeSentinel = ' ';

/// What the IME sees while the document selection spans more than one node:
/// the sentinel plus one placeholder character, fully selected. There is no
/// single node's text to show, so this stands in for "something is
/// selected" — any insert/replace over it edits the real (multi-node)
/// selection instead (see `_applyCrossNode`).
const _crossNodePlaceholder = '$_imeSentinel​';

/// Owns the editor's single `TextInputConnection` and translates between the
/// platform's delta-based editing value and [QuireEditorController]'s
/// document/selection model. The model is the only source of truth — this
/// class never holds document state of its own beyond what it needs to
/// track the platform's last-known value.
class DocumentInputClient implements DeltaTextInputClient {
  DocumentInputClient({required this.host});

  final DocumentInputHost host;

  TextInputConnection? _connection;

  /// The last editing value this client either sent to the platform or
  /// derived from a delta the platform sent back — i.e. what the platform
  /// itself currently believes the field contains. Every delta is applied
  /// against this, in order (never against a value recomputed from the
  /// model mid-batch — see `updateEditingValueWithDeltas`).
  TextEditingValue _remoteValue = const TextEditingValue(
    text: _imeSentinel,
    selection: TextSelection.collapsed(offset: 1),
  );

  /// The node id [_remoteValue] currently reflects, or `null` in cross-node
  /// mode or when nothing text-shaped is selected.
  String? _targetNodeId;
  bool _crossNodeMode = false;

  /// Set for the whole span of one `updateEditingValueWithDeltas` call, so
  /// the model mutations each delta triggers (`replaceText`, etc. —
  /// synchronous, via `ChangeNotifier`) don't re-enter [syncFromModel] and
  /// push a half-applied state back to the platform mid-batch. The batch is
  /// resynced once, after every delta in it has been applied.
  bool _applyingDeltas = false;

  bool get isAttached => _connection != null;

  void attach() {
    if (_connection != null) return;
    _remoteValue = _expectedValue();
    _resetLines();
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        textCapitalization: TextCapitalization.sentences,
        autocorrect: false,
        enableSuggestions: false,
        enableDeltaModel: true,
        keyboardAppearance: host.keyboardAppearance,
      ),
    );
    _connection!
      ..setEditingState(_remoteValue)
      ..show();
    pushGeometry();
  }

  void detach() {
    _connection?.close();
    _connection = null;
    _sentSize = null;
    _sentTransform = null;
    _sentCaretRect = null;
    _targetNodeId = null;
    _crossNodeMode = false;
  }

  void dispose() => detach();

  /// Recomputes the IME value the model implies and, if it actually differs
  /// from what the platform last reported, pushes it — this is how merges,
  /// splits, autoformat, undo, toolbar actions and a tap that moves the
  /// caret to another node all reach the keyboard, since none of them go
  /// through a delta. A no-op while a delta batch is still being applied
  /// (see [_applyingDeltas]) and while there's no open connection.
  ///
  /// Coalesced to one push per microtask: a compound edit (auto-link's
  /// select-token → link → restore-caret, a transaction of several requests)
  /// notifies once per step, and every intermediate selection pushed to the
  /// keyboard can reset its shift/autocorrect state. Platform deltas arrive
  /// as separate event-loop tasks, so the pending push always lands before
  /// the next one is applied.
  void syncFromModel() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      _syncNow();
    });
  }

  bool _syncScheduled = false;

  void _syncNow() {
    if (_applyingDeltas || _connection == null) return;
    // The platform's text can span several nodes after Return (see
    // [_lines]). While it still matches the model exactly, keep it: pushing
    // a fresh single-node value after every Return raced keystrokes the
    // platform had already applied against the old one (fast/hardware
    // typing put characters on the wrong line). Only the selection may
    // need correcting.
    final kept = _selectionWithinLines();
    if (kept != null) {
      if (kept == _remoteValue.selection) return;
      _push(_remoteValue.copyWith(selection: kept, composing: TextRange.empty));
      return;
    }
    final expected = _expectedValue();
    _resetLines();
    // Text AND selection both unchanged: never send anything, or an active
    // composing region gets clobbered for no reason (e.g. a rebuild from an
    // unrelated `notifyListeners` while mid-composition).
    if (expected.text == _remoteValue.text &&
        expected.selection == _remoteValue.selection) {
      return;
    }
    _push(expected);
  }

  void _push(TextEditingValue value) {
    _remoteValue = value;
    _connection!.setEditingState(value);
    host.onEditingStatePushed();
    pushGeometry();
  }

  /// The platform selection for the model's selection, if the platform's
  /// multi-line text ([_lines]) still mirrors the model exactly — `null`
  /// when it has diverged (an undo, a merge, a markdown shortcut stripping
  /// its prefix, a tap into a node outside it) and a fresh value must be
  /// pushed instead.
  TextSelection? _selectionWithinLines() {
    if (_crossNodeMode || _lines.isEmpty) return null;
    if (_lines.first.start != _imeSentinel.length) return null;
    final document = host.controller.document;
    final text = StringBuffer(_imeSentinel);
    for (final (i, line) in _lines.indexed) {
      final node = document.getNodeById(line.nodeId);
      if (node is! TextNode || line.base != 0) return null;
      if (i > 0) text.write('\n');
      if (text.length != line.start) return null;
      text.write(node.text.text);
    }
    if (text.toString() != _remoteValue.text) return null;
    final selection = host.controller.composer.selection;
    if (selection == null) return null;
    final base = _platformOffset(selection.base);
    final extent = _platformOffset(selection.extent);
    if (base == null || extent == null) return null;
    return TextSelection(baseOffset: base, extentOffset: extent);
  }

  int? _platformOffset(DocumentPosition position) {
    final offset = position.nodePosition;
    if (offset is! TextNodePosition) return null;
    for (final line in _lines) {
      if (line.nodeId == position.nodeId) {
        return line.start + offset.offset - line.base;
      }
    }
    return null;
  }

  /// The IME's current composing range for [nodeId], in that node's own
  /// model coordinates — `null` unless [nodeId] is the single node
  /// [_remoteValue] currently targets and its composing range is real.
  TextRange? composingRangeFor(String nodeId) {
    final composing = _remoteValue.composing;
    if (_crossNodeMode || !composing.isValid || composing.isCollapsed) {
      return null;
    }
    final node = host.controller.document.getNodeById(nodeId);
    if (node is! TextNode) return null;
    for (final line in _lines) {
      if (line.nodeId != nodeId) continue;
      final start = line.base + composing.start - line.start;
      final end = line.base + composing.end - line.start;
      if (start < 0 || end > node.text.text.length) return null;
      return TextRange(start: start, end: end);
    }
    return null;
  }

  // --- Building the IME's virtual text from the model ---------------------

  TextEditingValue _expectedValue() {
    final selection = host.controller.composer.selection;
    final document = host.controller.document;
    if (selection == null) {
      _crossNodeMode = false;
      _targetNodeId = null;
      return const TextEditingValue(
        text: _imeSentinel,
        selection: TextSelection.collapsed(offset: 1),
      );
    }
    if (selection.base.nodeId == selection.extent.nodeId) {
      final node = document.getNodeById(selection.base.nodeId);
      final basePos = selection.base.nodePosition;
      final extentPos = selection.extent.nodePosition;
      if (node is TextNode &&
          basePos is TextNodePosition &&
          extentPos is TextNodePosition) {
        final sameTarget = !_crossNodeMode && _targetNodeId == node.id;
        _crossNodeMode = false;
        _targetNodeId = node.id;
        final text = _imeSentinel + node.text.text;
        // Composing survives only while it's still the same node with the
        // same text — a real model edit invalidates whatever range the
        // platform was composing against.
        final composing = sameTarget && text == _remoteValue.text
            ? _remoteValue.composing
            : TextRange.empty;
        return TextEditingValue(
          text: text,
          selection: TextSelection(
            baseOffset: basePos.offset + _imeSentinel.length,
            extentOffset: extentPos.offset + _imeSentinel.length,
          ),
          composing: composing,
        );
      }
      // Non-text selection (an image/table/rule node, say).
      _crossNodeMode = false;
      _targetNodeId = null;
      return const TextEditingValue(
        text: _imeSentinel,
        selection: TextSelection.collapsed(offset: 1),
      );
    }
    // Cross-node selection: no single node's text to show — stand in with a
    // fully-selected placeholder (see `_crossNodePlaceholder`).
    _crossNodeMode = true;
    _targetNodeId = null;
    return const TextEditingValue(
      text: _crossNodePlaceholder,
      selection: TextSelection(
        baseOffset: _imeSentinel.length,
        extentOffset: _crossNodePlaceholder.length,
      ),
    );
  }

  Size? _sentSize;
  Matrix4? _sentTransform;
  Rect? _sentCaretRect;

  /// Tells the platform where the focused node and its caret are on screen,
  /// so iOS/Android can place the marked-text (CJK) candidate UI and the
  /// autocorrect bubble. The editor calls this after every frame while
  /// focused (layout, scrolling and keyboard insets all move things); only
  /// values that actually changed are sent.
  void pushGeometry() {
    final connection = _connection;
    if (connection == null) return;
    final selection = host.controller.composer.selection;
    if (selection == null) return;
    final geometry = host.editableGeometry(selection.extent.nodeId);
    if (geometry == null) return;
    if (geometry.size != _sentSize || geometry.transform != _sentTransform) {
      _sentSize = geometry.size;
      _sentTransform = geometry.transform;
      connection.setEditableSizeAndTransform(geometry.size, geometry.transform);
    }
    final caretGlobal = host.caretGlobalRect(selection.extent);
    final inverse = Matrix4.tryInvert(geometry.transform);
    if (caretGlobal == null || inverse == null) return;
    // setCaretRect/setComposingRect take the editable's own local
    // coordinates, i.e. relative to the transform sent above.
    final caretLocal = MatrixUtils.transformRect(inverse, caretGlobal);
    if (caretLocal == _sentCaretRect) return;
    _sentCaretRect = caretLocal;
    connection
      ..setCaretRect(caretLocal)
      ..setComposingRect(caretLocal);
  }

  // --- DeltaTextInputClient -------------------------------------------

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    _applyingDeltas = true;
    if (_lines.isEmpty) _resetLines();
    try {
      for (final delta in textEditingDeltas) {
        _applyDelta(delta);
      }
    } finally {
      _applyingDeltas = false;
      if (_staleBatch) {
        // The platform diverged from what this client tracked; forget the
        // line mapping so the sync below pushes a fresh, authoritative value.
        _staleBatch = false;
        _lines = const [];
      }
    }
    syncFromModel();
  }

  /// How the platform's text maps onto nodes while a delta batch is being
  /// applied. Normally that's one line: the target node, starting right
  /// after the sentinel. But one batch can carry several keystrokes,
  /// Return included (a hardware keyboard, or fast typing, easily fills
  /// one): once a "\n" has split the node, the rest of the batch addresses
  /// the platform's text *after* that newline, which is a different node
  /// now. Each line: where it starts in the platform text, its node, and
  /// the model offset that start corresponds to.
  List<({int start, String nodeId, int base})> _lines = const [];

  void _resetLines() {
    final id = _targetNodeId;
    _lines = id == null || _crossNodeMode
        ? const []
        : [(start: _imeSentinel.length, nodeId: id, base: 0)];
  }

  /// The model position the platform offset [offset] refers to.
  DocumentPosition _locate(int offset) {
    var line = _lines.first;
    for (final l in _lines) {
      if (l.start <= offset) line = l;
    }
    final node = host.controller.document.getNodeById(line.nodeId);
    final length = node is TextNode ? node.text.text.length : 0;
    final modelOffset = (line.base + offset - line.start).clamp(0, length);
    return DocumentPosition(line.nodeId, TextNodePosition(modelOffset));
  }

  /// Re-derives [_lines] from the platform's text after an edit that may
  /// have split or joined nodes: the first line keeps its node, and each
  /// following line is the next text node in document order — the model
  /// was just edited to mirror exactly those newlines.
  void _rebuildLines() {
    final first = _lines.first;
    final text = _remoteValue.text;
    final lines = [first];
    final following = host.controller.document.nodesInDocumentOrder
        .whereType<TextNode>()
        .skipWhile((n) => n.id != first.nodeId)
        .skip(1)
        .iterator;
    for (var i = text.indexOf('\n', first.start); i != -1;) {
      if (!following.moveNext()) break;
      lines.add((start: i + 1, nodeId: following.current.id, base: 0));
      i = text.indexOf('\n', i + 1);
    }
    _lines = lines;
  }

  void _applyDelta(TextEditingDelta delta) {
    // Track the platform's own value first — every branch below reasons
    // from what the platform believes, not from a value recomputed off the
    // model, since the model hasn't caught up with this delta yet.
    final previous = _remoteValue;
    if (_staleBatch || delta.oldText != previous.text) {
      _applyStale(delta);
      return;
    }
    _remoteValue = delta.apply(previous);

    final (TextRange range, String text) = switch (delta) {
      TextEditingDeltaInsertion() => (
        TextRange.collapsed(delta.insertionOffset),
        delta.textInserted,
      ),
      TextEditingDeltaDeletion() => (delta.deletedRange, ''),
      TextEditingDeltaReplacement() => (
        delta.replacedRange,
        delta.replacementText,
      ),
      _ => (TextRange.empty, ''),
    };

    if (_crossNodeMode) {
      // The platform only holds a placeholder standing in for the real,
      // multi-node selection: any edit over it edits that selection.
      if (delta is TextEditingDeltaNonTextUpdate) return;
      if (text.isEmpty) {
        host.controller.deleteSelection();
      } else {
        host.controller.replaceSelectionWithText(text);
      }
      // Whatever happens next in this batch is typed into the result; the
      // platform's placeholder is gone, so the sentinel line maps to the
      // caret's node from here on.
      final caret = host.controller.composer.selection?.extent;
      final caretOffset = caret?.nodePosition;
      if (caret != null && caretOffset is TextNodePosition) {
        _crossNodeMode = false;
        _lines = [
          (
            start: range.start + text.length,
            nodeId: caret.nodeId,
            base: caretOffset.offset,
          ),
        ];
      }
      return;
    }
    if (_lines.isEmpty) return;

    if (delta is TextEditingDeltaNonTextUpdate) {
      _applySelectionOnly(delta.selection);
      return;
    }

    // Backspace over the sentinel: the only thing a soft keyboard can
    // express for "backspace at the very start of this paragraph".
    if (text.isEmpty &&
        range.start == 0 &&
        range.end == _imeSentinel.length &&
        _lines.first.start == _imeSentinel.length) {
      _mergeFirstLineWithPrevious();
      return;
    }

    final start = _locate(range.start);
    final end = _locate(range.end);
    if (start.nodeId == end.nodeId && !text.contains('\n')) {
      final nodeId = start.nodeId;
      final node = host.controller.document.getNodeById(nodeId);
      if (node is! TextNode) return;
      var from = (start.nodePosition as TextNodePosition).offset;
      var to = (end.nodePosition as TextNodePosition).offset;
      if (text.isEmpty) {
        // iOS's own soft-keyboard delete isn't reliably grapheme-aware for
        // a custom TextInputClient — widen a pure deletion to the enclosing
        // grapheme cluster(s) so a picked emoji's surrogate pair (or a
        // longer ZWJ sequence) goes as one character, not half of one.
        (from, to) = _expandToGraphemeClusters(node.text.text, from, to);
        if (to <= from) return;
      }
      host.controller.replaceText(
        nodeId: nodeId,
        start: from,
        end: to,
        insertedText: text,
      );
      return;
    }

    // Inserting a "\n" (a soft keyboard's Return sends no key event — it
    // lands here as a literal newline), or deleting across one: express it
    // as a document selection and let the controller split/merge nodes
    // exactly as a physical Enter/Backspace would.
    host.controller.changeSelection(
      DocumentSelection(base: start, extent: end),
    );
    if (text.isEmpty) {
      host.controller.deleteSelection();
    } else {
      host.controller.replaceSelectionWithText(text, requestFocusAfter: false);
    }
    _rebuildLines();
  }

  bool _staleBatch = false;

  /// A delta built against a platform value this client no longer tracks —
  /// the platform applied it before our last [setEditingState] reached it
  /// (typing faster than a push round-trip). Its offsets can't be trusted,
  /// but its intent can: replay it at the model's caret, as the keystrokes
  /// they were. The rest of the batch follows the same path, and a fresh
  /// value is pushed once it's done.
  void _applyStale(TextEditingDelta delta) {
    _staleBatch = true;
    final (TextRange range, String text) = switch (delta) {
      TextEditingDeltaInsertion() => (
        TextRange.collapsed(delta.insertionOffset),
        delta.textInserted,
      ),
      TextEditingDeltaDeletion() => (delta.deletedRange, ''),
      TextEditingDeltaReplacement() => (
        delta.replacedRange,
        delta.replacementText,
      ),
      _ => (TextRange.empty, ''),
    };
    if (!range.isValid) return;
    final removed = delta.oldText.substring(range.start, range.end);
    for (var i = 0; i < removed.characters.length; i++) {
      host.controller.backspaceAtCaret();
    }
    if (text.isNotEmpty) {
      host.controller.replaceSelectionWithText(text, requestFocusAfter: false);
    }
  }

  void _mergeFirstLineWithPrevious() {
    final first = _lines.first;
    final document = host.controller.document;
    TextNode? previousNode;
    for (final n in document.nodesInDocumentOrder) {
      if (n.id == first.nodeId) break;
      if (n is TextNode) previousNode = n;
    }
    final previousLength = previousNode?.text.text.length ?? 0;
    host.controller.mergeWithPrevious(first.nodeId);
    // The platform's text lost its sentinel, so every line starts one
    // earlier; if the node really merged away, its line now continues the
    // node it merged into.
    final merged = document.getNodeById(first.nodeId) == null;
    _lines = [
      for (final (i, l) in _lines.indexed)
        i == 0 && merged && previousNode != null
            ? (start: 0, nodeId: previousNode.id, base: previousLength)
            : (start: l.start - 1, nodeId: l.nodeId, base: l.base),
    ];
  }

  /// A selection/composing-only report — a caret drag, or the platform
  /// repositioning within its own composing region.
  void _applySelectionOnly(TextSelection selection) {
    if (!selection.isValid) return;
    DocumentPosition snapped(int offset) {
      final position = _locate(offset);
      final node = host.controller.document.getNodeById(position.nodeId);
      if (node is! TextNode) return position;
      return DocumentPosition(
        position.nodeId,
        TextNodePosition(
          _snapToGraphemeBoundary(
            node.text.text,
            (position.nodePosition as TextNodePosition).offset,
          ),
        ),
      );
    }

    host.controller.changeSelection(
      DocumentSelection(
        base: snapped(selection.baseOffset),
        extent: snapped(selection.extentOffset),
      ),
    );
  }

  // --- TextInputClient ------------------------------------------------

  @override
  TextEditingValue get currentTextEditingValue => _remoteValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    // Never called: `enableDeltaModel: true` routes the platform through
    // `updateEditingValueWithDeltas` instead. Required by `TextInputClient`
    // regardless.
  }

  /// Deliberately ignores [TextInputAction.newline]: for a multiline input
  /// iOS reports the Return key BOTH as this action and as a literal "\n"
  /// insertion delta (which `_applyReplacement` already splits on), so
  /// acting on it here too would insert two paragraphs per Return — the
  /// same reason `EditableText` ignores it for multiline fields.
  @override
  void performAction(TextInputAction action) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  Offset? _floatingCursorStartCenter;

  /// iOS space-bar trackpad cursor: Start remembers the caret rect's centre;
  /// Update places the caret at that centre plus the gesture's own offset;
  /// End just leaves the caret wherever Update last put it.
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    final selection = host.controller.composer.selection;
    switch (point.state) {
      case FloatingCursorDragState.Start:
        _floatingCursorStartCenter = selection == null
            ? null
            : host.caretGlobalRect(selection.extent)?.center;
      case FloatingCursorDragState.Update:
        final start = _floatingCursorStartCenter;
        final offset = point.offset;
        if (start == null || offset == null) return;
        final resolved = host.resolveGlobalOffset(start + offset);
        if (resolved == null) return;
        host.controller.changeSelection(DocumentSelection.collapsed(resolved));
      case FloatingCursorDragState.End:
        _floatingCursorStartCenter = null;
    }
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  bool onFocusReceived() => false;

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void showToolbar() => host.showContextMenu();

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  /// macOS selector dispatch (e.g. from a trackpad/menu-driven edit
  /// command, or a hardware key macOS's own text-input system intercepts
  /// before it ever reaches `Focus.onKeyEvent`). `'deleteBackward:'` is
  /// deliberately left unmapped here even though it would be trivial: macOS
  /// hardware Backspace is *also* bound physically (see
  /// `quire_editor.dart`'s `_shortcutBindings`, `isDesktop` branch) for the
  /// platforms/configurations where it never reaches this selector path at
  /// all — mapping it in both places risks deleting twice for the same
  /// keystroke on whichever configuration delivers both, and there is no
  /// reliable signal here to tell them apart. `'insertNewline:'` has no such
  /// conflict (the physical Enter binding and this both do the same,
  /// idempotent-by-selection thing), so it's mapped.
  @override
  void performSelector(String selectorName) {
    switch (selectorName) {
      case 'insertNewline:':
        host.insertNewline();
      default:
      // No-op: not worth reimplementing the rest of NSStandardKeyBindingResponding here.
    }
  }
}

// --- Grapheme helpers -----------------------------------------------------

/// [offset] moved to the END of the grapheme cluster of [text] it falls
/// inside, or left alone if it's already on a cluster boundary. See
/// `quire_editor.dart`'s own copy (`_snapToGraphemeBoundary`) for the full
/// reasoning — kept in both files rather than shared, since each is a small,
/// self-contained pure function with no state to drift.
int _snapToGraphemeBoundary(String text, int offset) {
  if (offset <= 0 || offset >= text.length) return offset;
  var start = 0;
  for (final grapheme in text.characters) {
    final end = start + grapheme.length;
    if (offset > start && offset < end) return end;
    if (offset <= end) return offset;
    start = end;
  }
  return offset;
}

/// The tightest `[start, end)` range of [text]'s own grapheme clusters that
/// fully contains `[start, end)`.
(int, int) _expandToGraphemeClusters(String text, int start, int end) {
  var pos = 0;
  var expandedStart = start;
  var expandedEnd = end;
  for (final grapheme in text.characters) {
    final clusterEnd = pos + grapheme.length;
    if (pos < start && clusterEnd > start) expandedStart = pos;
    if (pos < end && clusterEnd > end) expandedEnd = clusterEnd;
    pos = clusterEnd;
  }
  return (expandedStart, expandedEnd);
}
