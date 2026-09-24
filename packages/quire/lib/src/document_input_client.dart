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
/// `text_span_builder.dart`'s `kEmptyNodeSentinel` (the *rendered*
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
    _pushGeometry();
  }

  void detach() {
    _connection?.close();
    _connection = null;
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
  void syncFromModel() {
    if (_applyingDeltas || _connection == null) return;
    final expected = _expectedValue();
    // Text AND selection both unchanged: never send anything, or an active
    // composing region gets clobbered for no reason (e.g. a rebuild from an
    // unrelated `notifyListeners` while mid-composition).
    if (expected.text == _remoteValue.text && expected.selection == _remoteValue.selection) {
      return;
    }
    _remoteValue = expected;
    _connection!.setEditingState(expected);
    host.onEditingStatePushed();
    _pushGeometry();
  }

  /// The IME's current composing range for [nodeId], in that node's own
  /// model coordinates — `null` unless [nodeId] is the single node
  /// [_remoteValue] currently targets and its composing range is real.
  TextRange? composingRangeFor(String nodeId) {
    if (_crossNodeMode || _targetNodeId != nodeId) return null;
    final composing = _remoteValue.composing;
    if (!composing.isValid || composing.isCollapsed) return null;
    return TextRange(
      start: (composing.start - _imeSentinel.length).clamp(0, 1 << 30),
      end: (composing.end - _imeSentinel.length).clamp(0, 1 << 30),
    );
  }

  // --- Building the IME's virtual text from the model ---------------------

  TextEditingValue _expectedValue() {
    final selection = host.controller.composer.selection;
    final document = host.controller.document;
    if (selection == null) {
      _crossNodeMode = false;
      _targetNodeId = null;
      return const TextEditingValue(text: _imeSentinel, selection: TextSelection.collapsed(offset: 1));
    }
    if (selection.base.nodeId == selection.extent.nodeId) {
      final node = document.getNodeById(selection.base.nodeId);
      final basePos = selection.base.nodePosition;
      final extentPos = selection.extent.nodePosition;
      if (node is TextNode && basePos is TextNodePosition && extentPos is TextNodePosition) {
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
      return const TextEditingValue(text: _imeSentinel, selection: TextSelection.collapsed(offset: 1));
    }
    // Cross-node selection: no single node's text to show — stand in with a
    // fully-selected placeholder (see `_crossNodePlaceholder`).
    _crossNodeMode = true;
    _targetNodeId = null;
    return const TextEditingValue(
      text: _crossNodePlaceholder,
      selection: TextSelection(baseOffset: _imeSentinel.length, extentOffset: _crossNodePlaceholder.length),
    );
  }

  void _pushGeometry() {
    final connection = _connection;
    if (connection == null) return;
    final selection = host.controller.composer.selection;
    final nodeId = selection?.extent.nodeId;
    if (nodeId == null) return;
    final geometry = host.editableGeometry(nodeId);
    if (geometry != null) {
      connection.setEditableSizeAndTransform(geometry.size, geometry.transform);
    }
    if (selection != null) {
      final caretRect = host.caretGlobalRect(selection.extent);
      if (caretRect != null) {
        final local = geometry == null
            ? caretRect
            : Rect.fromLTWH(0, 0, caretRect.width, caretRect.height);
        connection
          ..setCaretRect(local)
          ..setComposingRect(local);
      }
    }
  }

  // --- DeltaTextInputClient -------------------------------------------

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    _applyingDeltas = true;
    try {
      for (final delta in textEditingDeltas) {
        _applyDelta(delta);
      }
    } finally {
      _applyingDeltas = false;
    }
    syncFromModel();
  }

  void _applyDelta(TextEditingDelta delta) {
    // Track the platform's own value first (mirrors what a non-delta
    // `updateEditingValue` would leave `TextEditingController` holding) —
    // every branch below reasons from this, not from a value recomputed off
    // the model, since the model hasn't caught up with this delta yet.
    final previous = _remoteValue;
    _remoteValue = delta.apply(_remoteValue);

    if (delta is TextEditingDeltaNonTextUpdate) {
      _applySelectionOnly(delta.selection);
      return;
    }
    if (delta is TextEditingDeltaDeletion) {
      _applyDeletion(previous, delta.deletedRange);
      return;
    }
    if (delta is TextEditingDeltaInsertion) {
      _applyReplacement(
        previous,
        TextRange.collapsed(delta.insertionOffset),
        delta.textInserted,
      );
      return;
    }
    if (delta is TextEditingDeltaReplacement) {
      _applyReplacement(previous, delta.replacedRange, delta.replacementText);
      return;
    }
  }

  /// A selection/composing-only report — a caret drag, or the platform
  /// repositioning within its own composing region. Ignored in cross-node
  /// mode: this field's own text is only a placeholder there, so a
  /// selection report against it carries no real information about the
  /// document-wide selection (see `_expectedValue`'s cross-node branch).
  void _applySelectionOnly(TextSelection selection) {
    if (_crossNodeMode) return;
    final nodeId = _targetNodeId;
    if (nodeId == null) return;
    final node = host.controller.document.getNodeById(nodeId);
    if (node is! TextNode) return;
    final modelLength = node.text.text.length;
    // A selection ending at offset 0 sits ON the sentinel — clamp to model 0
    // rather than treating it as "before the document".
    int toModel(int fieldOffset) =>
        _snapToGraphemeBoundary(
          node.text.text,
          (fieldOffset - _imeSentinel.length).clamp(0, modelLength),
        );
    host.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(nodeId, TextNodePosition(toModel(selection.baseOffset))),
        extent: DocumentPosition(nodeId, TextNodePosition(toModel(selection.extentOffset))),
      ),
    );
  }

  void _applyDeletion(TextEditingValue before, TextRange deletedRange) {
    if (_crossNodeMode) {
      host.controller.deleteSelection();
      return;
    }
    final nodeId = _targetNodeId;
    if (nodeId == null) return;
    final node = host.controller.document.getNodeById(nodeId);
    if (node is! TextNode) return;

    // The deletion includes the sentinel and removes nothing else — the
    // only thing a soft keyboard can express for "backspace at the very
    // start of this paragraph".
    if (deletedRange.start == 0 && deletedRange.end == _imeSentinel.length) {
      host.controller.mergeWithPrevious(nodeId);
      return;
    }

    var start = (deletedRange.start - _imeSentinel.length).clamp(0, node.text.text.length);
    var end = (deletedRange.end - _imeSentinel.length).clamp(0, node.text.text.length);
    // iOS's own soft-keyboard delete isn't reliably grapheme-aware for a
    // custom TextInputClient — widen a pure deletion to the enclosing
    // grapheme cluster(s) so a picked emoji's surrogate pair (or a longer
    // ZWJ sequence) goes as one character, not half of one.
    final (expandedStart, expandedEnd) = _expandToGraphemeClusters(node.text.text, start, end);
    start = expandedStart;
    end = expandedEnd;
    if (end <= start) return;
    host.controller.replaceText(nodeId: nodeId, start: start, end: end, insertedText: '');
  }

  void _applyReplacement(TextEditingValue before, TextRange range, String text) {
    if (_crossNodeMode) {
      host.controller.replaceSelectionWithText(text);
      return;
    }
    final nodeId = _targetNodeId;
    if (nodeId == null) return;
    final node = host.controller.document.getNodeById(nodeId);
    if (node is! TextNode) return;
    final modelLength = node.text.text.length;
    final start = (range.start - _imeSentinel.length).clamp(0, modelLength);
    final end = (range.end - _imeSentinel.length).clamp(0, modelLength);

    if (!text.contains('\n')) {
      host.controller.replaceText(nodeId: nodeId, start: start, end: end, insertedText: text);
      return;
    }
    // A soft keyboard's Return key sends no key event — with
    // TextInputAction.newline it lands here as a literal "\n" in a delta.
    // Split it into insertNewline() calls so it splits the node the same
    // way a physical Enter does, instead of leaving a raw newline inside
    // one node's text.
    final segments = text.split('\n');
    host.controller.replaceText(
      nodeId: nodeId,
      start: start,
      end: end,
      insertedText: segments.first,
    );
    for (var i = 1; i < segments.length; i++) {
      host.insertNewline();
      final currentNodeId = host.controller.focusedNodeId;
      if (currentNodeId != null && segments[i].isNotEmpty) {
        host.controller.replaceText(
          nodeId: currentNodeId,
          start: 0,
          end: 0,
          insertedText: segments[i],
        );
      }
    }
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

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) host.insertNewline();
  }

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
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

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
