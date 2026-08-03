import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/services.dart';
import 'package:quire_core/quire_core.dart';

import 'node_text_controller.dart';
import 'quire_editor_controller.dart';
import 'table_grid.dart';
import 'table_settings_menu.dart';

// ponytail: one EditableText per node buys IME/handles/scribble for free.
// Cross-node selection is layered on top (editor-level drag + overlay
// painting) rather than replacing the fields with a single editor-level
// DeltaTextInputClient — that rewrite stays a separate, much larger project.

/// Paints the highlight for a selection that spans more than one node — a
/// field only paints its own (single-node) selection while focused, so the
/// editor paints the rest itself. [rects] are already in the editor's local
/// coordinate space. Pure paint logic, no document/render lookups, so it's
/// trivially testable in isolation.
class SelectionOverlayPainter extends CustomPainter {
  const SelectionOverlayPainter({required this.rects, required this.color});

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (rects.isEmpty) return;
    final paint = Paint()..color = color;
    for (final rect in rects) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SelectionOverlayPainter oldDelegate) =>
      oldDelegate.rects != rects || oldDelegate.color != color;
}

/// Renders [QuireEditorController.document] as one [EditableText] per
/// [TextNode] (plus image/rule widgets for the other node types).
class QuireEditor extends StatefulWidget {
  const QuireEditor({
    super.key,
    required this.controller,
    this.padding,
    this.placeholder,
    this.cursorColor,
  });

  final QuireEditorController controller;
  final EdgeInsetsGeometry? padding;

  /// Caret colour. Defaults to the theme's primary colour, which is an accent
  /// in most themes — pass the text colour where the caret should read as
  /// part of the content rather than as a highlight.
  final Color? cursorColor;

  /// Shown (in the host's muted theme color) when the document is a single
  /// empty text node and nothing is focused yet — e.g. "Start writing…".
  final String? placeholder;

  @override
  State<QuireEditor> createState() => _QuireEditorState();
}

// ponytail: soft-keyboard backspace sentinel. An iOS/Android soft keyboard
// sends no deletion delta (and no key event) when the field it's editing is
// already empty, so backspace-at-start-of-empty-paragraph is otherwise
// unreachable on touch. Fix: when a text node's model is empty, the field
// shows a single zero-width space (caret after it) instead of literally
// nothing, so a soft-keyboard backspace has something to delete and a real
// delta to observe. The sentinel is a field-level trick only — it is
// stripped before ever touching the model (`_stripSentinel`) and the model
// never sees or persists it. Real fix: an editor-level `DeltaTextInputClient`
// that sees the IME's actual delete requests instead of relying on text
// diffs (see the physical-key-binding comment below for the same tradeoff).
const _emptyNodeSentinel = '​';

class _QuireEditorState extends State<QuireEditor> {
  final Map<String, NodeTextController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, GlobalKey<EditableTextState>> _editableKeys = {};

  /// Text nodes paired with their controller, in document order, rebuilt by
  /// [_syncControllers]. Everything that walks the document per frame reads
  /// this instead of looking each controller up by node id.
  final List<(TextNode, NodeTextController)> _pairs = [];
  final GlobalKey _editorKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  bool _syncing = false;
  int _handledFocusRequest = -1;

  /// The node+offset the current editor-level drag started at, or `null`
  /// when no drag is in progress.
  DocumentPosition? _dragBase;

  /// Where a touch went down, and the timer that promotes it to a selection
  /// drag. On a touch screen a plain drag scrolls — only a long-press starts
  /// selecting, which is what every native text surface does. A precise
  /// pointer (mouse/trackpad/stylus) selects on drag immediately.
  Offset? _touchDownAt;
  Timer? _touchHoldTimer;

  /// Global hit-test rects for the two draggable selection handles (see
  /// [_buildSelectionHandles]), refreshed every build. `null` whenever no
  /// handle is showing. Checked by [_handlePointerDown] so a touch that
  /// starts on a handle is left entirely to that handle's own
  /// `GestureDetector` instead of also being picked up as a document-level
  /// tap/drag by the raw `Listener` — both currently see every pointer
  /// event, since `Listener` doesn't participate in the gesture arena.
  Rect? _startHandleHitRect;
  Rect? _endHandleHitRect;

  /// Whether the pointer currently down started on a handle — see the
  /// comment in [_handlePointerDown] for why [_handlePointerUp] needs this
  /// instead of just re-checking the up position.
  bool _pointerDownOnHandle = false;

  bool _isOnSelectionHandle(Offset globalPosition) =>
      (_startHandleHitRect?.contains(globalPosition) ?? false) ||
      (_endHandleHitRect?.contains(globalPosition) ?? false);

  bool get _hasMultiNodeSelection {
    final selection = widget.controller.composer.selection;
    return selection != null &&
        !selection.isCollapsed &&
        selection.base.nodeId != selection.extent.nodeId;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onModelChanged);
    // The overlay for a cross-node selection is painted with rects computed
    // fresh from each field's live (post-scroll) render position — but
    // nothing else here triggers a rebuild on scroll, so without this the
    // overlay would go stale under the moving content.
    // Only when a cross-node selection is actually on screen: otherwise this
    // would rebuild every field on every scroll frame for nothing.
    _scrollController.addListener(() {
      if (_hasMultiNodeSelection) setState(() {});
    });
    _syncAndPush();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onModelChanged);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    _touchHoldTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Runs before `setState` so no controller/model listener ever fires
  /// mid-build (that's how you get "setState called during build" from
  /// EditableText's own listener).
  void _onModelChanged() {
    _syncAndPush();
    setState(() {});
  }

  void _syncAndPush() {
    _syncControllers();
    _pushModelToControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeRequestFocus());
  }

  @override
  Widget build(BuildContext context) {
    final nodes = widget.controller.document.nodes;
    final padding = widget.padding ?? const EdgeInsets.all(16);
    // A CustomScrollView with a trailing SliverFillRemaining (rather than a
    // plain ListView) so the empty space below the last node is real,
    // tappable layout — not dead space the ListView never lays a hit-test
    // target over. This is this widget's equivalent of QuillEditor's
    // `expands: true`.
    final scrollView = CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildNode(context, nodes[index]),
              childCount: nodes.length,
            ),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focusLastNodeAtEnd,
          ),
        ),
      ],
    );

    // Document-level drag-to-select (defect 2): a raw Listener rather than a
    // GestureDetector pan recognizer, so it never has to fight the
    // CustomScrollView's own vertical-drag recognizer for the gesture arena
    // — it just observes the same pointer stream. Autoscroll while dragging
    // past the viewport edge is out of scope.
    final content = Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: (_) => _endDrag(),
      child: Stack(
        key: _editorKey,
        children: [
          scrollView,
          // Only a multi-node selection ever produces rects here — a
          // single-node selection is left entirely to that node's own field,
          // so this paints nothing and doesn't regress today's behaviour.
          IgnorePointer(
            child: CustomPaint(
              size: Size.infinite,
              painter: SelectionOverlayPainter(
                rects: _computeOverlayRects(),
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
          ),
          ..._buildSelectionHandles(context),
        ],
      ),
    );

    if (!_showPlaceholder) return content;
    return Stack(
      children: [
        Padding(
          padding: padding,
          child: IgnorePointer(
            child: Text(
              widget.placeholder!,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }

  bool get _showPlaceholder {
    final placeholder = widget.placeholder;
    if (placeholder == null || placeholder.isEmpty) return false;
    if (widget.controller.focusedNodeId != null) return false;
    final nodes = widget.controller.document.nodes;
    if (nodes.length != 1) return false;
    final only = nodes.first;
    return only is TextNode && only.text.text.isEmpty;
  }

  /// Tapping the empty tail below the last node focuses that node (if it's
  /// text) with the caret at its end — otherwise most of an almost-empty
  /// document would be dead to taps.
  void _focusLastNodeAtEnd() {
    TextNode? last;
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is TextNode) last = node;
    }
    if (last == null) return;
    widget.controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(last.id, TextNodePosition(last.text.text.length)),
      ),
    );
    widget.controller.requestFocus(last.id);
  }

  // --- Tap-to-caret / drag-to-select (document-level gesture layer) -------

  /// A field's [RenderEditable], but only once it is actually attached and
  /// laid out. Touching `size`/`localToGlobal`/`getPositionForPoint` before
  /// that is an assertion in debug and undefined behaviour in release, and
  /// this is reachable on the first frame and for a field the list hasn't
  /// laid out yet.
  RenderEditable? _laidOutEditable(String nodeId) {
    final renderEditable = _editableKeys[nodeId]?.currentState?.renderEditable;
    if (renderEditable == null) return null;
    if (!renderEditable.attached || !renderEditable.hasSize) return null;
    return renderEditable;
  }

  /// Tap **down** (not up) on a node's text, mapped through that field's own
  /// `RenderEditable` to a text offset, then applied through the model —
  /// this is the fix for defect 1: raw `EditableText` installs no tap
  /// recognizer of its own, so without this a tap never placed a caret.
  /// True when the tap that just went down landed on a caret that was
  /// already there, in a field that already had focus — that gesture means
  /// "show me the options", not "move the caret" (a plain text field has
  /// nowhere else to put a caret you tapped twice).
  bool _tapRepeatsCaret = false;
  Offset? _tapDownAt;

  /// The run of non-whitespace characters containing [offset] — a
  /// model-space word boundary that doesn't depend on the field's sentinel.
  (int, int) _wordBoundaryIn(String text, int offset) {
    if (text.isEmpty) return (0, 0);
    bool isWord(int i) => i >= 0 && i < text.length && !_isSpace(text[i]);
    var start = offset.clamp(0, text.length);
    var end = start;
    // If the caret sits just past a word (offset == word end), select that
    // word rather than nothing.
    if (!isWord(start) && isWord(start - 1)) start = end = start - 1;
    while (isWord(start - 1)) {
      start--;
    }
    while (isWord(end)) {
      end++;
    }
    return (start, end);
  }

  bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n';

  /// Selects the word under [offset] and opens the toolbar — what a
  /// double-tap or long-press does in any native text field, and the only
  /// way to get Cut/Copy, which need a non-empty selection.
  void _selectWordAt(String nodeId, int offset) {
    final state = _editableKeys[nodeId]?.currentState;
    final renderEditable = _laidOutEditable(nodeId);
    if (state == null || renderEditable == null) return;
    // Compute the word on the MODEL text, not via renderEditable
    // .getWordBoundary: the leading sentinel skews the platform word
    // segmenter (it treats "​hello" as starting a word one glyph over).
    final modelText = _controllers[nodeId]?.attributedText.text ?? '';
    final (wordStart, wordEnd) = _wordBoundaryIn(modelText, offset);
    if (wordEnd <= wordStart) return;
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(
        selection: TextSelection(
          baseOffset: _toField(wordStart),
          extentOffset: _toField(wordEnd),
        ),
      ),
      SelectionChangedCause.longPress,
    );
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(nodeId, TextNodePosition(wordStart)),
        extent: DocumentPosition(nodeId, TextNodePosition(wordEnd)),
      ),
    );
    widget.controller.requestFocus(nodeId);
    state.showToolbar();
  }

  /// Moves the caret through EditableText's own gesture path rather than by
  /// poking its controller: that is what builds the selection overlay
  /// (handles, magnifier, copy/paste toolbar). A direct controller write
  /// leaves the overlay null and showToolbar() silently does nothing.
  void _placeCaret(String nodeId, int offset) {
    final state = _editableKeys[nodeId]?.currentState;
    if (state != null) {
      state.userUpdateTextEditingValue(
        state.textEditingValue.copyWith(
          selection: TextSelection.collapsed(offset: _toField(offset)),
        ),
        SelectionChangedCause.tap,
      );
    }
    widget.controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(nodeId, TextNodePosition(offset)),
      ),
    );
  }

  bool _caretAlreadyAt(String nodeId, int offset) {
    final focusNode = _focusNodes[nodeId];
    if (focusNode == null || !focusNode.hasFocus) return false;
    final selection = widget.controller.composer.selection;
    if (selection == null || !selection.isCollapsed) return false;
    if (selection.extent.nodeId != nodeId) return false;
    final position = selection.extent.nodePosition;
    return position is TextNodePosition && position.offset == offset;
  }

  /// Resolves a global point to a document position by hit-testing every
  /// text node's live render rect, then mapping through that node's own
  /// `RenderEditable` — the same mapping [_handleFieldTapDown] uses for a
  /// single tap, reused here for both ends of a drag.
  DocumentPosition? _positionAt(Offset globalPosition) {
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final renderEditable = _laidOutEditable(node.id);
      if (renderEditable == null) continue;
      final rect =
          renderEditable.localToGlobal(Offset.zero) & renderEditable.size;
      if (!rect.contains(globalPosition)) continue;
      final fieldOffset = renderEditable
          .getPositionForPoint(globalPosition)
          .offset;
      // Clamp into the model's own length — an empty node's field carries
      // the sentinel (see `_emptyNodeSentinel`) and can report an offset the
      // (empty) model has no such position for.
      return DocumentPosition(
        node.id,
        TextNodePosition(_toModel(fieldOffset, node.text.text.length)),
      );
    }
    // Between two nodes (or past the last one): fall back to the vertically
    // nearest node, so a drag doesn't freeze whenever it crosses a gap.
    TextNode? nearest;
    var nearestDistance = double.infinity;
    var above = false;
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final renderEditable = _laidOutEditable(node.id);
      if (renderEditable == null) continue;
      final rect =
          renderEditable.localToGlobal(Offset.zero) & renderEditable.size;
      final distance = globalPosition.dy < rect.top
          ? rect.top - globalPosition.dy
          : globalPosition.dy > rect.bottom
          ? globalPosition.dy - rect.bottom
          : 0.0;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = node;
        above = globalPosition.dy < rect.top;
      }
    }
    if (nearest == null) return null;
    return DocumentPosition(
      nearest.id,
      TextNodePosition(above ? 0 : nearest.text.text.length),
    );
  }

  static const _touchHold = Duration(milliseconds: 500);
  static const _touchSlop = 12.0;

  void _handlePointerDown(PointerDownEvent event) {
    // A handle's own `GestureDetector` is a descendant of this `Listener`,
    // so this still fires for the same down/move/up events regardless of
    // what the handle does with them (Listener sees every event once it's
    // in a pointer's hit-test route, independent of the gesture arena) —
    // remembered here and re-checked in `_handlePointerUp` so a handle drag
    // doesn't ALSO get treated as a tap that collapses the caret.
    _pointerDownOnHandle = _isOnSelectionHandle(event.position);
    if (_pointerDownOnHandle) return;
    final position = _positionAt(event.position);
    if (position != null) {
      final offset = (position.nodePosition as TextNodePosition).offset;
      // The caret is placed on pointer *up*, not here: a tap must write the
      // selection exactly once, or the caret write races the word selection
      // a double-tap/long-press produces from the same gesture.
      _tapRepeatsCaret = _caretAlreadyAt(position.nodeId, offset);
      _tapDownAt = event.position;
      // On touch, focus is requested once the gesture is confirmed as a tap
      // (see `_handlePointerUp`/the long-press branch below) rather than
      // here — a scroll swipe that starts on text would otherwise pop the
      // keyboard for the instant before it's recognised as a scroll. A
      // precise pointer (mouse/trackpad/stylus) has no such ambiguity: a
      // drag starts a selection immediately, so it focuses right away.
      if (event.kind != PointerDeviceKind.touch) {
        widget.controller.requestFocus(position.nodeId);
      }
    }

    _touchHoldTimer?.cancel();
    if (event.kind == PointerDeviceKind.touch) {
      // Defer: if the finger moves first it was a scroll, not a selection.
      _dragBase = null;
      _touchDownAt = event.position;
      _touchHoldTimer = Timer(_touchHold, () {
        if (!mounted) return;
        final held = _positionAt(_touchDownAt!);
        _dragBase = held;
        // Long-press selects the word first, the way iOS/Android do; a drag
        // from here then extends that selection.
        if (held != null) {
          _selectWordAt(
            held.nodeId,
            (held.nodePosition as TextNodePosition).offset,
          );
        }
      });
      return;
    }
    _dragBase = position;
  }

  /// A tap that lands on the caret already sitting there means "show me the
  /// options" — copy/paste/select all — rather than "move the caret", which
  /// is what every native text field does. Shown on pointer *up* so the same
  /// tap's release doesn't dismiss it.
  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerDownOnHandle) {
      _pointerDownOnHandle = false;
      _endDrag();
      return;
    }
    final downAt = _tapDownAt;
    final moved = downAt != null && (event.position - downAt).distance > 8;
    if (!moved) {
      // ponytail: no double-tap-to-select-word yet — a second caret write in
      // the same gesture gets reverted by EditableText's own value pipeline.
      // Long-press covers word selection on touch; revisit with the
      // editor-level DeltaTextInputClient rewrite.
      final position = _positionAt(event.position);
      if (_tapRepeatsCaret) {
        final id = widget.controller.focusedNodeId;
        if (id != null) _editableKeys[id]?.currentState?.showToolbar();
      } else if (position != null && _dragBase == null) {
        widget.controller.requestFocus(position.nodeId);
        _placeCaret(
          position.nodeId,
          (position.nodePosition as TextNodePosition).offset,
        );
      }
    }
    _tapRepeatsCaret = false;
    _tapDownAt = null;
    _endDrag();
  }

  void _endDrag() {
    _touchHoldTimer?.cancel();
    _touchHoldTimer = null;
    _touchDownAt = null;
    _dragBase = null;
    _pointerDownOnHandle = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final touchDownAt = _touchDownAt;
    if (touchDownAt != null &&
        _dragBase == null &&
        (event.position - touchDownAt).distance > _touchSlop) {
      // Moved before the hold fired — this is a scroll. Let it be one.
      _endDrag();
      return;
    }
    final base = _dragBase;
    if (base == null) return;
    final extent = _positionAt(event.position);
    if (extent == null) return;
    widget.controller.changeSelection(
      DocumentSelection(base: base, extent: extent),
    );
  }

  /// Rects (in this editor's own coordinate space) covering every node a
  /// multi-node selection spans, for [SelectionOverlayPainter] — empty for
  /// no selection, a collapsed one, or one confined to a single node (that
  /// case is left entirely to the field's own painting).
  List<Rect> _computeOverlayRects() {
    final selection = widget.controller.composer.selection;
    if (selection == null || selection.isCollapsed) return const [];
    if (selection.base.nodeId == selection.extent.nodeId) return const [];

    final document = widget.controller.document;
    final (startPos, endPos) = selection.normalize(document);
    final startIndex = document.getNodeIndexById(startPos.nodeId);
    final endIndex = document.getNodeIndexById(endPos.nodeId);
    if (startIndex < 0 || endIndex < 0) return const [];

    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return const [];

    final rects = <Rect>[];
    for (var i = startIndex; i <= endIndex; i++) {
      final node = document.getNodeAt(i);
      if (node is! TextNode) continue;
      final renderEditable = _laidOutEditable(node.id);
      if (renderEditable == null) continue;

      final length = node.text.text.length;
      final segStart = i == startIndex
          ? (startPos.nodePosition as TextNodePosition).offset
          : 0;
      final segEnd = i == endIndex
          ? (endPos.nodePosition as TextNodePosition).offset
          : length;
      if (segEnd <= segStart) continue;

      // A node fully covered up to its own end (every node except the last)
      // has its boxes stretched to the render width, so consecutive
      // paragraphs read as one continuous highlight instead of stopping
      // short at the last glyph on each line.
      final stretchToEdge = i != endIndex;
      final boxes = renderEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: _toField(segStart),
          extentOffset: _toField(segEnd),
        ),
      );
      for (final box in boxes) {
        final rect = stretchToEdge
            ? Rect.fromLTRB(
                box.left,
                box.top,
                renderEditable.size.width,
                box.bottom,
              )
            : box.toRect();
        final topLeft = editorBox.globalToLocal(
          renderEditable.localToGlobal(rect.topLeft),
        );
        final bottomRight = editorBox.globalToLocal(
          renderEditable.localToGlobal(rect.bottomRight),
        );
        rects.add(Rect.fromPoints(topLeft, bottomRight));
      }
    }
    return rects;
  }

  // --- Multi-node selection drag handles ----------------------------------

  static const _handleKnobDiameter = 14.0;
  static const _handleHitSize = 24.0;

  /// The caret-height rect (in this editor's own coordinate space) at
  /// exactly [position] — unlike [_computeOverlayRects]'s per-line boxes
  /// (which stretch to the render width for every node but the last), this
  /// is a precise, zero-width caret rect at one specific offset, which is
  /// what a selection handle needs to sit exactly on the selection's edge.
  Rect? _caretRectAt(DocumentPosition position) {
    final nodePosition = position.nodePosition;
    if (nodePosition is! TextNodePosition) return null;
    final renderEditable = _laidOutEditable(position.nodeId);
    if (renderEditable == null) return null;
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return null;

    final caretRect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: _toField(nodePosition.offset)),
    );
    final topLeft = editorBox.globalToLocal(
      renderEditable.localToGlobal(caretRect.topLeft),
    );
    final bottomRight = editorBox.globalToLocal(
      renderEditable.localToGlobal(caretRect.bottomRight),
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// The hit-test rect (editor-local) for a handle drawn against
  /// [caretRect] — bigger than the visible knob so it's an easy touch
  /// target, and used both to lay the handle out and (via
  /// [_startHandleHitRect]/[_endHandleHitRect]) to keep the document-level
  /// drag `Listener` from also reacting to the same touch.
  Rect _handleLocalRect(Rect caretRect, {required bool isStart}) {
    final visualHeight = caretRect.height + _handleKnobDiameter;
    final height = math.max(_handleHitSize, visualHeight);
    final left = caretRect.left - _handleHitSize / 2;
    final top = isStart ? caretRect.top - _handleKnobDiameter : caretRect.top;
    return Rect.fromLTWH(left, top, _handleHitSize, height);
  }

  /// A vertical bar with a circular knob — at the top for the start handle,
  /// at the bottom for the end handle — matching the native iOS/Android
  /// text-selection handle look, wrapped in its own `GestureDetector` so its
  /// drag is scoped to just this widget rather than fighting the
  /// document-level `Listener`.
  Widget _buildHandle({
    required Rect caretRect,
    required bool isStart,
    required Color color,
    required ValueChanged<Offset> onDragUpdate,
  }) {
    final knob = Container(
      width: _handleKnobDiameter,
      height: _handleKnobDiameter,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final bar = Container(width: 2, height: caretRect.height, color: color);
    return Positioned.fromRect(
      key: ValueKey(isStart ? 'quire-start-handle' : 'quire-end-handle'),
      rect: _handleLocalRect(caretRect, isStart: isStart),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (details) => onDragUpdate(details.globalPosition),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: isStart ? [knob, bar] : [bar, knob],
          ),
        ),
      ),
    );
  }

  /// Draggable start/end handles for the current multi-node selection.
  /// Native `EditableText` handles only ever cover a single field, so once a
  /// selection spans nodes (e.g. after `selectAll()` on a multi-paragraph
  /// document) there is otherwise nothing to grab. Empty under exactly the
  /// same condition as [_computeOverlayRects] (collapsed or single-node
  /// selection), which is left entirely to the field's own native handles.
  List<Widget> _buildSelectionHandles(BuildContext context) {
    final selection = widget.controller.composer.selection;
    if (!_hasMultiNodeSelection || selection == null) {
      _startHandleHitRect = null;
      _endHandleHitRect = null;
      return const [];
    }
    final document = widget.controller.document;
    final (startPos, endPos) = selection.normalize(document);
    final startRect = _caretRectAt(startPos);
    final endRect = _caretRectAt(endPos);
    if (startRect == null || endRect == null) {
      _startHandleHitRect = null;
      _endHandleHitRect = null;
      return const [];
    }

    final startLocalRect = _handleLocalRect(startRect, isStart: true);
    final endLocalRect = _handleLocalRect(endRect, isStart: false);
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox != null && editorBox.attached) {
      _startHandleHitRect =
          editorBox.localToGlobal(startLocalRect.topLeft) & startLocalRect.size;
      _endHandleHitRect =
          editorBox.localToGlobal(endLocalRect.topLeft) & endLocalRect.size;
    } else {
      _startHandleHitRect = null;
      _endHandleHitRect = null;
    }

    final color = Theme.of(context).colorScheme.primary;
    return [
      _buildHandle(
        caretRect: startRect,
        isStart: true,
        color: color,
        onDragUpdate: (p) =>
            _dragSelectionHandle(isStart: true, globalPosition: p),
      ),
      _buildHandle(
        caretRect: endRect,
        isStart: false,
        color: color,
        onDragUpdate: (p) =>
            _dragSelectionHandle(isStart: false, globalPosition: p),
      ),
    ];
  }

  /// Moves the visual start (or end) of the current selection to wherever
  /// [globalPosition] lands, keeping the other end fixed — regardless of
  /// which of `selection.base`/`selection.extent` is currently the visual
  /// start vs end (that depends on which direction the original select
  /// gesture went), via [DocumentSelection.normalize].
  void _dragSelectionHandle({
    required bool isStart,
    required Offset globalPosition,
  }) {
    final selection = widget.controller.composer.selection;
    if (selection == null) return;
    final newPosition = _positionAt(globalPosition);
    if (newPosition == null) return;
    final (startPos, endPos) = selection.normalize(widget.controller.document);
    final target = isStart ? startPos : endPos;
    final fixed = isStart ? endPos : startPos;
    final targetIsBase = selection.base == target;
    widget.controller.changeSelection(
      DocumentSelection(
        base: targetIsBase ? newPosition : fixed,
        extent: targetIsBase ? fixed : newPosition,
      ),
    );
  }

  // --- Controller/focus-node bookkeeping ----------------------------------

  void _syncControllers() {
    final liveIds = widget.controller.document.nodesInDocumentOrder
        .whereType<TextNode>()
        .map((n) => n.id)
        .toSet();

    for (final staleId
        in _controllers.keys.where((id) => !liveIds.contains(id)).toList()) {
      _controllers.remove(staleId)?.dispose();
      _focusNodes.remove(staleId)?.dispose();
      _editableKeys.remove(staleId);
    }

    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      if (_controllers.containsKey(node.id)) continue;

      final controller = NodeTextController(nodeId: node.id, text: node.text);
      controller.addListener(() => _onControllerChanged(node.id));
      _controllers[node.id] = controller;

      final focusNode = FocusNode(debugLabel: node.id);
      focusNode.addListener(() {
        if (focusNode.hasFocus) {
          widget.controller.focusNode(node.id);
        } else {
          _handleFocusLost(node.id);
        }
      });
      _focusNodes[node.id] = focusNode;

      _editableKeys[node.id] = GlobalKey<EditableTextState>();
    }

    _pairs.clear();
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final controller = _controllers[node.id];
      if (controller != null) _pairs.add((node, controller));
    }
  }

  /// [nodeId]'s field just lost focus. Deferred to a microtask rather than
  /// checked synchronously: within the same tick, focus may still land on
  /// another node in this editor (tapping from paragraph to paragraph) — or
  /// this may be the toolbar's own panel-toggle dropping focus on purpose
  /// (`QuireToolbar._togglePanel` calls `primaryFocus?.unfocus()` and relies
  /// on `focusedNodeId` staying put so it can hand focus back later), which
  /// leaves nothing focused at all rather than moving focus elsewhere. Only a
  /// *third* case — some other real widget outside this editor ends up with
  /// focus — means focus genuinely left the editor, and only then is
  /// [focusedNodeId] cleared.
  void _handleFocusLost(String nodeId) {
    Future.microtask(() {
      if (!mounted) return;
      if (_focusNodes.values.any((f) => f.hasFocus)) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) return;
      widget.controller.clearFocusIfCurrent(nodeId);
    });
  }

  /// Pushes the model's [AttributedText] into each node's controller. Text
  /// is only overwritten when it actually differs from what the field
  /// already shows, and the field's selection is restored from the
  /// composer so a model-driven caret move (Enter, backspace-merge, undo)
  /// survives the round trip.
  void _pushModelToControllers() {
    _syncing = true;
    final composerSelection = widget.controller.composer.selection;
    // Read the selection's node ids ONCE, outside the loop. Leaving
    // `composerSelection!.base` inside a `&&` here crashed release (AOT)
    // builds with a null dereference: the field read is loop-invariant, and
    // hoisting it out of the loop loses the null guard. Debug/JIT never
    // optimises it, which is why only release builds died.
    final selectionBaseId = composerSelection?.base.nodeId;
    final selectionExtentId = composerSelection?.extent.nodeId;
    for (final (node, controller) in _pairs) {
      final modelText = node.text.text;
      final fieldText = _fieldTextFor(modelText);
      final targetsThisNode =
          selectionBaseId == node.id && selectionExtentId == node.id;

      if (controller.text != fieldText) {
        final selection = targetsThisNode
            ? _textSelectionFrom(composerSelection)
            : TextSelection.collapsed(
                offset: controller.selection.baseOffset.clamp(
                  0,
                  fieldText.length,
                ),
              );
        controller.value = TextEditingValue(
          text: fieldText,
          selection: selection,
        );
      } else if (targetsThisNode) {
        final selection = _textSelectionFrom(composerSelection);
        if (selection != controller.selection) {
          controller.selection = selection;
        }
      }
      controller.setAttributedText(node.text);
    }
    _syncing = false;
  }

  /// The text a node's field shows: a single leading zero-width-space
  /// sentinel followed by the model text. Present on EVERY node (not just
  /// empty ones), so the start of any paragraph has a character a soft
  /// keyboard can delete — that deletion is the only signal a soft keyboard
  /// gives for "backspace at the very start", which is what merges a
  /// paragraph into the one above it. The sentinel never reaches the model
  /// (see [_stripSentinel]) or the caret math (see [_toModel]/[_toField]).
  String _fieldTextFor(String modelText) => _emptyNodeSentinel + modelText;

  /// Undoes [_fieldTextFor] — the model must never see the sentinel. Strips
  /// only a leading one; a field that has lost its leading sentinel is
  /// [_onControllerChanged]'s signal that the user backspaced at offset 0.
  String _stripSentinel(String fieldText) =>
      fieldText.startsWith(_emptyNodeSentinel)
      ? fieldText.substring(_emptyNodeSentinel.length)
      : fieldText;

  /// Model offset → field offset (past the leading sentinel).
  int _toField(int modelOffset) => modelOffset + _emptyNodeSentinel.length;

  /// Field offset → model offset, clamped into the model's own length.
  int _toModel(int fieldOffset, int modelLength) =>
      (fieldOffset - _emptyNodeSentinel.length).clamp(0, modelLength);

  TextSelection _textSelectionFrom(DocumentSelection? selection) {
    if (selection == null) return TextSelection.collapsed(offset: _toField(0));
    final base = selection.base.nodePosition;
    final extent = selection.extent.nodePosition;
    if (base is TextNodePosition && extent is TextNodePosition) {
      return TextSelection(
        baseOffset: _toField(base.offset),
        extentOffset: _toField(extent.offset),
      );
    }
    return TextSelection.collapsed(offset: _toField(0));
  }

  void _maybeRequestFocus() {
    if (!mounted) return;
    final request = widget.controller.focusRequest;
    if (request == _handledFocusRequest) return;
    final id = widget.controller.focusedNodeId;
    if (id == null) return;
    final focusNode = _focusNodes[id];
    if (focusNode == null) return;
    _handledFocusRequest = request;
    if (!focusNode.hasFocus) focusNode.requestFocus();
  }

  /// Diffs the field's current plain text against the model's, as a single
  /// contiguous replacement (common prefix + common suffix — what an IME
  /// edit always looks like), and routes it through the model so
  /// attributions and undo survive. If only the selection moved, syncs that
  /// instead.
  void _onControllerChanged(String nodeId) {
    if (_syncing) return;
    final controller = _controllers[nodeId];
    if (controller == null) return;

    final oldText = controller.attributedText.text;
    final rawNewText = controller.text;

    // The leading sentinel was deleted with the model text otherwise
    // unchanged — the only thing a soft keyboard can express for "backspace
    // at the very start of this paragraph". Merge into the node above (works
    // whether or not the paragraph had any text). A full clear
    // (select-all + delete) also drops the sentinel but changes the text,
    // so it falls through to the normal diff below instead.
    if (!rawNewText.startsWith(_emptyNodeSentinel) && rawNewText == oldText) {
      // Deferred to a microtask: merging synchronously here could delete
      // this very node's own NodeTextController while it's still
      // mid-notifyListeners (this callback IS that notification) —
      // `_syncControllers` disposing it then would violate ChangeNotifier's
      // own reentrancy guard.
      scheduleMicrotask(() {
        if (!mounted) return;
        widget.controller.mergeWithPrevious(nodeId);
      });
      return;
    }
    final newText = _stripSentinel(rawNewText);

    if (oldText != newText) {
      final prefixLen = _commonPrefixLength(oldText, newText);
      final suffixLen = _commonSuffixLength(oldText, newText, prefixLen);
      final deleteEnd = oldText.length - suffixLen;
      final insertedText = newText.substring(
        prefixLen,
        newText.length - suffixLen,
      );

      // With a cross-node selection active, this field only ever showed a
      // stale local caret (see `_pushModelToControllers`) — the diff above
      // still correctly isolates what was typed (this node's text mirrored
      // the model exactly before the keystroke), but the prefix/suffix
      // offsets it's paired with are meaningless here. Replace the whole
      // document-level selection with what was typed instead of using them.
      final docSelection = widget.controller.composer.selection;
      if (docSelection != null &&
          docSelection.base.nodeId != docSelection.extent.nodeId) {
        widget.controller.replaceSelectionWithText(insertedText);
        return;
      }

      if (insertedText.contains('\n')) {
        // A soft keyboard's Return key sends no key event — with
        // TextInputAction.newline it lands here as a literal "\n" in the
        // diff. Split it into InsertNewlineRequests so it splits the node
        // the same way a physical Enter does, instead of leaving a raw
        // newline character inside one node's text.
        final segments = insertedText.split('\n');
        widget.controller.replaceText(
          nodeId: nodeId,
          start: prefixLen,
          end: deleteEnd,
          insertedText: segments.first,
        );
        if (segments.first.isEmpty && deleteEnd == prefixLen) {
          // replaceText was a no-op (nothing to delete or insert before the
          // first newline) and so left the composer's selection stale —
          // insertNewline splits at the composer's selection, so it must be
          // repositioned here or the split lands in the wrong place.
          widget.controller.changeSelection(
            DocumentSelection.collapsed(
              DocumentPosition(nodeId, TextNodePosition(prefixLen)),
            ),
          );
        }
        for (var i = 1; i < segments.length; i++) {
          widget.controller.insertNewline();
          final currentNodeId = widget.controller.focusedNodeId;
          if (currentNodeId != null && segments[i].isNotEmpty) {
            widget.controller.replaceText(
              nodeId: currentNodeId,
              start: 0,
              end: 0,
              insertedText: segments[i],
            );
          }
        }
      } else {
        widget.controller.replaceText(
          nodeId: nodeId,
          start: prefixLen,
          end: deleteEnd,
          insertedText: insertedText,
        );
      }
      return;
    }

    final selection = controller.selection;
    if (!selection.isValid) return;
    // Field offsets, clamped into the model's own length — with the
    // sentinel in place, an empty node's field selection sits at 0 or 1
    // (either side of the zero-width space) while the only valid model
    // offset is 0.
    final modelLength = oldText.length;
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(
          nodeId,
          TextNodePosition(_toModel(selection.baseOffset, modelLength)),
        ),
        extent: DocumentPosition(
          nodeId,
          TextNodePosition(_toModel(selection.extentOffset, modelLength)),
        ),
      ),
    );
  }

  int _commonPrefixLength(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  int _commonSuffixLength(String a, String b, int prefixLimit) {
    final maxA = a.length - prefixLimit;
    final maxB = b.length - prefixLimit;
    final max = maxA < maxB ? maxA : maxB;
    var i = 0;
    while (i < max &&
        a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
      i++;
    }
    return i;
  }

  // --- Enter / backspace interception -------------------------------------

  /// Physical-key bindings (desktop). Soft-keyboard Enter is handled in the
  /// controller-diff path instead (see `_onControllerChanged`), since a
  /// soft Return key emits no key event at all.
  ///
  /// Backspace is only bound when the caret is collapsed at offset 0 — every
  /// other backspace press is left unbound so `EditableText` deletes
  /// natively (including inside an IME composing region, which a blanket
  /// binding would otherwise corrupt).
  // ponytail: a soft keyboard sends no key event, and thus no deletion
  // delta, when there's nothing left to delete — so paragraph-merge via
  // Backspace is unavailable on touch (still works with a hardware
  // keyboard/Backspace-as-delete on desktop). Upgrade path: an editor-level
  // DeltaTextInputClient, which sees the IME's actual delete requests
  // instead of relying on key events.
  Map<ShortcutActivator, VoidCallback> _shortcutBindings(String nodeId) {
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.enter):
          widget.controller.insertNewline,
      const SingleActivator(LogicalKeyboardKey.numpadEnter):
          widget.controller.insertNewline,
      const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
          widget.controller.toggleBold,
      const SingleActivator(LogicalKeyboardKey.keyB, control: true):
          widget.controller.toggleBold,
      const SingleActivator(LogicalKeyboardKey.keyI, meta: true):
          widget.controller.toggleItalic,
      const SingleActivator(LogicalKeyboardKey.keyI, control: true):
          widget.controller.toggleItalic,
      const SingleActivator(LogicalKeyboardKey.keyU, meta: true):
          widget.controller.toggleUnderline,
      const SingleActivator(LogicalKeyboardKey.keyU, control: true):
          widget.controller.toggleUnderline,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          widget.controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          widget.controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          widget.controller.redo,
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): widget.controller.redo,
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
          widget.controller.selectAll,
      const SingleActivator(LogicalKeyboardKey.keyA, control: true):
          widget.controller.selectAll,
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
          widget.controller.copySelection,
      const SingleActivator(LogicalKeyboardKey.keyC, control: true):
          widget.controller.copySelection,
      const SingleActivator(LogicalKeyboardKey.keyX, meta: true):
          widget.controller.cutSelection,
      const SingleActivator(LogicalKeyboardKey.keyX, control: true):
          widget.controller.cutSelection,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
          widget.controller.pasteClipboard,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true):
          widget.controller.pasteClipboard,
    };

    final docSelection = widget.controller.composer.selection;
    final isCrossNode =
        docSelection != null &&
        docSelection.base.nodeId != docSelection.extent.nodeId;
    if (isCrossNode) {
      // A field's own selection can't reach across nodes, so a bare
      // Backspace/Delete here would otherwise fall through to EditableText
      // deleting inside just this one node's (locally collapsed) caret.
      bindings[const SingleActivator(LogicalKeyboardKey.backspace)] =
          widget.controller.deleteSelection;
      bindings[const SingleActivator(LogicalKeyboardKey.delete)] =
          widget.controller.deleteSelection;
    } else {
      final selection = _controllers[nodeId]?.selection;
      if (selection != null && selection.isValid && selection.isCollapsed) {
        if (selection.baseOffset == 0) {
          bindings[const SingleActivator(LogicalKeyboardKey.backspace)] = () =>
              widget.controller.mergeWithPrevious(nodeId);
        }
      }
    }

    if (widget.controller.isInsideTable(nodeId)) {
      bindings[const SingleActivator(LogicalKeyboardKey.tab)] = () =>
          widget.controller.moveToAdjacentCell(nodeId, forward: true);
      bindings[const SingleActivator(
        LogicalKeyboardKey.tab,
        shift: true,
      )] = () =>
          widget.controller.moveToAdjacentCell(nodeId, forward: false);
    }
    return bindings;
  }

  // --- Per-node-type widgets -----------------------------------------------

  Widget _buildNode(BuildContext context, DocumentNode node) {
    if (node is TextNode) return _buildTextNode(context, node);
    if (node is ImageNode) return _buildImageNode(context, node);
    if (node is TableNode) return _buildTableNode(context, node);
    if (node is HorizontalRuleNode) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(),
      );
    }
    return const SizedBox.shrink();
  }

  /// Resolves [node]'s grid and renders one child per distinct cell (a
  /// merged cell renders once, spanning its full rectangle) — each cell's
  /// nodes recurse back through [_buildNode], reusing the same per-node-type
  /// widgets used at the top level.
  Widget _buildTableNode(BuildContext context, TableNode node) {
    final grid = node.grid;
    final seen = <TableCell>{};
    final children = <Widget>[];
    for (var r = 0; r < grid.length; r++) {
      for (var c = 0; c < grid[r].length; c++) {
        final cell = grid[r][c];
        if (cell == null || !seen.add(cell)) continue;
        children.add(
          TableCellData(
            row: r,
            column: c,
            rowSpan: cell.rowSpan,
            colSpan: cell.colSpan,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final n in cell.nodes) _buildNode(context, n)],
              ),
            ),
          ),
        );
      }
    }
    final columnCount = grid.isEmpty ? 0 : grid[0].length;
    final tableGrid = TableGrid(
      rowCount: grid.length,
      columnCount: columnCount,
      columnWidths: node.columnWidths,
      borderColor: Theme.of(context).dividerColor,
      children: children,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // A table wider than the space we can give it lays out at its
          // natural width (RenderTableGrid falls back to that when given
          // unbounded width) and scrolls horizontally, rather than squeezing
          // every column down to unreadable widths. A table that fits keeps
          // today's behaviour untouched: fractions of the available width,
          // no scroll view.
          LayoutBuilder(
            builder: (context, constraints) {
              final naturalWidth =
                  columnCount * TableGrid.defaultMinColumnWidth;
              if (constraints.hasBoundedWidth &&
                  naturalWidth > constraints.maxWidth) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: tableGrid,
                );
              }
              return tableGrid;
            },
          ),
          // A control that sits in the document rather than a chrome bar
          // must not shout — small, muted, tight padding, no visual weight
          // beyond a hint of where to tap.
          // Material keeps a 48pt tap target around the 16pt glyph, which
          // reads as the button being indented from (and floating below) the
          // table's corner. Pull it back by that padding so it sits on the
          // corner, without shrinking the tap area.
          Transform.translate(
            offset: const Offset(-14, -12),
            child: TableSettingsMenu(
              controller: widget.controller,
              tableId: node.id,
              icon: Icon(
                Icons.settings_outlined,
                size: 16,
                color: Theme.of(context).hintColor,
              ),
              iconSize: 16,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextNode(BuildContext context, TextNode node) {
    final controller = _controllers[node.id]!;
    final focusNode = _focusNodes[node.id]!;
    final editableKey = _editableKeys[node.id]!;
    final theme = Theme.of(context);

    // Raw EditableText installs no tap recognizer of its own (that's defect
    // 1) — onTapDown, not onTap, so the caret lands with the touch the way a
    // real text field feels.
    final field = CallbackShortcuts(
      bindings: _shortcutBindings(node.id),
      child: EditableText(
        key: editableKey,
        controller: controller,
        focusNode: focusNode,
        style: _styleFor(theme, node),
        textAlign: _textAlignFor(node),
        // EditableText hard-defaults this to Brightness.light (unlike
        // TextField, which follows the theme), so an iOS keyboard would
        // come up light inside a dark app.
        keyboardAppearance: theme.brightness,
        // Flutter's own predictive-text bar has no completions behind it —
        // it just reserves the row and leaves it blank. `enableSuggestions`
        // alone doesn't touch this: on iOS the QuickType bar is tied to
        // autocorrect, not suggestions (Flutter's own doc comment on
        // enableSuggestions says as much) — autocorrect is what actually
        // removes the row instead of showing it empty.
        enableSuggestions: false,
        autocorrect: false,
        cursorColor: widget.cursorColor ?? theme.colorScheme.primary,
        backgroundCursorColor: theme.colorScheme.surfaceContainerHighest,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        selectionControls: switch (defaultTargetPlatform) {
          TargetPlatform.iOS ||
          TargetPlatform.macOS => cupertinoTextSelectionHandleControls,
          _ => materialTextSelectionHandleControls,
        },
        // Flutter's default menu offers only Select All on a collapsed
        // caret — Cut and Copy need a selection, and it has no built-in
        // "Select" (this word) button the way iOS does. Prepend one, so
        // tapping the caret gives Select / Select all / Paste, and choosing
        // Select puts Cut and Copy one tap away.
        contextMenuBuilder: (context, state) {
          final value = state.textEditingValue;
          final canSelectWord =
              value.selection.isCollapsed && value.text.isNotEmpty;
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: [
              if (canSelectWord)
                ContextMenuButtonItem(
                  label: 'Select',
                  onPressed: () {
                    state.hideToolbar();
                    _selectWordAt(
                      node.id,
                      _toModel(
                        value.selection.baseOffset,
                        node.text.text.length,
                      ),
                    );
                  },
                ),
              ...state.contextMenuButtonItems,
            ],
          );
        },
      ),
    );

    final prefix = _prefixFor(context, node);
    final row = prefix == null
        ? field
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              prefix,
              Expanded(child: field),
            ],
          );

    final indentPadding = node.indent * 24.0;

    switch (node.blockType) {
      case 'blockquote':
        return Container(
          margin: EdgeInsets.only(left: indentPadding, bottom: 4),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.dividerColor, width: 3),
            ),
          ),
          child: row,
        );
      case 'code':
        return Container(
          margin: EdgeInsets.only(left: indentPadding, bottom: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: row,
        );
      default:
        return Padding(
          padding: EdgeInsets.only(left: indentPadding, bottom: 4),
          child: row,
        );
    }
  }

  Widget _buildImageNode(BuildContext context, ImageNode node) {
    Widget errorBuilder(BuildContext context, Object error, StackTrace? st) =>
        Container(
          height: 120,
          alignment: Alignment.center,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        );
    final uri = Uri.tryParse(node.url);
    final isNetwork =
        uri != null && (uri.isScheme('http') || uri.isScheme('https'));
    final image = isNetwork
        ? Image.network(node.url, errorBuilder: errorBuilder)
        : Image.file(File(node.url), errorBuilder: errorBuilder);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          image,
          if (node.altText != null && node.altText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                node.altText!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _styleFor(ThemeData theme, TextNode node) {
    var base = (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16))
        .copyWith(height: node.lineSpacing);
    if (node.blockType == 'listItemTask' && node.isChecked) {
      base = base.copyWith(
        decoration: TextDecoration.lineThrough,
        color: theme.hintColor,
      );
    }
    switch (node.blockType) {
      case 'header1':
        return base.copyWith(fontSize: 32, fontWeight: FontWeight.bold);
      case 'header2':
        return base.copyWith(fontSize: 28, fontWeight: FontWeight.bold);
      case 'header3':
        return base.copyWith(fontSize: 24, fontWeight: FontWeight.bold);
      case 'header4':
        return base.copyWith(fontSize: 20, fontWeight: FontWeight.bold);
      case 'header5':
        return base.copyWith(fontSize: 18, fontWeight: FontWeight.bold);
      case 'header6':
        return base.copyWith(fontSize: 16, fontWeight: FontWeight.bold);
      case 'blockquote':
        return base.copyWith(fontStyle: FontStyle.italic);
      case 'code':
        return base.copyWith(fontFamily: 'monospace');
      default:
        return base;
    }
  }

  TextAlign _textAlignFor(TextNode node) {
    switch (node.textAlign) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      default:
        return TextAlign.left;
    }
  }

  /// Height of one line of [node]'s own text. Measured with a [TextPainter]
  /// rather than derived from `fontSize`, because the real line box comes
  /// from the font's metrics — and the font here is the host app's, not ours.
  double _lineHeight(BuildContext context, TextNode node) {
    final painter = TextPainter(
      text: TextSpan(text: 'x', style: _styleFor(Theme.of(context), node)),
      textDirection: Directionality.of(context),
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// The bullet/number sits beside its own `EditableText`, so it has to carry
  /// the node's text style itself — otherwise it renders at the default size
  /// and its baseline drifts off the line it labels.
  Widget? _prefixFor(BuildContext context, TextNode node) {
    if (node.blockType == 'listItemTask') {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        // Sized to exactly one line of this node's own text, so the checkbox
        // centres on the *first* line: the row is top-aligned, so a taller
        // box would push the mark down past a one-line item's text, and on a
        // wrapped item an unconstrained checkbox centres itself against the
        // whole paragraph instead of the line it belongs to.
        //
        // Checkbox paints a fixed 18pt mark centred in whatever box it's
        // given, so constraining the box is what moves the mark — the floor
        // keeps that mark from clipping at very small text sizes.
        child: SizedBox(
          width: 24,
          height: math.max(_lineHeight(context, node), 18),
          // Scaled rather than resized: Checkbox paints a fixed 18pt mark, so
          // this is the only way to shrink it — and because a transform is
          // paint-time, the box it centres in is untouched.
          child: Transform.scale(
            scale: 0.8,
            // Keeps the checkbox out of the focus tree so tapping it can't
            // pull focus (and the keyboard) off the node's text field. This
            // used to be a `FocusNode(canRequestFocus: false)` built inline,
            // which minted — and leaked — a new node on every rebuild, so
            // every keystroke re-attached it mid-frame.
            child: ExcludeFocus(
              child: Checkbox(
                value: node.isChecked,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => widget.controller.toggleTaskChecked(node.id),
              ),
            ),
          ),
        ),
      );
    }
    final label = switch (node.blockType) {
      'listItemUnordered' => '•',
      'listItemOrdered' =>
        '${_orderedListNumber(widget.controller.document, node.id)}.',
      _ => null,
    };
    if (label == null) return null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(label, style: _styleFor(Theme.of(context), node)),
    );
  }

  /// The number to show for an ordered-list item: 1-based within the
  /// contiguous run of `listItemOrdered` nodes at the same indent — a
  /// deeper indent starts its own run at 1, and any non-matching node
  /// (different block type or shallower indent) breaks the run.
  int _orderedListNumber(MutableDocument document, String nodeId) {
    final index = document.getNodeIndexById(nodeId);
    if (index < 0) return 1;
    final node = document.getNodeAt(index) as TextNode;
    var count = 1;
    for (var i = index - 1; i >= 0; i--) {
      final prev = document.getNodeAt(i);
      if (prev is! TextNode) break;
      if (prev.indent > node.indent) continue;
      if (prev.indent < node.indent) break;
      if (prev.blockType == 'listItemOrdered') {
        count++;
      } else {
        break;
      }
    }
    return count;
  }
}
