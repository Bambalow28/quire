import 'package:flutter/material.dart';
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
}

/// Stage 1 placeholder: owns nothing yet. Real IME wiring (one
/// `DeltaTextInputClient`/`TextInputConnection` for the whole editor) lands
/// in stage 2 — see the spec this rewrite follows
/// (`IME_REWRITE_SPEC.md`, "Stage 2 — one DeltaTextInputClient").
class DocumentInputClient {
  DocumentInputClient({required this.host});

  final DocumentInputHost host;

  void attach() {}

  void detach() {}

  void syncFromModel() {}

  /// The IME's current composing range for [nodeId], in that node's own
  /// model coordinates — `null` outside stage 2.
  TextRange? composingRangeFor(String nodeId) => null;

  void dispose() {}
}
