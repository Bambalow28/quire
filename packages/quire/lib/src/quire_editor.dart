import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:quire_core/quire_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'document_input_client.dart';
import 'link_dialog.dart';
import 'quire_editor_controller.dart';
import 'table_grid.dart';
import 'table_settings_menu.dart';
import 'text_span_builder.dart';

// The model is the only source of truth. Every TextNode renders as a plain
// RichText (no controller, no focus node, no platform input connection of
// its own) — one editor-level FocusNode and one DeltaTextInputClient
// (`document_input_client.dart`) drive the whole document. Cross-node
// selection, handles, overlay painting, ghost caret and word/paragraph
// select are quire's own, same as before; what's gone is the layer that used
// to exist only to keep a per-node EditableText in sync with the model and
// then fight its own internal gesture/selection handling.

/// Paints the highlight for the current selection, single-node or not — the
/// only thing that draws selection highlight, since nodes no longer have
/// their own field to paint one. [rects] are already in the editor's local
/// coordinate space. Pure paint logic, no document/render lookups, so it's
/// trivially testable in isolation.
class SelectionOverlayPainter extends CustomPainter {
  const SelectionOverlayPainter({required this.rects, required this.color});

  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (rects.isEmpty) return;
    // One drawPath call for every rect, not one drawRect call per rect: two
    // adjacent semi-transparent rects each get anti-aliased against the
    // background independently, and compositing those separately-blended
    // edges leaves a faint seam right where consecutive lines touch. Filling
    // them as a single path rasterizes the shared edge once, as interior to
    // one solid region, instead of twice.
    final path = Path();
    for (final rect in rects) {
      path.addRect(rect);
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant SelectionOverlayPainter oldDelegate) =>
      oldDelegate.rects != rects || oldDelegate.color != color;
}

/// Renders [QuireEditorController.document] as one render-only text block per
/// [TextNode] (plus image/rule/table widgets for the other node types).
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

/// The side of the mark Flutter's [Checkbox] paints, before scaling. It is
/// fixed — the widget ignores the box it is given — so it is the number every
/// checklist-alignment sum is built from.
const kCheckboxMarkSize = 18.0;

/// How far down that mark is scaled to sit next to body text without
/// out-weighing it. Paint-time, so the box it centres in is unaffected.
const kCheckboxMarkScale = 0.8;

/// A Latin UI face's cap height as a share of its ascent — roughly three
/// quarters of it, the ascent's remainder being the room a font keeps above
/// capitals for accents.
///
/// It is a ratio rather than a measurement because Flutter exposes a line's
/// ascent and never its cap height, and it is a ratio of the *measured*
/// ascent rather than of `fontSize` so it scales with whatever font the host
/// app hands the editor, the way everything else in this alignment does.
const kCapHeightOfAscent = 0.75;

class _QuireEditorState extends State<QuireEditor>
    with WidgetsBindingObserver
    implements DocumentInputHost {
  /// One `GlobalKey` per text node, so its `RichText`'s `RenderParagraph` is
  /// reachable for hit-testing/geometry (`_laidOutParagraph`) — the render-
  /// only replacement for the old per-node `RenderEditable`.
  final Map<String, GlobalKey> _paragraphKeys = {};

  /// Per-`listItemTask` node's real first-line box (top offset from the
  /// node's own top, and that line's height), measured post-frame from the
  /// node's own `RenderParagraph` — see [_scheduleChecklistBoxMeasurement].
  /// A `TextStyle.height` multiplier (`node.lineSpacing`) doesn't just grow
  /// the line-to-line spacing evenly above and below the glyphs; how Skia
  /// splits that extra leading for line 1 differs depending on whether the
  /// item wraps, so it can only be read from the real render object, not
  /// predicted from an isolated `TextPainter`. Empty until the first
  /// post-frame measurement lands, so [_prefixFor] falls back to the old
  /// `_lineHeight` estimate for one frame on first build.
  final Map<String, ({double topOffset, double height})> _checklistBoxes = {};

  /// Text nodes in document order, rebuilt by [_syncParagraphKeys].
  /// Everything that walks the document per frame reads this instead of
  /// re-filtering [QuireEditorController.document] each time.
  final List<TextNode> _textNodes = [];
  final GlobalKey _editorKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  /// The one focus node for the whole editor. Gaining it opens the IME
  /// connection ([DocumentInputClient]); losing it closes it. Replaces the
  /// old one-`FocusNode`-per-node scheme entirely.
  final FocusNode _editorFocusNode = FocusNode(debugLabel: 'quire-editor');

  late final DocumentInputClient _inputClient;

  /// Solid, blinking (500ms, like `EditableText`'s own cursor) while the
  /// editor has real focus and the selection is collapsed. Reset on every
  /// caret move/edit by [_resetCaretBlink].
  bool _caretBlinkOn = true;
  Timer? _caretBlinkTimer;

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
  /// every build by [_buildSelectionHandles].
  Rect? _startHandleHitRect;
  Rect? _endHandleHitRect;

  /// The most recent pointer kind seen in [_handlePointerDown] — used only
  /// to decide whether to render touch-style selection handles (see
  /// [_buildSelectionHandles]).
  PointerDeviceKind? _lastPointerKind;

  bool _pointerDownOnHandle = false;
  int? _startHandlePointerId;
  int? _endHandlePointerId;
  DocumentPosition? _dragAnchor;
  Offset? _dragTouchOffset;
  Offset? _dragGlobalPosition;
  (DocumentPosition, DocumentPosition)? _wordDragAnchor;

  Timer? _autoscrollTimer;

  static const _autoscrollMargin = 40.0;
  static const _autoscrollMaxSpeed = 800.0; // px/sec, at full margin depth
  static const _autoscrollTick = Duration(milliseconds: 16);

  bool _isOnSelectionHandle(Offset globalPosition) =>
      (_startHandleHitRect?.contains(globalPosition) ?? false) ||
      (_endHandleHitRect?.contains(globalPosition) ?? false);

  bool get _hasVisibleSelectionHandles {
    final selection = widget.controller.composer.selection;
    return selection != null && !selection.isCollapsed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputClient = DocumentInputClient(host: this);
    widget.controller.addListener(_onModelChanged);
    _editorFocusNode.addListener(_onEditorFocusChanged);
    _scrollController.addListener(() {
      _hideContextMenu();
      if (_hasVisibleSelectionHandles) setState(() {});
      if (_editorFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _inputClient.pushGeometry(),
        );
      }
    });
    _syncAndPush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onModelChanged);
    _editorFocusNode.dispose();
    _inputClient.dispose();
    _touchHoldTimer?.cancel();
    _autoscrollTimer?.cancel();
    _caretBlinkTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() => _keepCaretVisible();

  void _onEditorFocusChanged() {
    if (_editorFocusNode.hasFocus) {
      final id = widget.controller.focusedNodeId ?? _firstTextNodeId();
      if (id != null) widget.controller.focusNode(id);
      // Every real gesture path (tap, word/paragraph select, `_focusLastNodeAtEnd`)
      // sets a selection before it requests focus — but a caller that goes
      // straight to `QuireEditorController.requestFocus` with no selection
      // yet (a bare programmatic focus) would otherwise leave the IME with
      // no node to target: default to that node's start so typing works
      // immediately instead of silently doing nothing until some other
      // selection change arrives.
      if (widget.controller.composer.selection == null && id != null) {
        widget.controller.changeSelection(
          DocumentSelection.collapsed(
            DocumentPosition(id, const TextNodePosition(0)),
          ),
        );
      }
      widget.controller.hideGhostCaret = false;
      _inputClient.attach();
    } else {
      _handleFocusLost();
      _inputClient.detach();
      _hideContextMenu();
    }
    _resetCaretBlink();
    if (mounted) setState(() {});
  }

  String? _firstTextNodeId() => _textNodes.isEmpty ? null : _textNodes.first.id;

  void _resetCaretBlink() {
    _caretBlinkTimer?.cancel();
    _caretBlinkOn = true;
    if (!_editorFocusNode.hasFocus) return;
    _caretBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() => _caretBlinkOn = !_caretBlinkOn);
    });
  }

  /// Runs before `setState` so no controller/model listener ever fires
  /// mid-build.
  void _onModelChanged() {
    // Hide on typing (and on any other model change — a toolbar action, an
    // undo) the same way a native selection toolbar disappears the moment
    // its selection stops meaning what it showed.
    _hideContextMenu();
    _syncAndPush();
    setState(() {});
  }

  void _syncAndPush() {
    _syncParagraphKeys();
    _inputClient.syncFromModel();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeRequestFocus());
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepCaretVisible());
  }

  @override
  Widget build(BuildContext context) {
    // Every rebuild can move the focused node on screen (layout, scroll —
    // see the scroll listener — keyboard insets); keep the IME's idea of
    // where it is current. `pushGeometry` only sends what changed.
    if (_editorFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _inputClient.pushGeometry(),
      );
    }
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

    // Document-level drag-to-select: a raw Listener rather than a
    // GestureDetector pan recognizer, so it never has to fight the
    // CustomScrollView's own vertical-drag recognizer for the gesture arena
    // — it just observes the same pointer stream. Autoscroll while dragging
    // past the viewport edge is handled by `_syncAutoscroll`/`_onAutoscrollTick`.
    final content = Focus(
      focusNode: _editorFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: (_) => _endDrag(),
        child: Stack(
          key: _editorKey,
          children: [
            scrollView,
            // Paints every non-collapsed selection, single-node or not.
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
            if (_buildCaret(context) case final caret?) caret,
          ],
        ),
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

  /// A node's [RenderParagraph], but only once it is actually attached and
  /// laid out. Touching `size`/`localToGlobal`/`getPositionForOffset` before
  /// that is an assertion in debug and undefined behaviour in release, and
  /// this is reachable on the first frame and for a node the list hasn't
  /// laid out yet.
  RenderParagraph? _laidOutParagraph(String nodeId) {
    final renderObject = _paragraphKeys[nodeId]?.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderParagraph) return null;
    if (!renderObject.attached || !renderObject.hasSize) return null;
    return renderObject;
  }

  /// The run of non-whitespace characters containing [offset] — a
  /// model-space word boundary.
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

  String _modelTextOf(String nodeId) {
    final node = widget.controller.document.getNodeById(nodeId);
    return node is TextNode ? node.text.text : '';
  }

  /// Selects the word under [offset] and opens the context menu — what a
  /// double-tap or long-press does in any native text field.
  void _selectWordAt(String nodeId, int offset) {
    final modelText = _modelTextOf(nodeId);
    final (wordStart, wordEnd) = _wordBoundaryIn(modelText, offset);
    if (wordEnd <= wordStart) return;
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(nodeId, TextNodePosition(wordStart)),
        extent: DocumentPosition(nodeId, TextNodePosition(wordEnd)),
      ),
    );
    widget.controller.requestFocus(nodeId);
    _showContextMenu();
  }

  /// Selects the entire node (paragraph) — a triple-click's job on desktop.
  /// Each `TextNode` here already IS one paragraph, so "select the
  /// paragraph" is just "select the whole node's text", no line-boundary
  /// math needed the way it would be in a plain multi-line text field.
  void _selectNodeAt(String nodeId) {
    final modelText = _modelTextOf(nodeId);
    if (modelText.isEmpty) return;
    widget.controller.changeSelection(
      DocumentSelection(
        base: DocumentPosition(nodeId, const TextNodePosition(0)),
        extent: DocumentPosition(nodeId, TextNodePosition(modelText.length)),
      ),
    );
    widget.controller.requestFocus(nodeId);
    _showContextMenu();
  }

  void _placeCaret(String nodeId, int offset) {
    // [offset] came from `_positionAt`'s raw glyph-geometry hit-test (a tap
    // near/on a picked emoji, most commonly one right after picking it,
    // where the emoji renders wider than the surrounding text) — snap it
    // the same way the IME selection-report path already does (see
    // `_snapToGraphemeBoundary`'s doc comment for exactly this scenario).
    final node = widget.controller.document.getNodeById(nodeId);
    final snappedOffset = node is TextNode
        ? _snapToGraphemeBoundary(node.text.text, offset)
        : offset;
    widget.controller.changeSelection(
      DocumentSelection.collapsed(
        DocumentPosition(nodeId, TextNodePosition(snappedOffset)),
      ),
    );
    widget.controller.requestFocus(nodeId);
    _resetCaretBlink();
  }

  /// True if [nodeId]/[offset] falls inside the current (non-collapsed)
  /// selection — a tap there means "show me the options" (open the context
  /// menu) rather than "move the caret here".
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

  bool _caretAlreadyAt(String nodeId, int offset) {
    if (!_editorFocusNode.hasFocus) return false;
    final selection = widget.controller.composer.selection;
    if (selection == null || !selection.isCollapsed) return false;
    if (selection.extent.nodeId != nodeId) return false;
    final position = selection.extent.nodePosition;
    return position is TextNodePosition && position.offset == offset;
  }

  /// Resolves a global point to a document position by hit-testing every
  /// text node's live render rect, then mapping through that node's own
  /// `RenderParagraph`.
  DocumentPosition? _positionAt(Offset globalPosition) {
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final paragraph = _laidOutParagraph(node.id);
      if (paragraph == null) continue;
      final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
      if (!rect.contains(globalPosition)) continue;
      final localOffset = paragraph.globalToLocal(globalPosition);
      final rawOffset = paragraph.getPositionForOffset(localOffset).offset;
      // Clamp into the model's own length — an empty node renders the
      // U+200B render placeholder (see `text_span_builder.dart`) and can report an
      // offset the (empty) model has no such position for.
      return DocumentPosition(
        node.id,
        TextNodePosition(rawOffset.clamp(0, node.text.text.length)),
      );
    }
    // Between two nodes (or past the last one): fall back to the vertically
    // nearest node, so a drag doesn't freeze whenever it crosses a gap.
    TextNode? nearest;
    var nearestDistance = double.infinity;
    var above = false;
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final paragraph = _laidOutParagraph(node.id);
      if (paragraph == null) continue;
      final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
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
  /// [globalPosition], or `null` if the tap didn't land on one.
  String? _linkUrlAtGlobalPosition(Offset globalPosition) {
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      final paragraph = _laidOutParagraph(node.id);
      if (paragraph == null) continue;
      final origin = paragraph.localToGlobal(Offset.zero);
      final rect = origin & paragraph.size;
      if (!rect.contains(globalPosition)) continue;
      final localPosition = globalPosition - origin;
      for (final span in node.text.spans) {
        if (span.attribution.name != 'link') continue;
        final boxes = paragraph.getBoxesForSelection(
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

  static const _multiClickTimeout = Duration(milliseconds: 400);
  static const _multiClickSlop = 6.0;
  int _clickCount = 0;
  Offset? _lastClickDownAt;
  DateTime? _lastClickDownTime;
  PointerDeviceKind? _lastClickKind;

  void _resetClickStreak() {
    _clickCount = 0;
    _lastClickDownTime = null;
  }

  int _registerClick(Offset position, PointerDeviceKind kind) {
    final now = DateTime.now();
    // A fingertip lands less precisely than a cursor.
    final slop = kind == PointerDeviceKind.touch
        ? _touchSlop * 2
        : _multiClickSlop;
    final lastTime = _lastClickDownTime;
    final lastPosition = _lastClickDownAt;
    final withinTime =
        lastTime != null && now.difference(lastTime) < _multiClickTimeout;
    final withinSlop =
        lastPosition != null && (position - lastPosition).distance < slop;
    _clickCount = (withinTime && withinSlop && kind == _lastClickKind)
        ? _clickCount + 1
        : 1;
    _lastClickKind = kind;
    _lastClickDownTime = now;
    _lastClickDownAt = position;
    return _clickCount;
  }

  void _handlePointerDown(PointerDownEvent event) {
    _hideContextMenu();
    _pointerDownOnHandle = _isOnSelectionHandle(event.position);
    if (_pointerDownOnHandle) return;
    _lastPointerKind = event.kind;
    _registerClick(event.position, event.kind);
    final position = _positionAt(event.position);
    if (position != null) {
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
        _resetClickStreak(); // a long-press is not the first tap of a double
        final held = _positionAt(_touchDownAt!);
        _dragBase = held;
        if (held != null) {
          final offset = (held.nodePosition as TextNodePosition).offset;
          _selectWordAt(held.nodeId, offset);
          final modelText = _modelTextOf(held.nodeId);
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

  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerDownOnHandle) {
      _pointerDownOnHandle = false;
      _endDrag();
      return;
    }
    final downAt = _touchDownAt ?? _lastClickDownAt;
    final moved = downAt != null && (event.position - downAt).distance > 8;
    if (moved) _resetClickStreak(); // a drag is not the first tap of a double
    if (!moved) {
      final position = _positionAt(event.position);
      final linkUrl = _linkUrlAtGlobalPosition(event.position);
      if (linkUrl != null) {
        launchUrl(Uri.parse(linkUrl), mode: LaunchMode.externalApplication);
      } else if (position != null && _clickCount >= 2) {
        final nodeId = position.nodeId;
        final offset = (position.nodePosition as TextNodePosition).offset;
        if (_clickCount >= 3) {
          _selectNodeAt(nodeId);
        } else {
          _selectWordAt(nodeId, offset);
        }
      } else if (position != null &&
          (_caretAlreadyAt(
                position.nodeId,
                (position.nodePosition as TextNodePosition).offset,
              ) ||
              _tapWithinSelection(
                position.nodeId,
                (position.nodePosition as TextNodePosition).offset,
              ))) {
        // A tap on the caret already there, or inside an existing selection,
        // means "show me the options" — copy/paste/select all — rather than
        // "move the caret", which is what every native text field does.
        widget.controller.requestFocus(position.nodeId);
        _showContextMenu();
      } else if (position != null && _dragBase == null) {
        widget.controller.requestFocus(position.nodeId);
        final nodeId = position.nodeId;
        final offset = (position.nodePosition as TextNodePosition).offset;
        _placeCaret(nodeId, offset);
      }
    }
    _touchDownAt = null;
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
  /// from a long-press (`_wordDragAnchor` non-null).
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

  (DocumentPosition, DocumentPosition) _wordPositionsAt(
    DocumentPosition position,
  ) {
    final modelText = _modelTextOf(position.nodeId);
    final offset = (position.nodePosition as TextNodePosition).offset;
    final (start, end) = _wordBoundaryIn(modelText, offset);
    return (
      DocumentPosition(position.nodeId, TextNodePosition(start)),
      DocumentPosition(position.nodeId, TextNodePosition(end)),
    );
  }

  /// Native iOS/Android long-press-drag behaviour: once a long-press has
  /// selected a word (`anchorWord`), continuing to drag extends the
  /// selection BY WHOLE WORDS rather than by exact character position.
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
  /// selection spans, for [SelectionOverlayPainter] — empty for no selection
  /// or a collapsed one.
  List<Rect> _computeOverlayRects() {
    final selection = widget.controller.composer.selection;
    if (selection == null || selection.isCollapsed) return const [];

    final document = widget.controller.document;
    final (startPos, endPos) = selection.normalize(document);
    final startIndex = document.getNodeIndexById(startPos.nodeId);
    final endIndex = document.getNodeIndexById(endPos.nodeId);
    if (startIndex < 0 || endIndex < 0) return const [];

    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return const [];

    final perNode = <List<Rect>>[];
    for (var i = startIndex; i <= endIndex; i++) {
      final node = document.getNodeAt(i);
      if (node is! TextNode) continue;
      final paragraph = _laidOutParagraph(node.id);
      if (paragraph == null) continue;

      final length = node.text.text.length;
      final segStart = i == startIndex
          ? (startPos.nodePosition as TextNodePosition).offset
          : 0;
      final segEnd = i == endIndex
          ? (endPos.nodePosition as TextNodePosition).offset
          : length;
      if (segEnd <= segStart) continue;

      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: segStart, extentOffset: segEnd),
      );
      final lastLineTop = (i == endIndex && boxes.isNotEmpty)
          ? boxes.last.top
          : null;
      final nodeRects = <Rect>[];
      for (final box in boxes) {
        final stretchToEdge = lastLineTop == null || box.top < lastLineTop;
        final rect = stretchToEdge
            ? Rect.fromLTRB(box.left, box.top, paragraph.size.width, box.bottom)
            : box.toRect();
        final topLeft = editorBox.globalToLocal(
          paragraph.localToGlobal(rect.topLeft),
        );
        final bottomRight = editorBox.globalToLocal(
          paragraph.localToGlobal(rect.bottomRight),
        );
        if (!topLeft.dx.isFinite ||
            !topLeft.dy.isFinite ||
            !bottomRight.dx.isFinite ||
            !bottomRight.dy.isFinite) {
          continue;
        }
        nodeRects.add(Rect.fromPoints(topLeft, bottomRight));
      }
      if (nodeRects.isNotEmpty) perNode.add(nodeRects);
    }

    const seamOverlap = 0.5;
    for (var g = 0; g < perNode.length - 1; g++) {
      final current = perNode[g];
      final nextTop = perNode[g + 1].first.top;
      final last = current.last;
      if (nextTop > last.bottom) {
        current[current.length - 1] = Rect.fromLTRB(
          last.left,
          last.top,
          last.right,
          nextTop + seamOverlap,
        );
      }
    }
    return [for (final nodeRects in perNode) ...nodeRects];
  }

  // --- Multi-node selection drag handles ----------------------------------

  static const _handleKnobDiameter = 14.0;
  static const _handleHitSize = 24.0;

  /// The caret-height rect (in this editor's own coordinate space) at
  /// exactly [position].
  Rect? _caretRectAt(DocumentPosition position) {
    final nodePosition = position.nodePosition;
    if (nodePosition is! TextNodePosition) return null;
    final paragraph = _laidOutParagraph(position.nodeId);
    if (paragraph == null) return null;
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return null;

    final textPosition = TextPosition(offset: nodePosition.offset);
    final caretOffset = paragraph.getOffsetForCaret(textPosition, Rect.zero);
    final caretHeight = paragraph.getFullHeightForCaret(textPosition);
    final caretRect = Rect.fromLTWH(
      caretOffset.dx,
      caretOffset.dy,
      2,
      caretHeight,
    );
    final topLeft = editorBox.globalToLocal(
      paragraph.localToGlobal(caretRect.topLeft),
    );
    final bottomRight = editorBox.globalToLocal(
      paragraph.localToGlobal(caretRect.bottomRight),
    );
    if (!topLeft.dx.isFinite ||
        !topLeft.dy.isFinite ||
        !bottomRight.dx.isFinite ||
        !bottomRight.dy.isFinite) {
      return null;
    }
    return Rect.fromPoints(topLeft, bottomRight);
  }

  Rect _handleLocalRect(Rect caretRect, {required bool isStart}) {
    final visualHeight = caretRect.height + _handleKnobDiameter;
    final height = math.max(_handleHitSize, visualHeight);
    final left = caretRect.left - _handleHitSize / 2;
    final top = isStart ? caretRect.top - _handleKnobDiameter : caretRect.top;
    return Rect.fromLTWH(left, top, _handleHitSize, height);
  }

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

  /// The position the caret overlay is currently showing (or was last asked
  /// to show) for, and its measured rect — see [_buildCaret].
  DocumentPosition? _caretPosition;
  Rect? _caretRect;

  /// One caret, painted by the editor overlay rather than by any per-node
  /// field (there is no such field any more): solid + blinking while the
  /// editor has real focus and the selection is collapsed, or a dimmed,
  /// non-blinking "ghost" while unfocused (e.g. the +/emoji panel is open,
  /// which deliberately avoids stealing focus back so it stays open for
  /// repeated picks — see `insertEmoji`'s doc comment) — so there is still a
  /// visual sign of where the next insert will land. Respects
  /// `hideGhostCaret` in the unfocused case.
  Widget? _buildCaret(BuildContext context) {
    final focused = _editorFocusNode.hasFocus;
    if (!focused && widget.controller.hideGhostCaret) {
      _caretPosition = null;
      return null;
    }
    final selection = widget.controller.composer.selection;
    if (selection == null || !selection.isCollapsed) {
      _caretPosition = null;
      return null;
    }
    final position = selection.extent;
    if (_caretPosition != position) {
      // `_caretRectAt` reads `RenderParagraph` geometry that's still last
      // frame's — e.g. right after an emoji insert, the layout carrying the
      // new (wider) text hasn't run for this frame yet. Defer to a
      // post-frame measurement instead and paint nothing until it lands —
      // one frame of absence reads far better than a visible jump.
      _caretPosition = position;
      _caretRect = null;
      _scheduleCaretMeasurement();
      return null;
    }
    final rect = _caretRect;
    if (rect == null) return null;
    if (focused && !_caretBlinkOn) return null;
    final color = widget.cursorColor ?? Theme.of(context).colorScheme.primary;
    return Positioned(
      key: const ValueKey('quire-caret'),
      left: rect.left,
      top: rect.top,
      width: 2,
      height: rect.height,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: focused ? color : color.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }

  bool _caretMeasurementScheduled = false;

  void _scheduleCaretMeasurement() {
    if (_caretMeasurementScheduled) return;
    _caretMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretMeasurementScheduled = false;
      if (!mounted) return;
      final current = _caretPosition;
      if (current == null) return;
      final rect = _caretRectAt(current);
      // Keep measuring for as long as the caret is showing — its rect moves
      // whenever the layout under it does (the keyboard finishing its slide
      // out is the big one), and none of that rebuilds this widget on its
      // own. A post-frame callback never schedules a frame of its own, so
      // this only costs anything on frames something else was already
      // producing.
      _scheduleCaretMeasurement();
      if (rect == _caretRect) return;
      setState(() => _caretRect = rect);
    });
  }

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

  Rect? _viewportRect() {
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorBox == null || !editorBox.attached) return null;
    return editorBox.localToGlobal(Offset.zero) & editorBox.size;
  }

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

  void _updateDragSelectionAt(Offset globalPosition) {
    if (_dragBase != null) {
      _extendDocumentDragTo(globalPosition);
    } else if (_dragAnchor != null) {
      _dragSelectionHandle(globalPosition);
    }
  }

  // --- Node bookkeeping ----------------------------------------------------

  void _syncParagraphKeys() {
    final liveIds = widget.controller.document.nodesInDocumentOrder
        .whereType<TextNode>()
        .map((n) => n.id)
        .toSet();

    for (final staleId
        in _paragraphKeys.keys.where((id) => !liveIds.contains(id)).toList()) {
      _paragraphKeys.remove(staleId);
      _checklistBoxes.remove(staleId);
      if (_caretPosition?.nodeId == staleId) {
        _caretPosition = null;
        _caretRect = null;
      }
    }

    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is! TextNode) continue;
      _paragraphKeys.putIfAbsent(node.id, GlobalKey.new);
    }

    _textNodes.clear();
    for (final node in widget.controller.document.nodesInDocumentOrder) {
      if (node is TextNode) _textNodes.add(node);
    }
  }

  /// The editor just lost real focus. Deferred to a microtask rather than
  /// checked synchronously: within the same tick, focus may still land
  /// elsewhere in this editor (e.g. a fresh `requestFocus` from a tap) — or
  /// this may be the toolbar's own panel-toggle dropping focus on purpose
  /// (`QuireToolbar._togglePanel` calls `primaryFocus?.unfocus()` and relies
  /// on `focusedNodeId` staying put so it can hand focus back later). Only
  /// when the editor's own focus node genuinely doesn't have focus any more
  /// a beat later is [focusedNodeId] cleared.
  void _handleFocusLost() {
    Future.microtask(() {
      if (!mounted) return;
      if (_editorFocusNode.hasFocus) return;
      final id = widget.controller.focusedNodeId;
      if (id != null) widget.controller.clearFocusIfCurrent(id);
    });
  }

  void _maybeRequestFocus() {
    if (!mounted) return;
    final request = widget.controller.focusRequest;
    if (request == _handledFocusRequest) return;
    final id = widget.controller.focusedNodeId;
    if (id == null) return;
    _handledFocusRequest = request;
    if (!_editorFocusNode.hasFocus) {
      _editorFocusNode.requestFocus();
    } else {
      // Already focused (e.g. caret moved to another node by a tap while
      // the keyboard stayed up) — the IME connection stays open, only its
      // editing state needs refreshing.
      _inputClient.syncFromModel();
    }
    _resetCaretBlink();
  }

  /// [offset] moved to the END of the grapheme cluster of [text] it falls
  /// inside, or left alone if it's already on a cluster boundary.
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
      if (offset > start && offset < end) return end;
      if (offset <= end) return offset;
      start = end;
    }
    return offset;
  }

  // --- Keep the caret visible / DocumentInputHost -------------------------

  /// Scrolls so the current caret rect stays visible — after edits/caret
  /// moves while focused, and when the keyboard inset changes
  /// ([didChangeMetrics]), same as `EditableText` did with its own field.
  void _keepCaretVisible() {
    if (!mounted || !_editorFocusNode.hasFocus) return;
    final selection = widget.controller.composer.selection;
    if (selection == null || !selection.isCollapsed) return;
    final paragraph = _laidOutParagraph(selection.extent.nodeId);
    final nodePosition = selection.extent.nodePosition;
    if (paragraph == null || nodePosition is! TextNodePosition) return;
    final textPosition = TextPosition(offset: nodePosition.offset);
    final caretOffset = paragraph.getOffsetForCaret(textPosition, Rect.zero);
    final caretHeight = paragraph.getFullHeightForCaret(textPosition);
    paragraph.showOnScreen(
      rect: Rect.fromLTWH(caretOffset.dx, caretOffset.dy, 2, caretHeight),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeInOut,
    );
  }

  // --- DocumentInputHost (bridge to DocumentInputClient, stage 2) --------

  @override
  QuireEditorController get controller => widget.controller;

  @override
  bool get hasFocus => _editorFocusNode.hasFocus;

  @override
  Brightness get keyboardAppearance => Theme.of(context).brightness;

  @override
  void onEditingStatePushed() {
    if (!mounted) return;
    _resetCaretBlink();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keepCaretVisible();
      setState(() {});
    });
  }

  @override
  Rect? caretGlobalRect(DocumentPosition position) {
    final nodePosition = position.nodePosition;
    final paragraph = _laidOutParagraph(position.nodeId);
    if (paragraph == null || nodePosition is! TextNodePosition) return null;
    final textPosition = TextPosition(offset: nodePosition.offset);
    final caretOffset = paragraph.getOffsetForCaret(textPosition, Rect.zero);
    final caretHeight = paragraph.getFullHeightForCaret(textPosition);
    return paragraph.localToGlobal(
          Rect.fromLTWH(caretOffset.dx, caretOffset.dy, 2, caretHeight).topLeft,
        ) &
        Size(2, caretHeight);
  }

  @override
  ({Size size, Matrix4 transform})? editableGeometry(String nodeId) {
    final paragraph = _laidOutParagraph(nodeId);
    if (paragraph == null) return null;
    return (size: paragraph.size, transform: paragraph.getTransformTo(null));
  }

  @override
  void insertNewline() => widget.controller.insertNewline();

  @override
  void requestKeepCaretVisible() => _keepCaretVisible();

  @override
  DocumentPosition? resolveGlobalOffset(Offset globalOffset) =>
      _positionAt(globalOffset);

  @override
  void showContextMenu() => _showContextMenu();

  // --- Hardware keyboard ---------------------------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final selection = widget.controller.composer.selection;
    final nodeId = selection?.extent.nodeId ?? widget.controller.focusedNodeId;
    if (nodeId == null) return KeyEventResult.ignored;
    final bindings = _shortcutBindings(nodeId);
    for (final entry in bindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Moves the caret into the next (or, for `forward: false`, the previous)
  /// `TextNode` — landing at its start when arriving from the left/above, or
  /// its end when arriving from the right/below, the same convention every
  /// desktop text editor uses for Left/Right running off a paragraph's edge.
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

  void _extendSelectionTo(DocumentPosition newExtent) {
    final selection = widget.controller.composer.selection;
    final base = selection?.base ?? newExtent;
    widget.controller.changeSelection(
      DocumentSelection(base: base, extent: newExtent),
    );
  }

  void _moveCaretHorizontally(
    String nodeId, {
    required bool forward,
    required bool extend,
  }) {
    final selection = widget.controller.composer.selection;
    final node = widget.controller.document.getNodeById(nodeId);
    if (node is! TextNode) return;
    final currentOffset =
        (selection?.extent.nodePosition as TextNodePosition?)?.offset ?? 0;
    if (forward && currentOffset >= node.text.text.length) {
      _moveToAdjacentNode(nodeId, forward: true);
      return;
    }
    if (!forward && currentOffset <= 0) {
      _moveToAdjacentNode(nodeId, forward: false);
      return;
    }
    final text = node.text.text;
    var newOffset = currentOffset;
    if (forward) {
      final grapheme = text.substring(currentOffset).characters.first;
      newOffset = currentOffset + grapheme.length;
    } else {
      final grapheme = text.substring(0, currentOffset).characters.last;
      newOffset = currentOffset - grapheme.length;
    }
    final newPosition = DocumentPosition(nodeId, TextNodePosition(newOffset));
    if (extend) {
      _extendSelectionTo(newPosition);
    } else {
      widget.controller.changeSelection(
        DocumentSelection.collapsed(newPosition),
      );
    }
  }

  void _moveCaretVertically(
    String nodeId, {
    required bool down,
    required bool extend,
  }) {
    final paragraph = _laidOutParagraph(nodeId);
    final selection = widget.controller.composer.selection;
    final nodePosition = selection?.extent.nodePosition;
    if (paragraph == null || nodePosition is! TextNodePosition) return;
    final textPosition = TextPosition(offset: nodePosition.offset);
    final caretOffset = paragraph.getOffsetForCaret(textPosition, Rect.zero);
    final lineHeight = paragraph.getFullHeightForCaret(textPosition);
    final targetLocal = Offset(
      caretOffset.dx,
      caretOffset.dy + (down ? lineHeight * 1.5 : -lineHeight * 0.5),
    );
    // Within this node's own wrapped lines, or crossing into the adjacent
    // node when the target y falls outside this paragraph's own box —
    // `_positionAt` already does exactly that nearest-node fallback.
    final targetGlobal = paragraph.localToGlobal(targetLocal);
    final resolved = _positionAt(targetGlobal);
    if (resolved == null) return;
    widget.controller.requestFocus(resolved.nodeId);
    if (extend) {
      _extendSelectionTo(resolved);
    } else {
      widget.controller.changeSelection(DocumentSelection.collapsed(resolved));
    }
  }

  /// Physical-key bindings (desktop/hardware keyboard). A soft keyboard's
  /// equivalents (typing, Return, Backspace) arrive as IME deltas instead —
  /// see `document_input_client.dart` — and are handled exactly once there,
  /// never here too.
  Map<ShortcutActivator, VoidCallback> _shortcutBindings(String nodeId) {
    final bindings = <ShortcutActivator, VoidCallback>{
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
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _moveCaretHorizontally(nodeId, forward: false, extend: false),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _moveCaretHorizontally(nodeId, forward: true, extend: false),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          _moveCaretHorizontally(nodeId, forward: false, extend: true),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          _moveCaretHorizontally(nodeId, forward: true, extend: true),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          _moveCaretVertically(nodeId, down: false, extend: false),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          _moveCaretVertically(nodeId, down: true, extend: false),
      const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
          _moveCaretVertically(nodeId, down: false, extend: true),
      const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
          _moveCaretVertically(nodeId, down: true, extend: true),
    };

    // Physical Backspace/Delete are only bound on desktop. On iOS/Android, a
    // hardware-keyboard Backspace while a text input connection is focused
    // never reaches this handler at all — the OS's own text-input system
    // consumes it and reports it to us as a deletion delta instead (same as
    // a soft-keyboard backspace; see `document_input_client.dart`'s
    // `_applyDeletion`). Binding it here too would double-delete on exactly
    // that path. Desktop key events, by contrast, are NOT guaranteed to
    // reach the input connection the same way, so they need a binding of
    // their own — this mirrors `performSelector`'s own 'deleteBackward:'
    // comment (that mapping is deliberately left unbound, for the same
    // double-fire reason, on the platforms where it could ever race this).
    final isDesktop = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      TargetPlatform.iOS ||
      TargetPlatform.android ||
      TargetPlatform.fuchsia => false,
    };
    // Enter follows the same rule as Backspace. On iOS/Android a hardware
    // key event reaches this handler immediately, but the characters typed
    // just before it arrive later, as IME deltas — so splitting here would
    // land ahead of text the user typed first ("x⏎y" came out as "⏎xy",
    // seen on the iOS simulator). Unhandled, the platform delivers Enter as
    // a "\n" delta in order with the rest (see `_applyReplacement`).
    if (isDesktop) {
      bindings[const SingleActivator(LogicalKeyboardKey.enter)] =
          widget.controller.insertNewline;
      bindings[const SingleActivator(LogicalKeyboardKey.numpadEnter)] =
          widget.controller.insertNewline;
    }
    final docSelection = widget.controller.composer.selection;
    if (isDesktop && docSelection != null && !docSelection.isCollapsed) {
      bindings[const SingleActivator(LogicalKeyboardKey.backspace)] =
          widget.controller.deleteSelection;
      bindings[const SingleActivator(LogicalKeyboardKey.delete)] =
          widget.controller.deleteSelection;
    } else if (isDesktop && docSelection != null && docSelection.isCollapsed) {
      final offset =
          (docSelection.extent.nodePosition as TextNodePosition?)?.offset;
      if (offset == 0) {
        bindings[const SingleActivator(LogicalKeyboardKey.backspace)] = () =>
            widget.controller.mergeWithPrevious(nodeId);
      } else if (offset != null) {
        final node = widget.controller.document.getNodeById(nodeId);
        if (node is TextNode &&
            widget.controller.isEmojiBefore(nodeId, offset)) {
          bindings[const SingleActivator(LogicalKeyboardKey.backspace)] = () =>
              widget.controller.deleteEmojiBefore(nodeId, offset);
        } else {
          bindings[const SingleActivator(LogicalKeyboardKey.backspace)] =
              widget.controller.backspaceAtCaret;
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

  // --- Context menu ---------------------------------------------------

  final ContextMenuController _contextMenuController = ContextMenuController();

  void _hideContextMenu() {
    if (_contextMenuController.isShown) _contextMenuController.remove();
  }

  /// Shows the platform-adaptive selection toolbar (Select / Select all /
  /// Paste for a collapsed caret; Cut/Copy/Paste/Select all for a real
  /// selection) anchored at the selection — the `EditableText.showToolbar`/
  /// `contextMenuBuilder` replacement now that there is no such field to
  /// host it.
  void _showContextMenu() {
    final selection = widget.controller.composer.selection;
    if (selection == null) return;
    final document = widget.controller.document;
    final (startPos, endPos) = selection.normalize(document);
    final primaryRect = _caretRectAt(startPos) ?? _caretRectAt(endPos);
    final secondaryRect = _caretRectAt(endPos);
    final editorBox =
        _editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (primaryRect == null || editorBox == null || !editorBox.attached) return;
    final primaryGlobal = editorBox.localToGlobal(primaryRect.topCenter);
    final secondaryGlobal = editorBox.localToGlobal(
      (secondaryRect ?? primaryRect).bottomCenter,
    );

    _contextMenuController.show(
      context: context,
      contextMenuBuilder: (context) {
        final isCollapsed = selection.isCollapsed;
        final buttonItems = <ContextMenuButtonItem>[
          if (isCollapsed && _modelTextOf(startPos.nodeId).isNotEmpty)
            ContextMenuButtonItem(
              label: 'Select',
              onPressed: () {
                _hideContextMenu();
                _selectWordAt(
                  startPos.nodeId,
                  (startPos.nodePosition as TextNodePosition).offset,
                );
              },
            ),
          if (!isCollapsed)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.cut,
              onPressed: () {
                _hideContextMenu();
                widget.controller.cutSelection();
              },
            ),
          if (!isCollapsed)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                _hideContextMenu();
                widget.controller.copySelection();
              },
            ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              _hideContextMenu();
              _pasteWithLinkDetection();
            },
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: () {
              _hideContextMenu();
              widget.controller.selectAll();
              _showContextMenu();
            },
          ),
        ];
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(
            primaryAnchor: primaryGlobal,
            secondaryAnchor: secondaryGlobal,
          ),
          buttonItems: buttonItems,
        );
      },
    );
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

  void _scheduleChecklistBoxMeasurement(String nodeId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final paragraph = _laidOutParagraph(nodeId);
      final node = widget.controller.document.getNodeById(nodeId);
      final textLength = node is TextNode ? node.text.text.length : null;
      if (paragraph == null || textLength == null || textLength < 1) return;
      final boxes = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: math.min(2, textLength)),
          )
          .where((b) => b.bottom - b.top > 1)
          .toList();
      if (boxes.isEmpty) return;
      final top = boxes.map((b) => b.top).reduce(math.min);
      final bottom = boxes.map((b) => b.bottom).reduce(math.max);
      final measured = (topOffset: top, height: bottom - top);
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
    final paragraphKey = _paragraphKeys[node.id]!;
    if (node.blockType == 'listItemTask' || node.blockType == 'toggleList') {
      _scheduleChecklistBoxMeasurement(node.id);
    }
    final theme = Theme.of(context);
    final style = _styleFor(theme, node);
    final isFocused =
        _editorFocusNode.hasFocus && widget.controller.focusedNodeId == node.id;
    final composingRange = isFocused
        ? _inputClient.composingRangeFor(node.id)
        : null;

    // Keyed so tests can find/tap a specific node's rendered text block
    // without an EditableText to search for any more — see
    // `test/support/ime.dart` and `IME_REWRITE_SPEC.md` stage 4.
    final textBlock = KeyedSubtree(
      key: ValueKey('quire-node-${node.id}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: Semantics(
          textField: true,
          multiline: true,
          value: node.text.text,
          focused: isFocused,
          onTap: () => _placeCaret(node.id, node.text.text.length),
          child: RichText(
            key: paragraphKey,
            textAlign: _textAlignFor(node),
            textScaler: MediaQuery.textScalerOf(context),
            text: buildAttributedTextSpan(
              text: node.text,
              style: style,
              context: context,
              composingRange: composingRange,
            ),
          ),
        ),
      ),
    );

    // An empty callout title shows its own inline placeholder — same
    // position as the real text, painted behind it.
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
              textBlock,
            ],
          )
        : textBlock;

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
            child: row,
          ),
        );
      default:
        final container = _containerParentOf(node);
        if (container != null && container.blockType == 'callout') {
          final isLast = _isLastContainerContentNode(node, container);
          return Padding(
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

  bool _containerHasContent(TextNode container) {
    final nodes = widget.controller.document.nodesInDocumentOrder.toList();
    final index = nodes.indexWhere((n) => n.id == container.id);
    if (index == -1 || index + 1 >= nodes.length) return false;
    final next = nodes[index + 1];
    return next is TextNode && next.indent > container.indent;
  }

  Widget _buildEmptyContainerHint(BuildContext context, TextNode container) {
    final theme = Theme.of(context);
    const label = 'Empty toggle';
    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final newId = widget.controller.addToggleContent(container.id);
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

  static const _containerContentScale = 0.875;
  static const _containerBlockTypes = {'toggleList', 'callout'};

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

  double _lineHeight(BuildContext context, TextNode node) {
    final painter = _linePainter(context, node);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  double _baselineFraction(BuildContext context, TextNode node) {
    final painter = _linePainter(context, node);
    final fraction =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) /
        painter.height;
    painter.dispose();
    return fraction;
  }

  TextPainter _linePainter(BuildContext context, TextNode node) => TextPainter(
    text: TextSpan(text: 'x', style: _styleFor(Theme.of(context), node)),
    textDirection: Directionality.of(context),
  )..layout();

  Widget? _prefixFor(BuildContext context, TextNode node) {
    if (node.blockType == 'listItemTask') {
      final measured = _checklistBoxes[node.id];
      final topOffset = measured?.topOffset ?? 0.0;
      final height = measured?.height ?? _lineHeight(context, node);
      final boxHeight = math.max(height, kCheckboxMarkSize);
      final ascent = height * _baselineFraction(context, node);
      final markCentreInLine = ascent - (ascent * kCapHeightOfAscent) / 2;
      return Padding(
        padding: EdgeInsets.only(top: topOffset, right: 4),
        child: SizedBox(
          width: 24,
          height: boxHeight,
          child: Transform.translate(
            offset: Offset(0, markCentreInLine - boxHeight / 2),
            child: Transform.scale(
              scale: kCheckboxMarkScale,
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
      final measured = _checklistBoxes[node.id];
      final topOffset = measured?.topOffset ?? 0.0;
      final height = measured?.height ?? _lineHeight(context, node);
      const iconSize = 18.0;
      return Padding(
        padding: EdgeInsets.only(top: topOffset),
        child: SizedBox(
          width: 24,
          height: math.max(height, iconSize),
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
