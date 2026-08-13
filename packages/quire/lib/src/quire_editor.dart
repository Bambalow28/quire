import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/services.dart';
import 'package:quire_core/quire_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'link_dialog.dart';
import 'node_text_controller.dart';
import 'quire_editor_controller.dart';
import 'table_grid.dart';
import 'table_settings_menu.dart';

// ponytail: one EditableText per node buys IME/handles/scribble for free.
// Cross-node selection is layered on top (editor-level drag + overlay
// painting) rather than replacing the fields with a single editor-level
// DeltaTextInputClient — that rewrite stays a separate, much larger project.

/// Selection controls with no handles and no legacy toolbar — the handles
/// are quire's own (see `_buildSelectionHandles`), and the toolbar is
/// `EditableText.contextMenuBuilder`, not this. Mixing in
/// [TextSelectionHandleControls] (on top of the already-empty
/// [EmptyTextSelectionControls]) matters, not just cosmetically: passing
/// `selectionControls: null` outright leaves `EditableTextState.showToolbar`
/// working (it's routed through `contextMenuBuilder` independently) but
/// breaks `TextSelectionOverlay.toolbarIsVisible`, which only reads the
/// `contextMenuBuilder`-driven state when `selectionControls is
/// TextSelectionHandleControls` — with a plain `null` it instead checks a
/// legacy `_toolbar` field that path never touches, so it reports the
/// toolbar as closed even while it's showing.
class _NoHandleTextSelectionControls extends EmptyTextSelectionControls
    with TextSelectionHandleControls {}

final _noHandleTextSelectionControls = _NoHandleTextSelectionControls();

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

  /// Per-`listItemTask` node's real first-line box (top offset from the
  /// field's own top, and that line's height), measured post-frame from the
  /// node's own `RenderEditable` — see [_scheduleChecklistBoxMeasurement].
  /// A `TextStyle.height` multiplier (`node.lineSpacing`) doesn't just grow
  /// the field's line-to-line spacing evenly above and below the glyphs; how
  /// Skia splits that extra leading for line 1 differs depending on whether
  /// the item wraps, so it can only be read from the real render object, not
  /// predicted from an isolated `TextPainter`. Empty until the first
  /// post-frame measurement lands, so [_prefixFor] falls back to the old
  /// `_lineHeight` estimate for one frame on first build.
  final Map<String, ({double topOffset, double height})> _checklistBoxes = {};

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

  /// Global hit-test rects for the current selection's two handles, refreshed
  /// every build by [_buildSelectionHandles] — for a multi-node selection
  /// these are quire's own draggable handles (see [_buildHandle]); for a
  /// selection confined to a single node there's no such widget (Flutter's
  /// own `EditableText`/`TextSelectionOverlay` draws and drives that handle
  /// entirely internally), but the rects are still computed so this
  /// document-level `Listener` knows to back off. `null` whenever no handle
  /// is showing (collapsed or no selection). Checked by [_handlePointerDown]
  /// so a touch that starts on either kind of handle is left to that
  /// handle's own gesture handling instead of also being picked up as a
  /// document-level tap/drag — every `Listener` in the tree sees every
  /// pointer event regardless, since `Listener` doesn't participate in the
  /// gesture arena.
  Rect? _startHandleHitRect;
  Rect? _endHandleHitRect;

  /// The most recent pointer kind seen in [_handlePointerDown] — used only
  /// to decide whether to render touch-style selection handles (see
  /// [_buildSelectionHandles]); everything else already branches on the
  /// current event's own `kind` directly.
  PointerDeviceKind? _lastPointerKind;

  /// Whether the pointer currently down started on a handle — see the
  /// comment in [_handlePointerDown] for why [_handlePointerUp] needs this
  /// instead of just re-checking the up position.
  bool _pointerDownOnHandle = false;

  /// The pointer id currently dragging each handle, or `null` when that
  /// handle isn't being dragged — set on that handle's own `onPointerDown`
  /// (see [_buildHandle]) so its `onPointerMove`/`onPointerUp` keep reacting
  /// to that exact pointer no matter where the finger travels afterward,
  /// same as a `Listener`'s owner keeps receiving events for a pointer that
  /// started within its hit-test area even once it moves outside those
  /// original bounds. A plain `GestureDetector.onPanUpdate` would lose this
  /// gesture to the ancestor `CustomScrollView`'s own drag recognizer in a
  /// genuinely scrollable document (the arena fight the document-level drag
  /// above already avoids by using a raw `Listener`) — using `Listener` here
  /// too sidesteps the same fight.
  int? _startHandlePointerId;
  int? _endHandlePointerId;

  /// The endpoint a handle drag keeps fixed, captured once at that handle's
  /// pointer-down — see [_dragSelectionHandle] for why this can't be
  /// recomputed on every move.
  DocumentPosition? _dragAnchor;

  /// Finger-to-caret correction for the drag in progress, captured at the
  /// same pointer-down — see [_buildHandle] for why probing the raw finger
  /// position doesn't work.
  Offset? _dragTouchOffset;

  /// The most recent raw pointer position for whichever drag (document-level
  /// or a selection handle) is in progress, re-read by [_onAutoscrollTick]
  /// on every tick even when the finger itself hasn't moved — the content
  /// sliding under a still finger changes what [_positionAt] resolves to,
  /// so holding still at the viewport edge must keep extending the
  /// selection, not just keep scrolling. `null` when no drag is active.
  Offset? _dragGlobalPosition;

  /// Set when the drag in progress was promoted from a long-press (see the
  /// touch-hold timer in [_handlePointerDown]) — the (start, end) of the word
  /// that long-press originally selected. Non-null only for that case, so a
  /// plain mouse/handle drag stays character-precise; see
  /// [_wordSnappedSelection] for how it's used to extend BY WHOLE WORDS the
  /// way native iOS/Android long-press-drag does.
  (DocumentPosition, DocumentPosition)? _wordDragAnchor;

  /// Runs while a drag (document-level or handle) has the finger within
  /// [_autoscrollMargin] of the viewport's top/bottom edge — see
  /// [_syncAutoscroll]. `null` when no autoscroll is needed right now.
  Timer? _autoscrollTimer;

  static const _autoscrollMargin = 40.0;
  static const _autoscrollMaxSpeed = 800.0; // px/sec, at full margin depth
  static const _autoscrollTick = Duration(milliseconds: 16);

  bool _isOnSelectionHandle(Offset globalPosition) =>
      (_startHandleHitRect?.contains(globalPosition) ?? false) ||
      (_endHandleHitRect?.contains(globalPosition) ?? false);

  /// Whether quire is currently drawing selection handles for anything —
  /// single-node or multi-node, see [_buildSelectionHandles] — so the
  /// scroll listener below knows whether their positions need refreshing.
  bool get _hasVisibleSelectionHandles {
    final selection = widget.controller.composer.selection;
    return selection != null && !selection.isCollapsed;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onModelChanged);
    // The overlay/handles are painted from each field's live (post-scroll)
    // render position — but nothing else here triggers a rebuild on scroll,
    // so without this they'd go stale under the moving content. This also
    // covers autoscroll-while-dragging (see `_syncAutoscroll`), which moves
    // the scroll offset out from under a selection handle drag.
    // Only when a selection with handles is actually on screen: otherwise
    // this would rebuild every field on every scroll frame for nothing.
    _scrollController.addListener(() {
      if (_hasVisibleSelectionHandles) setState(() {});
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
    _autoscrollTimer?.cancel();
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
    final nodes = _visibleNodes(widget.controller.document.nodes);
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
    // past the viewport edge is handled by `_syncAutoscroll`/`_onAutoscrollTick`.
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
          if (_buildGhostCaret(context) case final ghostCaret?) ghostCaret,
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
    // A checklist/list/header node with no typed text is still content the
    // user deliberately created — only a plain empty paragraph should show
    // the placeholder.
    return only is TextNode &&
        only.text.text.isEmpty &&
        only.blockType == 'paragraph';
  }

  /// Hides a collapsed toggle list's content from the rendered node list.
  /// The document model is flat (see `TextNode.indent`) — "content" means
  /// every node immediately following the toggle whose indent is greater
  /// than the toggle's own, stopping at the first node that's back at or
  /// above the toggle's indent (or a nested toggle inside a collapsed one,
  /// which is skipped along with it and re-evaluated on its own once its
  /// ancestor is expanded again).
  List<DocumentNode> _visibleNodes(List<DocumentNode> nodes) {
    final visible = <DocumentNode>[];
    int? collapsedAtIndent;
    for (final node in nodes) {
      final indent = node is TextNode ? node.indent : 0;
      if (collapsedAtIndent != null) {
        if (indent > collapsedAtIndent) continue;
        collapsedAtIndent = null;
      }
      visible.add(node);
      if (node is TextNode &&
          node.blockType == 'toggleList' &&
          node.isCollapsed) {
        collapsedAtIndent = indent;
      }
    }
    return visible;
  }

  /// Pastes with a detour for URLs: a clipboard that's *just* a bare
  /// `http(s)://...` string (not a URL sitting inside other text) offers
  /// turning it into a link with editable display text before it lands,
  /// rather than dropping the raw URL in as plain text. Every paste path
  /// (keyboard shortcut, system context-menu Paste) routes through this
  /// instead of calling `controller.pasteClipboard` directly.
  Future<void> _pasteWithLinkDetection() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    final uri = text == null ? null : Uri.tryParse(text);
    final isBareUrl =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.toString() == text;
    if (!isBareUrl) {
      await widget.controller.pasteClipboard();
      return;
    }
    if (!mounted) return;
    final result = await showLinkDialog(context, initialUrl: text!);
    if (!mounted) return;
    if (result != null) {
      widget.controller.insertLink(url: result.url, displayText: result.text);
    } else {
      await widget.controller.pasteClipboard();
    }
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

  /// Set while a deliberate non-collapsed same-node selection (word or
  /// paragraph select) is being applied, so [_onControllerChanged]'s
  /// selection-only path ignores the stale collapsed report that
  /// `EditableText`'s own internal tap-up handling still produces for the
  /// same physical click a moment later (it can't be suppressed — see the
  /// link-tap comment in [_handlePointerUp] for why). Without this, that
  /// stale report — which the guard below can't otherwise tell apart from a
  /// real one, since both are same-node — silently collapses the selection
  /// right back down. Cleared a frame later, once that stale report has had
  /// its chance to arrive.
  bool _suppressFieldSelectionSync = false;

  void _applyThenSuppressStaleReport(VoidCallback apply) {
    _suppressFieldSelectionSync = true;
    apply();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suppressFieldSelectionSync = false;
    });
  }

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
    _applyThenSuppressStaleReport(() {
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
    });
  }

  /// Selects the entire node (paragraph) — a triple-click's job on desktop.
  /// Each `TextNode` here already IS one paragraph, so "select the
  /// paragraph" is just "select the whole node's text", no line-boundary
  /// math needed the way it would be in a plain multi-line text field.
  void _selectNodeAt(String nodeId) {
    final state = _editableKeys[nodeId]?.currentState;
    if (state == null) return;
    final modelText = _controllers[nodeId]?.attributedText.text ?? '';
    if (modelText.isEmpty) return;
    _applyThenSuppressStaleReport(() {
      state.userUpdateTextEditingValue(
        state.textEditingValue.copyWith(
          selection: TextSelection(
            baseOffset: _toField(0),
            extentOffset: _toField(modelText.length),
          ),
        ),
        SelectionChangedCause.longPress,
      );
      widget.controller.changeSelection(
        DocumentSelection(
          base: DocumentPosition(nodeId, const TextNodePosition(0)),
          extent: DocumentPosition(nodeId, TextNodePosition(modelText.length)),
        ),
      );
      widget.controller.requestFocus(nodeId);
      state.showToolbar();
    });
  }

  /// Gives [state]'s field a real non-collapsed local selection (covering
  /// its own full field text) and then opens the toolbar — the same
  /// showToolbar()-needs-a-selection-overlay mechanism [_selectWordAt] uses.
  /// Called after [QuireEditorController.selectAll] so the toolbar (Cut/
  /// Copy) appears immediately instead of requiring a second long-press.
  ///
  /// The field's own selection here is cosmetic for a cross-node document
  /// selection (Cut/Copy/Paste are overridden to act on the whole document
  /// in that case) but must stay accurate for a single-node one, where the
  /// default Cut/Copy/Paste act on exactly this range — hence `_toField(0)`
  /// rather than the field's literal `0`, which would fold the leading
  /// sentinel into the copied text. Routing this through
  /// `userUpdateTextEditingValue` fires `_onControllerChanged`, but with the
  /// text unchanged it takes the selection-only path, which bails out
  /// immediately once it sees a cross-node document selection — so this
  /// can't clobber that selection.
  void _showToolbarForWholeField(EditableTextState state) {
    final value = state.textEditingValue;
    state.userUpdateTextEditingValue(
      value.copyWith(
        selection: TextSelection(
          baseOffset: _toField(0),
          extentOffset: value.text.length,
        ),
      ),
      SelectionChangedCause.toolbar,
    );
    state.showToolbar();
  }

  /// Moves the caret through EditableText's own gesture path rather than by
  /// poking its controller: that is what builds the selection overlay
  /// (handles, magnifier, copy/paste toolbar). A direct controller write
  /// leaves the overlay null and showToolbar() silently does nothing.
  void _placeCaret(String nodeId, int offset) {
    // [offset] came from `_positionAt`'s raw glyph-geometry hit-test (a tap
    // near/on a picked emoji, most commonly one right after picking it,
    // where the emoji renders wider than the surrounding text) — snap it
    // the same way the field's own selection-report path already does (see
    // `_snapToGraphemeBoundary`'s doc comment for exactly this scenario).
    // Missing this here meant a tap could still leave the caret split
    // inside a surrogate pair even though that fix already existed
    // elsewhere: a following backspace then only removed half the emoji's
    // code units, leaving the other half behind as a broken glyph.
    final node = widget.controller.document.getNodeById(nodeId);
    final snappedOffset = node is TextNode
        ? _snapToGraphemeBoundary(node.text.text, offset)
        : offset;
    final state = _editableKeys[nodeId]?.currentState;
    if (state != null) {
      state.userUpdateTextEditingValue(
        state.textEditingValue.copyWith(
          selection: TextSelection.collapsed(offset: _toField(snappedOffset)),
        ),
        SelectionChangedCause.tap,
      );
    }
    widget.controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(nodeId, TextNodePosition(snappedOffset)),
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

  /// True if [nodeId]/[offset] falls inside the current (non-collapsed)
  /// selection — a tap there means "show me the options" the same way a tap
  /// on an already-placed caret does (see [_caretAlreadyAt]), rather than
  /// "move the caret here", which is what a tap inside a highlighted range
  /// did before this existed: it silently collapsed the selection instead of
  /// bringing up Copy/Cut, unlike every native text field.
  bool _tapWithinSelection(String nodeId, int offset) {
    final selection = widget.controller.composer.selection;
    if (selection == null || selection.isCollapsed) return false;
    final document = widget.controller.document;
    final (start, end) = selection.normalize(document);
    final startIndex = document.getNodeIndexById(start.nodeId);
    final endIndex = document.getNodeIndexById(end.nodeId);
    final tapIndex = document.getNodeIndexById(nodeId);
    if (startIndex < 0 || endIndex < 0 || tapIndex < 0) return false;
    if (tapIndex < startIndex || tapIndex > endIndex) return false;
    final startOffset = start.nodePosition;
    if (tapIndex == startIndex &&
        startOffset is TextNodePosition &&
        offset < startOffset.offset) {
      return false;
    }
    final endOffset = end.nodePosition;
    if (tapIndex == endIndex &&
        endOffset is TextNodePosition &&
        offset > endOffset.offset) {
      return false;
    }
    return true;
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

  /// The URL of the `'link'` attribution actually painted under
  /// [globalPosition], or `null` if the tap didn't land on one — checked on
  /// every tap-up so tapping a link opens it instead of just moving the
  /// caret there.
  ///
  /// Deliberately not built on [_positionAt]: that resolves to the
  /// *nearest* character for any tap inside a node's full-width row (so a
  /// tap in the blank space to the right of a short line still "resolves"
  /// to its last character), which would make a link clickable across its
  /// entire row instead of just the linked glyphs. This hit-tests the
  /// link's own real glyph boxes instead, so only they are clickable.
  String? _linkUrlAtGlobalPosition(Offset globalPosition) {
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final renderEditable = _laidOutEditable(node.id);
      if (renderEditable == null) continue;
      final origin = renderEditable.localToGlobal(Offset.zero);
      final rect = origin & renderEditable.size;
      if (!rect.contains(globalPosition)) continue;
      final localPosition = globalPosition - origin;
      for (final span in node.text.spans) {
        if (span.attribution.name != 'link') continue;
        final boxes = renderEditable.getBoxesForSelection(
          TextSelection(baseOffset: span.start, extentOffset: span.end),
        );
        for (final box in boxes) {
          if (box.toRect().contains(localPosition)) {
            return span.attribution.value['url'] as String?;
          }
        }
      }
      // The tap landed inside this node's row but not on any link glyph —
      // no other node's row can also contain the same global point.
      return null;
    }
    return null;
  }

  static const _touchHold = Duration(milliseconds: 500);
  static const _touchSlop = 12.0;

  // Desktop double/triple-click word/paragraph selection — mouse/trackpad
  // only, tracked independently of `_tapRepeatsCaret`/`_tapDownAt` (those
  // exist for touch's "tap an existing caret to show the toolbar" gesture,
  // a different thing). Native click-count APIs aren't exposed through a
  // raw `Listener`, so this reimplements the standard OS heuristic: same
  // pointer kind, close enough in time and position to the previous
  // pointer-down, increments the streak; anything else resets it to 1.
  static const _multiClickTimeout = Duration(milliseconds: 400);
  static const _multiClickSlop = 6.0;
  int _clickCount = 0;
  Offset? _lastClickDownAt;
  DateTime? _lastClickDownTime;

  int _registerNonTouchClick(Offset position) {
    final now = DateTime.now();
    final lastTime = _lastClickDownTime;
    final lastPosition = _lastClickDownAt;
    final withinTime =
        lastTime != null && now.difference(lastTime) < _multiClickTimeout;
    final withinSlop =
        lastPosition != null &&
        (position - lastPosition).distance < _multiClickSlop;
    _clickCount = (withinTime && withinSlop) ? _clickCount + 1 : 1;
    _lastClickDownTime = now;
    _lastClickDownAt = position;
    return _clickCount;
  }

  void _handlePointerDown(PointerDownEvent event) {
    // A handle's own `Listener` (see [_buildHandle]) is a descendant of this
    // `Listener`, so this still fires for the same down/move/up events
    // regardless of what the handle does with them (Listener sees every
    // event once it's in a pointer's hit-test route, independent of the
    // gesture arena) — remembered here and re-checked in `_handlePointerUp`
    // so a handle drag doesn't ALSO get treated as a tap that collapses the
    // caret.
    _pointerDownOnHandle = _isOnSelectionHandle(event.position);
    if (_pointerDownOnHandle) return;
    _lastPointerKind = event.kind;
    if (event.kind != PointerDeviceKind.touch) {
      _registerNonTouchClick(event.position);
    } else {
      _clickCount = 0;
    }
    final position = _positionAt(event.position);
    if (position != null) {
      final offset = (position.nodePosition as TextNodePosition).offset;
      // The caret is placed on pointer *up*, not here: a tap must write the
      // selection exactly once, or the caret write races the word selection
      // a double-tap/long-press produces from the same gesture. Also true
      // for a tap anywhere inside an existing (non-collapsed) selection —
      // see `_tapWithinSelection`.
      _tapRepeatsCaret =
          _caretAlreadyAt(position.nodeId, offset) ||
          _tapWithinSelection(position.nodeId, offset);
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
        // from here then extends that selection BY WHOLE WORDS (see
        // `_wordSnappedSelection`) — remember the word it selected so
        // `_extendDocumentDragTo` can snap to it.
        if (held != null) {
          final offset = (held.nodePosition as TextNodePosition).offset;
          _selectWordAt(held.nodeId, offset);
          final modelText =
              _controllers[held.nodeId]?.attributedText.text ?? '';
          final (wordStart, wordEnd) = _wordBoundaryIn(modelText, offset);
          _wordDragAnchor = (
            DocumentPosition(held.nodeId, TextNodePosition(wordStart)),
            DocumentPosition(held.nodeId, TextNodePosition(wordEnd)),
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
      final linkUrl = _linkUrlAtGlobalPosition(event.position);
      if (linkUrl != null) {
        // Skips this listener's own caret placement below — EditableText's
        // own internal tap handling still focuses/places its caret alongside
        // this (it's a separate gesture recognizer this Listener can't
        // suppress), so the field ends up focused too. Not worth fighting:
        // EditableText has no read-only-free way to attach a tap recognizer
        // to a span instead (see RenderEditable.describeSemanticsConfiguration's
        // `assert(readOnly && !obscureText)`), which is why this lives here,
        // in the same document-level pointer listener drag-to-select uses.
        launchUrl(Uri.parse(linkUrl), mode: LaunchMode.externalApplication);
      } else if (event.kind != PointerDeviceKind.touch &&
          position != null &&
          _clickCount >= 2) {
        // EditableText's own internal tap recognizer (a separate gesture
        // recognizer this raw `Listener` can't suppress — same reason the
        // link-tap branch above can't stop it either) fires on this same
        // click a moment later and would otherwise collapse this selection
        // right back down, same race the ponytail note above hit for
        // touch's double-tap — `_selectWordAt`/`_selectNodeAt` guard against
        // it themselves now (see `_suppressFieldSelectionSync`), so this can
        // just call them directly.
        final nodeId = position.nodeId;
        final offset = (position.nodePosition as TextNodePosition).offset;
        if (_clickCount >= 3) {
          _selectNodeAt(nodeId);
        } else {
          _selectWordAt(nodeId, offset);
        }
      } else if (_tapRepeatsCaret && position != null) {
        final id = position.nodeId;
        final state = _editableKeys[id]?.currentState;
        final docSelection = widget.controller.composer.selection;
        if (state != null && docSelection != null) {
          final isCrossNode = docSelection.base.nodeId != docSelection.extent.nodeId;
          if (isCrossNode) {
            // This field only holds ONE slice of a selection that spans
            // other nodes too — there's no local range here that's both
            // correct (`docSelection`'s raw base/extent offsets don't fit
            // THIS field's own shorter text) and safe to paint (ANY
            // non-collapsed local selection on a node already covered by
            // `SelectionOverlayPainter`, see `_computeOverlayRects`, double-
            // highlights against it). Leave this field's local selection
            // alone — `contextMenuBuilder`'s `isCrossNode` branch guarantees
            // Copy/Cut regardless of it — `showToolbar()` alone still opens
            // the toolbar, the same as it already does for a collapsed
            // re-tapped caret (see the `_caretAlreadyAt` branch above).
            state.showToolbar();
          } else {
            // Single-node selection: `EditableText`'s own built-in toolbar
            // (what `showToolbar()` opens) reads Cut/Copy/Paste availability
            // off THIS FIELD's own local `TextEditingValue.selection`, not
            // `composer.selection` — merely preserving the latter left the
            // field's own selection as whatever it happened to be, which
            // for a tap landing inside a drag-made selection was still
            // collapsed (the drag only ever wrote `composer.selection`,
            // never this field's local one), so the toolbar only offered
            // Select/Select All. Mirror the real range into the field's own
            // selection instead — safe here since a single-node selection
            // has no separate overlay to double-paint against
            // (`_computeOverlayRects` returns empty for one).
            void applyAndShow() {
              state.userUpdateTextEditingValue(
                state.textEditingValue.copyWith(
                  selection: _textSelectionFrom(docSelection),
                ),
                SelectionChangedCause.tap,
              );
              state.showToolbar();
            }

            _applyThenSuppressStaleReport(applyAndShow);
            // Unlike `_selectWordAt`/`_selectNodeAt` (triggered from a
            // long-press timer, which has already won the gesture arena
            // before either runs — so no competing recognizer fires for
            // that same gesture), this branch runs on a plain tap:
            // `EditableText`'s own internal tap recognizer for that SAME
            // tap still resolves the arena a moment later and overwrites
            // this field's local selection with its own (collapsed, at the
            // tap point) one — genuinely concurrent for this gesture, not
            // just a stale report from an earlier one, so a single
            // suppressed apply isn't enough. Re-apply once more after that
            // recognizer has had its turn.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              applyAndShow();
            });
          }
        }
      } else if (position != null && _dragBase == null) {
        widget.controller.requestFocus(position.nodeId);
        final nodeId = position.nodeId;
        final offset = (position.nodePosition as TextNodePosition).offset;
        _placeCaret(nodeId, offset);
        // Same race as the tap-inside-selection branch above (see its
        // comment): EditableText's own internal tap recognizer for this
        // SAME tap resolves the gesture arena a moment later and overwrites
        // this field's local selection with its own raw, un-snapped
        // hit-tested offset — which can land mid-emoji-grapheme. Left
        // uncorrected, a physical Backspace right after tapping back into
        // the field reads that stale offset (`_shortcutBindings` uses the
        // field's own local selection, not `composer.selection`) and misses
        // the whole-emoji-delete path, splitting the emoji instead of
        // removing it. Re-snap once more after that recognizer has had its
        // turn.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _placeCaret(nodeId, offset);
        });
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
    _wordDragAnchor = null;
    _dragGlobalPosition = null;
    _stopAutoscroll();
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
    if (_dragBase == null) return;
    _dragGlobalPosition = event.position;
    _syncAutoscroll();
    _extendDocumentDragTo(event.position);
  }

  /// Extends the document-level drag started at [_dragBase] to
  /// [globalPosition] — character-precise for a plain drag, or snapped to
  /// whole words (see [_wordSnappedSelection]) when this drag was promoted
  /// from a long-press (`_wordDragAnchor` non-null). Also what
  /// [_onAutoscrollTick] re-runs every tick so the selection keeps growing
  /// while the finger holds still at the viewport edge.
  void _extendDocumentDragTo(Offset globalPosition) {
    final base = _dragBase;
    if (base == null) return;
    final extent = _positionAt(globalPosition);
    if (extent == null) return;
    final wordAnchor = _wordDragAnchor;
    final selection = wordAnchor == null
        ? DocumentSelection(base: base, extent: extent)
        : _wordSnappedSelection(wordAnchor, extent);
    widget.controller.changeSelection(selection);
  }

  /// -1 if [a] is before [b] in document order, 1 if after, 0 if equal.
  int _compareDocumentPositions(DocumentPosition a, DocumentPosition b) {
    final document = widget.controller.document;
    final nodeCompare = document
        .getNodeIndexById(a.nodeId)
        .compareTo(document.getNodeIndexById(b.nodeId));
    if (nodeCompare != 0) return nodeCompare;
    final aOffset = (a.nodePosition as TextNodePosition).offset;
    final bOffset = (b.nodePosition as TextNodePosition).offset;
    return aOffset.compareTo(bOffset);
  }

  /// The word boundary at [position], as a `(start, end)` pair of
  /// [DocumentPosition]s within [position]'s own node.
  (DocumentPosition, DocumentPosition) _wordPositionsAt(
    DocumentPosition position,
  ) {
    final modelText = _controllers[position.nodeId]?.attributedText.text ?? '';
    final offset = (position.nodePosition as TextNodePosition).offset;
    final (start, end) = _wordBoundaryIn(modelText, offset);
    return (
      DocumentPosition(position.nodeId, TextNodePosition(start)),
      DocumentPosition(position.nodeId, TextNodePosition(end)),
    );
  }

  /// Native iOS/Android long-press-drag behaviour: once a long-press has
  /// selected a word (`anchorWord`), continuing to drag extends the
  /// selection BY WHOLE WORDS rather than by exact character position —
  /// dragging past the anchor word's end keeps its START fixed and widens to
  /// the end of the word under [dragPosition]; dragging past its start keeps
  /// the END fixed and widens to that word's start; staying inside the
  /// anchor word itself leaves the selection exactly as the long-press left
  /// it.
  DocumentSelection _wordSnappedSelection(
    (DocumentPosition, DocumentPosition) anchorWord,
    DocumentPosition dragPosition,
  ) {
    final (anchorStart, anchorEnd) = anchorWord;
    if (_compareDocumentPositions(dragPosition, anchorStart) < 0) {
      final (dragStart, _) = _wordPositionsAt(dragPosition);
      return DocumentSelection(base: anchorEnd, extent: dragStart);
    }
    if (_compareDocumentPositions(dragPosition, anchorEnd) > 0) {
      final (_, dragEnd) = _wordPositionsAt(dragPosition);
      return DocumentSelection(base: anchorStart, extent: dragEnd);
    }
    return DocumentSelection(base: anchorStart, extent: anchorEnd);
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
        // Same guard as `_caretRectAt`: a node scrolled far enough past the
        // SliverList's cache extent (now reachable via autoscroll) can hand
        // back NaN geometry instead of throwing — skip that box rather than
        // painting a NaN rect.
        if (!topLeft.dx.isFinite ||
            !topLeft.dy.isFinite ||
            !bottomRight.dx.isFinite ||
            !bottomRight.dy.isFinite) {
          continue;
        }
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
    // A node that has scrolled far enough past the SliverList's cache
    // extent can stay `attached`/`hasSize` (see `_laidOutEditable`) while
    // its paint transform is no longer invertible — `localToGlobal`
    // /`globalToLocal` then hand back NaN instead of throwing. Autoscroll
    // can now drag a selection's fixed endpoint that far away, so this is
    // reachable in practice (it wasn't before autoscroll existed): treat it
    // the same as "not laid out" rather than handing NaN geometry to a
    // handle widget.
    if (!topLeft.dx.isFinite ||
        !topLeft.dy.isFinite ||
        !bottomRight.dx.isFinite ||
        !bottomRight.dy.isFinite) {
      return null;
    }
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
  /// text-selection handle look. Wrapped in its own raw `Listener` rather
  /// than a `GestureDetector`/`onPanUpdate`, for the same reason the
  /// document-level drag above uses one (see the comment on [_dragBase]'s
  /// content build above): a `GestureDetector` pan recognizer here would
  /// have to win the gesture arena against the ancestor `CustomScrollView`'s
  /// own vertical-drag recognizer, and loses in a genuinely scrollable
  /// document. A `Listener` just observes the raw pointer stream, so it
  /// can't lose that fight. [_startHandlePointerId]/[_endHandlePointerId]
  /// track which pointer this handle owns so its move/up handlers keep
  /// reacting to that pointer even once the finger travels outside this
  /// widget's original hit-test bounds.
  Widget _buildHandle({
    required Rect caretRect,
    required Offset caretGlobalCenter,
    required bool isStart,
    required Color color,
    required DocumentPosition anchor,
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
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (isStart) {
            _startHandlePointerId = event.pointer;
          } else {
            _endHandlePointerId = event.pointer;
          }
          _dragAnchor = anchor;
          // The knob is drawn deliberately OFF the text line (above it for
          // the start handle, below for the end) so it doesn't cover the
          // glyphs it points at — so the finger holding it is off the line
          // too. Probing `_positionAt` at the raw finger position therefore
          // misses this field's own rect and falls through to its
          // nearest-node fallback, which snaps the selection to another
          // node's edge. Remember how far the finger is from the caret it
          // grabbed, and keep probing at that corrected point for the whole
          // drag (the same trick Flutter's own TextSelectionOverlay uses).
          _dragTouchOffset = caretGlobalCenter - event.position;
        },
        onPointerMove: (event) {
          final owns = isStart
              ? _startHandlePointerId == event.pointer
              : _endHandlePointerId == event.pointer;
          if (!owns) return;
          _dragGlobalPosition = event.position;
          _syncAutoscroll();
          onDragUpdate(event.position);
        },
        onPointerUp: (event) {
          if (isStart) {
            _startHandlePointerId = null;
          } else {
            _endHandlePointerId = null;
          }
          _dragAnchor = null;
          _dragTouchOffset = null;
        },
        onPointerCancel: (event) {
          if (isStart) {
            _startHandlePointerId = null;
          } else {
            _endHandlePointerId = null;
          }
          _dragAnchor = null;
          _dragTouchOffset = null;
        },
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: isStart ? [knob, bar] : [bar, knob],
          ),
        ),
      ),
    );
  }

  /// Draggable start/end handles for the current selection, plus (as a side
  /// effect) [_startHandleHitRect]/[_endHandleHitRect] for
  /// [_isOnSelectionHandle]. Builds actual widgets for ANY non-collapsed
  /// selection, single-node or multi-node — native `EditableText` handles are
  /// disabled (see the `selectionControls:` comment on the field), so quire's
  /// own handles are the only ones there are.
  ///
  /// Skipped for a mouse/trackpad/stylus-made selection: these are sized and
  /// styled for a fingertip, and no native desktop app shows drag handles
  /// for a selection a precise pointer already made by dragging — the
  /// selection highlight itself (from `SelectionOverlayPainter`/the field's
  /// own `selectionColor`) is enough there.
  List<Widget> _buildSelectionHandles(BuildContext context) {
    final selection = widget.controller.composer.selection;
    if (selection == null ||
        selection.isCollapsed ||
        _lastPointerKind == PointerDeviceKind.mouse) {
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

    // No attached editor box means no global coordinates to correct the
    // drag against (see the `_dragTouchOffset` capture in [_buildHandle]),
    // and no hit rects either — so there's nothing draggable to show.
    if (editorBox == null || !editorBox.attached) return const [];

    final color = Theme.of(context).colorScheme.primary;
    return [
      _buildHandle(
        caretRect: startRect,
        caretGlobalCenter: editorBox.localToGlobal(startRect.center),
        isStart: true,
        color: color,
        anchor: endPos,
        onDragUpdate: _dragSelectionHandle,
      ),
      _buildHandle(
        caretRect: endRect,
        caretGlobalCenter: editorBox.localToGlobal(endRect.center),
        isStart: false,
        color: color,
        anchor: startPos,
        onDragUpdate: _dragSelectionHandle,
      ),
    ];
  }

  /// The position the ghost caret is currently showing (or was last asked
  /// to show) for, and its measured rect — see [_buildGhostCaret].
  DocumentPosition? _ghostCaretPosition;
  Rect? _ghostCaretRect;

  /// A dimmed caret-shaped bar at [composer.selection]'s position, shown
  /// only when nothing actually holds real focus there — e.g. the +/emoji
  /// panel is open, which deliberately avoids stealing focus back so it
  /// stays open for repeated picks (see `insertEmoji`'s doc comment) — so
  /// `EditableText`'s own native cursor, which only blinks while its
  /// `FocusNode.hasFocus` is true, isn't painting anything there. Without
  /// this the user has no visual sign of where the next insert will land.
  /// Left `null` (nothing painted) the moment real focus returns, so it
  /// never doubles up with the native cursor.
  Widget? _buildGhostCaret(BuildContext context) {
    final selection = widget.controller.composer.selection;
    if (selection == null || !selection.isCollapsed) {
      _ghostCaretPosition = null;
      return null;
    }
    final position = selection.extent;
    if (_focusNodes[position.nodeId]?.hasFocus ?? false) {
      _ghostCaretPosition = null;
      return null;
    }
    if (_ghostCaretPosition != position) {
      // `_caretRectAt` reads `RenderEditable` geometry that's still last
      // frame's — e.g. right after an emoji insert, the layout carrying the
      // new (wider) text hasn't run for this frame yet — the same
      // stale-until-the-frame-paints problem `_scheduleChecklistBoxMeasure
      // ment` already solves for the checklist checkbox box. Painting
      // `_caretRectAt(position)` straight into this build would flash the
      // caret at the OLD position for one frame before jumping to the new
      // one. Defer to a post-frame measurement instead and paint nothing
      // until it lands — one frame of absence reads far better than a
      // visible jump.
      _ghostCaretPosition = position;
      _ghostCaretRect = null;
      _scheduleGhostCaretMeasurement(position);
      return null;
    }
    final rect = _ghostCaretRect;
    if (rect == null) return null;
    return Positioned(
      key: const ValueKey('quire-ghost-caret'),
      left: rect.left,
      top: rect.top,
      width: 2,
      height: rect.height,
      child: IgnorePointer(
        child: Container(
          color: (widget.cursorColor ?? Theme.of(context).colorScheme.primary)
              .withValues(alpha: 0.5),
        ),
      ),
    );
  }

  void _scheduleGhostCaretMeasurement(DocumentPosition position) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The desired position may have moved on (another insert, real focus
      // returning) since this was scheduled — only apply a measurement
      // that's still for the position it's currently wanted at.
      if (_ghostCaretPosition != position) return;
      final rect = _caretRectAt(position);
      if (rect == _ghostCaretRect) return;
      setState(() => _ghostCaretRect = rect);
    });
  }

  /// Moves the dragged handle to wherever [globalPosition] lands, keeping
  /// [_dragAnchor] — the opposite endpoint, captured once at this drag's
  /// pointer-down (see [_buildHandle]) — fixed as `base`. Using the anchor
  /// captured at drag-start rather than re-deriving "the other endpoint" from
  /// the current selection on every move means a crossover (dragging past
  /// the anchor) just naturally inverts `base`/`extent`, which
  /// [DocumentSelection.normalize] handles everywhere downstream, instead of
  /// silently swapping which physical endpoint this handle is moving.
  void _dragSelectionHandle(Offset globalPosition) {
    final anchor = _dragAnchor;
    if (anchor == null) return;
    final newPosition = _positionAt(
      globalPosition + (_dragTouchOffset ?? Offset.zero),
    );
    if (newPosition == null) return;
    widget.controller.changeSelection(
      DocumentSelection(base: anchor, extent: newPosition),
    );
  }

  // --- Autoscroll while dragging past the viewport edge ------------------

  /// This editor's own on-screen rect — while it sits inside a
  /// `CustomScrollView`, the `Stack` this key is on is given the viewport's
  /// own (unscrolled) size, so its global rect IS the viewport, and is what
  /// [_autoscrollVelocityFor] measures the finger's distance from.
  Rect? _viewportRect() {
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return null;
    return editorBox.localToGlobal(Offset.zero) & editorBox.size;
  }

  /// Scroll speed (px/sec, signed — negative is up) for a finger at [dy],
  /// ramping from 0 at [_autoscrollMargin] in from the edge to
  /// [_autoscrollMaxSpeed] at (or past) the edge itself. 0 when [dy] isn't
  /// within the margin of either edge.
  double _autoscrollVelocityFor(double dy, Rect viewport) {
    final topDepth = viewport.top + _autoscrollMargin - dy;
    if (topDepth > 0) {
      return -_autoscrollMaxSpeed *
          (topDepth.clamp(0.0, _autoscrollMargin) / _autoscrollMargin);
    }
    final bottomDepth = dy - (viewport.bottom - _autoscrollMargin);
    if (bottomDepth > 0) {
      return _autoscrollMaxSpeed *
          (bottomDepth.clamp(0.0, _autoscrollMargin) / _autoscrollMargin);
    }
    return 0;
  }

  /// Starts (or stops) [_autoscrollTimer] to match whether the drag's
  /// current position is in the autoscroll margin right now — called from
  /// every document-level and handle drag move. The timer itself just keeps
  /// re-running [_onAutoscrollTick], which re-measures the margin on every
  /// tick, so it self-stops once the finger moves back toward the middle
  /// (or lifts, via [_endDrag]).
  void _syncAutoscroll() {
    final position = _dragGlobalPosition;
    final viewport = position == null ? null : _viewportRect();
    if (position == null ||
        viewport == null ||
        _autoscrollVelocityFor(position.dy, viewport) == 0) {
      _stopAutoscroll();
      return;
    }
    _autoscrollTimer ??= Timer.periodic(
      _autoscrollTick,
      (_) => _onAutoscrollTick(),
    );
  }

  void _stopAutoscroll() {
    _autoscrollTimer?.cancel();
    _autoscrollTimer = null;
  }

  /// One autoscroll step: nudges the scroll offset toward whichever edge the
  /// finger is near, then re-runs the selection update for whichever drag is
  /// active at the SAME finger position — that second part is what keeps the
  /// selection growing while the finger holds still at the edge, instead of
  /// only the content scrolling underneath it.
  void _onAutoscrollTick() {
    if (!mounted || !_scrollController.hasClients) {
      _stopAutoscroll();
      return;
    }
    final position = _dragGlobalPosition;
    final viewport = position == null ? null : _viewportRect();
    if (position == null || viewport == null) {
      _stopAutoscroll();
      return;
    }
    final velocity = _autoscrollVelocityFor(position.dy, viewport);
    if (velocity == 0) {
      _stopAutoscroll();
      return;
    }
    final scrollPosition = _scrollController.position;
    final newOffset =
        (scrollPosition.pixels +
                velocity * _autoscrollTick.inMilliseconds / 1000)
            .clamp(
              scrollPosition.minScrollExtent,
              scrollPosition.maxScrollExtent,
            );
    if (newOffset != scrollPosition.pixels) _scrollController.jumpTo(newOffset);
    _updateDragSelectionAt(position);
  }

  /// Re-runs whichever drag's selection update is active (document-level or
  /// a handle) at [globalPosition] — shared by [_onAutoscrollTick] so a still
  /// finger at the viewport edge keeps extending the selection.
  void _updateDragSelectionAt(Offset globalPosition) {
    if (_dragBase != null) {
      _extendDocumentDragTo(globalPosition);
    } else if (_dragAnchor != null) {
      _dragSelectionHandle(globalPosition);
    }
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
      _checklistBoxes.remove(staleId);
      if (_ghostCaretPosition?.nodeId == staleId) {
        _ghostCaretPosition = null;
        _ghostCaretRect = null;
      }
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
      } else if (!controller.selection.isCollapsed) {
        // This node isn't the exact single-node selection target (either
        // there's no selection, or this node is one piece of a wider
        // multi-node one — painted instead by `SelectionOverlayPainter`,
        // see `_computeOverlayRects`) — a non-collapsed local selection left
        // here (e.g. from a word long-press right before the drag extended
        // past this node into a cross-node range) would keep painting its
        // own native `selectionColor` highlight on top of that overlay,
        // double-shading wherever the two overlap.
        controller.selection = TextSelection.collapsed(
          offset: controller.selection.baseOffset.clamp(0, fieldText.length),
        );
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
    if (focusNode.hasFocus) return;
    // Only a *pre-existing* selection needs protecting below — e.g. the
    // +/emoji panel closing hands focus back to exactly where the caret
    // already was. A fresh mouse click, by contrast, requests focus on
    // pointer-down before it has a position at all (`composer.selection` is
    // still whatever it was before this click, often `null`) — its real,
    // correct selection only shows up *after* this, via EditableText's own
    // internal click handling. There's nothing to restore in that case, and
    // trying to would overwrite that legitimate new position with the stale
    // pre-click one once it resolves.
    final selectionBeforeFocus = widget.controller.composer.selection;
    focusNode.requestFocus();
    if (selectionBeforeFocus == null) return;
    // Gaining real focus here runs through `EditableText`'s own internal
    // focus-change handling (and, once it reopens its `TextInputConnection`,
    // whatever the platform echoes back for the newly-focused field) — both
    // write straight into this node's `NodeTextController` selection with no
    // idea where the model's own (grapheme-safe) caret actually is. Left
    // alone, that write doesn't just leave the *field* stale: the field
    // controller's own listener (`_onControllerChanged`) treats ANY outside
    // write to its selection as a genuine report and feeds it back into
    // `composer.selection` too (snapped, but snapped from the wrong raw
    // offset) — corrupting the model itself. This is exactly the gap
    // between "backspace still works while the +/emoji panel never closes"
    // (nothing here ever runs) and "breaks again once the panel closes and
    // reopens" (this path runs, unguarded, every time): `_shortcutBindings`'
    // physical-Backspace binding reads exactly the selection this echo
    // would have polluted. Restoring the known-correct pre-focus value a
    // frame later — after the echo has had its turn — fixes both the model
    // and (via the normal model→field push `changeSelection` triggers) the
    // field in one step, rather than trying to distinguish a real echo from
    // a legitimate report.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.controller.composer.selection == selectionBeforeFocus) {
        return;
      }
      widget.controller.changeSelection(selectionBeforeFocus);
    });
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
      var prefixLen = _commonPrefixLength(oldText, newText);
      final suffixLen = _commonSuffixLength(oldText, newText, prefixLen);
      var deleteEnd = oldText.length - suffixLen;
      final insertedText = newText.substring(
        prefixLen,
        newText.length - suffixLen,
      );

      // A pure deletion (no insertedText — backspace/delete, not a typed
      // replacement) that lands mid-grapheme means the platform only
      // removed part of a multi-code-unit character (typically half of a
      // picked emoji's surrogate pair) instead of the whole thing — iOS's
      // own soft-keyboard delete isn't reliably grapheme-aware for a custom
      // TextInputClient the way it is for a stock UITextField. Widen the
      // range to the enclosing grapheme cluster(s) so the whole character
      // goes, not a broken half of it.
      if (insertedText.isEmpty && prefixLen < deleteEnd) {
        final (expandedStart, expandedEnd) = _expandToGraphemeClusters(
          oldText,
          prefixLen,
          deleteEnd,
        );
        prefixLen = expandedStart;
        deleteEnd = expandedEnd;
      }

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
    if (_suppressFieldSelectionSync) return;

    // With a cross-node selection active, this field only ever holds a
    // stale local caret (see `_pushModelToControllers`) — a selection-only
    // report from it (e.g. the platform repositioning this field's own
    // caret) carries no real information about the document-wide selection
    // and must not overwrite it. Without this guard, that stale report
    // collapses `composer.selection` to a single point inside this node
    // right before a soft-keyboard delete arrives, so the delete only
    // removes one character here instead of the whole selection.
    final docSelection = widget.controller.composer.selection;
    if (docSelection != null &&
        docSelection.base.nodeId != docSelection.extent.nodeId) {
      return;
    }

    // Field offsets, clamped into the model's own length — with the
    // sentinel in place, an empty node's field selection sits at 0 or 1
    // (either side of the zero-width space) while the only valid model
    // offset is 0.
    final modelLength = oldText.length;
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(
          nodeId,
          TextNodePosition(
            _snapToGraphemeBoundary(
              oldText,
              _toModel(selection.baseOffset, modelLength),
            ),
          ),
        ),
        extent: DocumentPosition(
          nodeId,
          TextNodePosition(
            _snapToGraphemeBoundary(
              oldText,
              _toModel(selection.extentOffset, modelLength),
            ),
          ),
        ),
      ),
    );
  }

  /// [offset] moved to the nearer edge of the grapheme cluster of [text] it
  /// falls inside, or left alone if it's already on a cluster boundary.
  ///
  /// A tap resolves to a raw code-unit offset via hit-testing on rendered
  /// glyph geometry, which isn't guaranteed to land on a cluster boundary —
  /// a picked emoji (a surrogate pair, or wider still for a ZWJ sequence)
  /// can report a caret position that sits *inside* it. Left unsnapped, a
  /// later backspace from there deletes half the emoji's code units instead
  /// of the whole character, and the emoji itself never goes away.
  int _snapToGraphemeBoundary(String text, int offset) {
    if (offset <= 0 || offset >= text.length) return offset;
    var start = 0;
    for (final grapheme in text.characters) {
      final end = start + grapheme.length;
      if (offset > start && offset < end) {
        return offset - start <= end - offset ? start : end;
      }
      if (offset <= end) return offset;
      start = end;
    }
    return offset;
  }

  /// The tightest `[start, end)` range of [text]'s own grapheme clusters
  /// that fully contains `[start, end)` — each edge pushed out to the
  /// boundary of whatever cluster it falls inside, left alone if it's
  /// already on one. Unlike [_snapToGraphemeBoundary] (nearest edge, for a
  /// single caret position), this only ever widens — used to recover a
  /// deletion range the platform clipped to part of a character instead of
  /// all of it.
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
  /// Moves the caret into the next (or, for `forward: false`, the previous)
  /// `TextNode` — landing at its start when arriving from the left/above, or
  /// its end when arriving from the right/below, the same convention every
  /// desktop text editor uses for Left/Right running off a paragraph's edge.
  /// Skips non-text nodes (images, tables, rules) since they have no caret
  /// position of their own; a document that starts or ends with one still
  /// works, the search just keeps going until it finds a `TextNode` or runs
  /// out of document.
  void _moveToAdjacentNode(String nodeId, {required bool forward}) {
    final nodes = widget.controller.document.nodesInDocumentOrder;
    final index = nodes.indexWhere((n) => n.id == nodeId);
    if (index == -1) return;
    for (
      var i = index + (forward ? 1 : -1);
      forward ? i < nodes.length : i >= 0;
      forward ? i++ : i--
    ) {
      final target = nodes[i];
      if (target is! TextNode) continue;
      final offset = forward ? 0 : target.text.text.length;
      widget.controller.requestFocus(target.id);
      widget.controller.changeSelection(
        DocumentSelection.collapsed(
          DocumentPosition(target.id, TextNodePosition(offset)),
        ),
      );
      return;
    }
  }

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
      const SingleActivator(LogicalKeyboardKey.keyX, meta: true, shift: true):
          widget.controller.toggleStrikethrough,
      const SingleActivator(
        LogicalKeyboardKey.keyX,
        control: true,
        shift: true,
      ): widget.controller.toggleStrikethrough,
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
          _pasteWithLinkDetection,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true):
          _pasteWithLinkDetection,
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
        } else {
          final node = widget.controller.document.getNodeById(nodeId);
          final modelOffset = node is TextNode
              ? _toModel(selection.baseOffset, node.text.text.length)
              : 0;
          if (node is TextNode &&
              widget.controller.isEmojiBefore(nodeId, modelOffset)) {
            bindings[const SingleActivator(LogicalKeyboardKey.backspace)] =
                () => widget.controller.deleteEmojiBefore(nodeId, modelOffset);
          }
        }
      }

      // Cross-node Left/Right — bound only when the caret is already at
      // this node's own edge, so every other Left/Right press still falls
      // through to `EditableText`'s normal intra-paragraph caret movement
      // (a `CallbackShortcuts` entry always consumes its key once bound —
      // this is why these are added conditionally rather than checking the
      // boundary inside the callback).
      if (docSelection != null &&
          docSelection.isCollapsed &&
          docSelection.extent.nodeId == nodeId) {
        final offset =
            (docSelection.extent.nodePosition as TextNodePosition).offset;
        final node = widget.controller.document.getNodeById(nodeId);
        final textLength = node is TextNode ? node.text.text.length : 0;
        if (offset == 0) {
          bindings[const SingleActivator(LogicalKeyboardKey.arrowLeft)] = () =>
              _moveToAdjacentNode(nodeId, forward: false);
          bindings[const SingleActivator(LogicalKeyboardKey.arrowUp)] = () =>
              _moveToAdjacentNode(nodeId, forward: false);
        }
        if (offset == textLength) {
          bindings[const SingleActivator(LogicalKeyboardKey.arrowRight)] = () =>
              _moveToAdjacentNode(nodeId, forward: true);
          bindings[const SingleActivator(LogicalKeyboardKey.arrowDown)] = () =>
              _moveToAdjacentNode(nodeId, forward: true);
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

  /// Reads [node]'s field's real first-line box off its `RenderEditable`
  /// after this frame paints, and rebuilds if it moved [_prefixFor]'s
  /// checkbox/chevron. Scheduled from every build of a `listItemTask` or
  /// `toggleList` node (see [_buildTextNode]) — cheap: skipped entirely
  /// once the cached value stops changing, which is every frame after the
  /// first for a document that isn't actively resizing/retyping.
  void _scheduleChecklistBoxMeasurement(String nodeId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderEditable =
          _editableKeys[nodeId]?.currentState?.renderEditable;
      final fieldLength = _controllers[nodeId]?.text.length;
      if (renderEditable == null || fieldLength == null || fieldLength < 1) {
        return;
      }
      // Any run of characters confined to line 1 reports that line's real
      // box — one character (or just the sentinel, on an empty node) is
      // enough and can never cross a wrap point.
      final boxes = renderEditable.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: math.min(2, fieldLength)),
      );
      if (boxes.isEmpty) return;
      final box = boxes.first;
      final measured = (topOffset: box.top, height: box.bottom - box.top);
      final cached = _checklistBoxes[nodeId];
      const epsilon = 0.05;
      if (cached != null &&
          (cached.topOffset - measured.topOffset).abs() < epsilon &&
          (cached.height - measured.height).abs() < epsilon) {
        return;
      }
      setState(() => _checklistBoxes[nodeId] = measured);
    });
  }

  Widget _buildTextNode(BuildContext context, TextNode node) {
    final controller = _controllers[node.id]!;
    final focusNode = _focusNodes[node.id]!;
    final editableKey = _editableKeys[node.id]!;
    if (node.blockType == 'listItemTask' || node.blockType == 'toggleList') {
      _scheduleChecklistBoxMeasurement(node.id);
    }
    final theme = Theme.of(context);

    // Raw EditableText installs no tap recognizer of its own (that's defect
    // 1) — onTapDown, not onTap, so the caret lands with the touch the way a
    // real text field feels.
    //
    // MouseRegion sets the I-beam cursor over the text itself — EditableText
    // doesn't do this on its own since it has no gesture/cursor wiring of
    // its own either (same "defect 1"). SystemMouseCursors.text is a no-op
    // on touch (there's no mouse pointer to show it on), so this is safe to
    // apply unconditionally rather than gating it on pointer kind.
    final field = MouseRegion(
      cursor: SystemMouseCursors.text,
      child: CallbackShortcuts(
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
          // Soft-keyboard auto-shift for the first letter of a sentence. This
          // is a hint to the platform keyboard only — it never mutates typed
          // text itself, so intentional lowercase still goes through untouched.
          textCapitalization: TextCapitalization.sentences,
          cursorColor: widget.cursorColor ?? theme.colorScheme.primary,
          backgroundCursorColor: theme.colorScheme.surfaceContainerHighest,
          selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          // Native handles are disabled: selection is one-way (composer ->
          // field, see `_pushModelToControllers`), so a native handle drag only
          // ever mutates this field's local selection, which the next rebuild
          // overwrites with the stale composer selection, snapping the drag
          // back. Quire drives its own handles against `composer.selection`
          // instead (see `_buildSelectionHandles`) — the field still paints its
          // own selection highlight via `selectionColor`, only the draggable
          // handles are quire's. Not literally `null` — see
          // [_NoHandleTextSelectionControls]'s doc comment for why.
          selectionControls: _noHandleTextSelectionControls,
          // Flutter's default menu offers only Select All on a collapsed
          // caret — Cut and Copy need a selection, and it has no built-in
          // "Select" (this word) button the way iOS does. Prepend one, so
          // tapping the caret gives Select / Select all / Paste, and choosing
          // Select puts Cut and Copy one tap away.
          contextMenuBuilder: (context, state) {
            final value = state.textEditingValue;
            final canSelectWord =
                value.selection.isCollapsed && value.text.isNotEmpty;
            final docSelection = widget.controller.composer.selection;
            // Cut/Copy/Paste's built-in handlers act on this field's own
            // (possibly stale, see `_pushModelToControllers`) local selection
            // only — fine for a same-node selection, wrong once the document
            // selection spans more than one node, where they need to act on
            // the whole thing instead.
            final isCrossNode =
                docSelection != null &&
                docSelection.base.nodeId != docSelection.extent.nodeId;
            final transformedItems = [
              // EditableText's own "Select All" button (from
              // state.contextMenuButtonItems below) selects only within
              // this one field's own text — there's no touch path to the
              // document-wide controller.selectAll() otherwise (Cmd/Ctrl+A
              // only fires from a hardware keyboard). Replace it so the one
              // "Select All" button touch users actually have reaches the
              // whole document, the way the drag handles expect.
              for (final item in state.contextMenuButtonItems)
                if (item.type == ContextMenuButtonType.selectAll)
                  ContextMenuButtonItem(
                    label: item.label,
                    type: ContextMenuButtonType.selectAll,
                    onPressed: () {
                      state.hideToolbar();
                      widget.controller.selectAll();
                      _showToolbarForWholeField(state);
                    },
                  )
                else if (isCrossNode &&
                    item.type == ContextMenuButtonType.copy)
                  ContextMenuButtonItem(
                    label: item.label,
                    type: ContextMenuButtonType.copy,
                    onPressed: () {
                      state.hideToolbar();
                      widget.controller.copySelection();
                    },
                  )
                else if (isCrossNode &&
                    item.type == ContextMenuButtonType.cut)
                  ContextMenuButtonItem(
                    label: item.label,
                    type: ContextMenuButtonType.cut,
                    onPressed: () {
                      state.hideToolbar();
                      widget.controller.cutSelection();
                    },
                  )
                else if (isCrossNode &&
                    item.type == ContextMenuButtonType.paste)
                  ContextMenuButtonItem(
                    label: item.label,
                    type: ContextMenuButtonType.paste,
                    onPressed: () {
                      state.hideToolbar();
                      _pasteWithLinkDetection();
                    },
                  )
                else
                  item,
            ];
            // For a cross-node selection, this field's own local selection
            // is deliberately left alone (collapsed) when its tap opened
            // this toolbar — see the `_tapRepeatsCaret` branch in
            // `_handlePointerUp` — since giving it a real local selection to
            // generate these from would double-paint against
            // `SelectionOverlayPainter`. That means `state.contextMenuButtonItems`
            // above has nothing to transform into Copy/Cut: a collapsed
            // selection doesn't generate them at all. Add them directly.
            final hasCopy = transformedItems.any(
              (i) => i.type == ContextMenuButtonType.copy,
            );
            final hasCut = transformedItems.any(
              (i) => i.type == ContextMenuButtonType.cut,
            );
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
                ...transformedItems,
                if (isCrossNode && !hasCopy)
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: () {
                      state.hideToolbar();
                      widget.controller.copySelection();
                    },
                  ),
                if (isCrossNode && !hasCut)
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.cut,
                    onPressed: () {
                      state.hideToolbar();
                      widget.controller.cutSelection();
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );

    // An empty callout title shows its own inline placeholder — same
    // position as the real text, painted behind it — rather than a second
    // line below the box (that's [_buildEmptyContainerHint]'s job, for
    // toggles and for a callout that already has a title but no content
    // yet).
    final titleField = node.blockType == 'callout' && node.text.text.isEmpty
        ? Stack(
            children: [
              IgnorePointer(
                child: Text(
                  'Enter text...',
                  style: _styleFor(
                    theme,
                    node,
                  ).copyWith(color: theme.hintColor),
                ),
              ),
              field,
            ],
          )
        : field;

    final prefix = _prefixFor(context, node);
    final row = prefix == null
        ? titleField
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              prefix,
              Expanded(child: titleField),
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
      case 'toggleList':
        return Padding(
          padding: EdgeInsets.only(left: indentPadding, bottom: 4),
          child: !node.isCollapsed && !_containerHasContent(node)
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [row, _buildEmptyContainerHint(context, node)],
                )
              : row,
        );
      case 'callout':
        // Unlike a toggle, a callout's border has to visually wrap its
        // content too — but content is stored one indent level deeper (the
        // same marker toggle content uses), which would step the box in on
        // the left. Render it flush with the title instead; only the data
        // indent (used to detect "this is callout content") goes deeper.
        final hasContent = _containerHasContent(node);
        return Padding(
          padding: EdgeInsets.only(
            left: indentPadding,
            bottom: hasContent ? 0 : 4,
          ),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.transparent,
              // No bottom side when content follows — that edge belongs to
              // the content piece below, which draws its own top-less
              // border. A full Border.all here would draw a visible line
              // right where the two pieces meet.
              border: hasContent
                  ? Border(
                      top: BorderSide(color: theme.dividerColor),
                      left: BorderSide(color: theme.dividerColor),
                      right: BorderSide(color: theme.dividerColor),
                    )
                  : Border.all(color: theme.dividerColor),
              borderRadius: hasContent
                  ? const BorderRadius.vertical(top: Radius.circular(8))
                  : BorderRadius.circular(8),
            ),
            // No tappable "Empty callout" hint below the title — a callout
            // with no content yet is just its (single-line) title, with its
            // own inline placeholder when empty (see `titleField` above).
            // Content only appears once Enter is pressed on the title (see
            // commands.dart's `_InsertNewlineCommand`).
            child: row,
          ),
        );
      default:
        final container = _containerParentOf(node);
        if (container != null && container.blockType == 'callout') {
          final isLast = _isLastContainerContentNode(node, container);
          return Padding(
            // Flush with the callout's own left edge (see the 'callout'
            // case above) — not this node's own (deeper) indent.
            padding: EdgeInsets.only(
              left: container.indent * 24.0,
              bottom: isLast ? 4 : 0,
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: theme.dividerColor),
                  right: BorderSide(color: theme.dividerColor),
                  bottom: isLast
                      ? BorderSide(color: theme.dividerColor)
                      : BorderSide.none,
                ),
                borderRadius: isLast
                    ? const BorderRadius.vertical(bottom: Radius.circular(8))
                    : null,
              ),
              child: row,
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.only(left: indentPadding, bottom: 4),
          child: row,
        );
    }
  }

  /// Whether [container] already has a following node indented deeper than
  /// it — i.e. content of its own, as opposed to a toggle/callout nobody
  /// has written into yet. Checked against the raw (unfiltered) node list,
  /// not [_visibleNodes] — a collapsed toggle's content is hidden from
  /// rendering but still exists, and still counts as "has content".
  bool _containerHasContent(TextNode container) {
    final nodes = widget.controller.document.nodesInDocumentOrder.toList();
    final index = nodes.indexWhere((n) => n.id == container.id);
    if (index == -1 || index + 1 >= nodes.length) return false;
    final next = nodes[index + 1];
    return next is TextNode && next.indent > container.indent;
  }

  /// Tappable "Empty toggle" placeholder shown under a toggle with no
  /// content yet — without it, the only way to discover one can hold
  /// content is to place the caret at the end of its title and press Enter,
  /// which isn't obvious just by looking at it. A callout's own empty state
  /// is its title's inline placeholder instead (see `titleField` in
  /// `_buildTextNode`) — no tappable line of its own.
  Widget _buildEmptyContainerHint(BuildContext context, TextNode container) {
    final theme = Theme.of(context);
    const label = 'Empty toggle';
    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final newId = widget.controller.addToggleContent(container.id);
          // Deferred a frame — see addToggleContent's doc comment for why
          // requesting focus synchronously here loses a race against this
          // same tap's own document-level pointer handling.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.controller.requestFocus(newId);
            widget.controller.changeSelection(
              DocumentSelection.collapsed(
                DocumentPosition(newId, const TextNodePosition(0)),
              ),
            );
          });
        },
        child: Text(
          label,
          style: (theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16))
              .copyWith(
                fontSize:
                    (theme.textTheme.bodyLarge?.fontSize ?? 16) *
                    _containerContentScale,
                fontStyle: FontStyle.italic,
                color: theme.hintColor,
              ),
        ),
      ),
    );
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

  /// Content nested under a toggle or callout renders at this fraction of
  /// the normal body size, so it visibly reads as "inside" the container
  /// rather than a same-weight continuation of the title.
  static const _containerContentScale = 0.875;

  /// Block types that hold a title line followed by indented content —
  /// `toggleList` (collapsible, with a chevron) and `callout` (a bordered
  /// box, always expanded). Everything that treats "am I inside one of
  /// these" the same way — content font scaling, the empty-content hint,
  /// Enter-key behavior — is driven off this one set.
  static const _containerBlockTypes = {'toggleList', 'callout'};

  /// The nearest `toggleList`/`callout` ancestor [node] is content of, or
  /// null if it isn't nested under one. Walks the flat node list backward
  /// following the indent-tree's parent chain (the same one [_visibleNodes]
  /// and [ChangeIndentRequest] already imply): each step finds the nearest
  /// preceding node at a shallower indent (`node`'s "parent"); if that
  /// parent is a container, `node` is its content; otherwise the walk
  /// continues from the parent's own indent.
  TextNode? _containerParentOf(TextNode node) {
    if (node.indent == 0) return null;
    final nodes = widget.controller.document.nodesInDocumentOrder.toList();
    final index = nodes.indexWhere((n) => n.id == node.id);
    if (index == -1) return null;
    var currentIndent = node.indent;
    for (var i = index - 1; i >= 0; i--) {
      final candidate = nodes[i];
      if (candidate is! TextNode || candidate.indent >= currentIndent) continue;
      if (_containerBlockTypes.contains(candidate.blockType)) return candidate;
      if (candidate.indent == 0) return null;
      currentIndent = candidate.indent;
    }
    return null;
  }

  bool _isInsideContainer(TextNode node) => _containerParentOf(node) != null;

  /// Whether [node] is the last node in [container]'s content run — i.e.
  /// the next node in raw document order isn't indented deeper than
  /// [container]. Used to draw a callout's bottom border/rounded corners on
  /// the right content line, since its box is stitched together from
  /// several independently-rendered nodes rather than one widget.
  bool _isLastContainerContentNode(TextNode node, TextNode container) {
    final nodes = widget.controller.document.nodesInDocumentOrder.toList();
    final index = nodes.indexWhere((n) => n.id == node.id);
    if (index == -1 || index + 1 >= nodes.length) return true;
    final next = nodes[index + 1];
    return !(next is TextNode && next.indent > container.indent);
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
    if (_isInsideContainer(node)) {
      base = base.copyWith(
        fontSize: (base.fontSize ?? 16) * _containerContentScale,
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
      // The measured box (see [_scheduleChecklistBoxMeasurement]) is the
      // real first line's top offset + height off the field's own
      // RenderEditable. `TextStyle.height` (node.lineSpacing) doesn't split
      // its extra leading evenly above/below the glyphs, and how it splits
      // for line 1 differs between a one-line item and a wrapped one — a
      // synthetic TextPainter can't predict that, only the real render
      // object can. Nothing measured yet (first frame) falls back to the
      // old top-offset-0 / single-line-height estimate.
      final measured = _checklistBoxes[node.id];
      final topOffset = measured?.topOffset ?? 0.0;
      final height = measured?.height ?? _lineHeight(context, node);
      // Geometric centering on the line's own box reads as slightly low: an
      // outlined square's visual weight sits toward its lower half (the
      // stroke closes the shape there), so the eye expects it a touch above
      // true center. This is the standard optical correction for boxy glyphs
      // next to text — not a fontSize guess, hence exempt from "measure the
      // line, never guess" (see [_scheduleChecklistBoxMeasurement]). Done as
      // a paint-time translate, not folded into the padding above, because
      // `Padding` rejects a negative inset and this can't go negative.
      const opticalNudge = 1.5;
      return Padding(
        padding: EdgeInsets.only(top: topOffset, right: 4),
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
          height: math.max(height, 18),
          // Scaled rather than resized: Checkbox paints a fixed 18pt mark, so
          // this is the only way to shrink it — and because a transform is
          // paint-time, the box it centres in is untouched.
          child: Transform.translate(
            offset: const Offset(0, -opticalNudge),
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
                  onChanged: (_) =>
                      widget.controller.toggleTaskChecked(node.id),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (node.blockType == 'toggleList') {
      // Centered on the real measured first line the same way the
      // checklist checkbox is (see [_scheduleChecklistBoxMeasurement]) —
      // fixed at the checkbox's own mark size (18pt) so the two prefixes
      // read as the same size next to each other, rather than scaling with
      // the node's font size.
      final measured = _checklistBoxes[node.id];
      final topOffset = measured?.topOffset ?? 0.0;
      final height = measured?.height ?? _lineHeight(context, node);
      const iconSize = 18.0;
      return Padding(
        // No right inset: the icon box is exactly 24px — one indent level
        // — so the title's text starts flush with content text one level
        // deeper (`addToggleContent` gives content `indent: toggle.indent
        // + 1`). Any right padding here would push the title text further
        // right than the content below it.
        padding: EdgeInsets.only(top: topOffset),
        child: SizedBox(
          width: 24,
          height: math.max(height, iconSize),
          // A plain IconButton (not ExcludeFocus + GestureDetector like the
          // checkbox) is fine here — this row has no adjoining text field of
          // its own to steal focus from mid-tap, unlike a checklist item's
          // inline checkbox.
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: iconSize,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              node.isCollapsed ? Icons.chevron_right : Icons.expand_more,
            ),
            onPressed: () => widget.controller.toggleCollapsed(node.id),
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
