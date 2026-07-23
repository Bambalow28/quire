import 'attributed_text.dart';
import 'document.dart';
import 'nodes.dart';

class DocumentPosition {
  const DocumentPosition(this.nodeId, this.nodePosition);

  final String nodeId;
  final NodePosition nodePosition;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'nodePosition': nodePosition.toJson(),
  };

  factory DocumentPosition.fromJson(Map<String, Object?> json) =>
      DocumentPosition(
        json['nodeId'] as String,
        nodePositionFromJson(json['nodePosition'] as Map<String, Object?>),
      );

  @override
  bool operator ==(Object other) =>
      other is DocumentPosition &&
      other.nodeId == nodeId &&
      other.nodePosition == nodePosition;

  @override
  int get hashCode => Object.hash(nodeId, nodePosition);

  @override
  String toString() => 'DocumentPosition($nodeId, $nodePosition)';
}

class DocumentSelection {
  const DocumentSelection({required this.base, required this.extent});

  DocumentSelection.collapsed(DocumentPosition position)
    : base = position,
      extent = position;

  final DocumentPosition base;
  final DocumentPosition extent;

  bool get isCollapsed => base == extent;

  Map<String, Object?> toJson() => {
    'base': base.toJson(),
    'extent': extent.toJson(),
  };

  factory DocumentSelection.fromJson(Map<String, Object?> json) =>
      DocumentSelection(
        base: DocumentPosition.fromJson(json['base'] as Map<String, Object?>),
        extent: DocumentPosition.fromJson(
          json['extent'] as Map<String, Object?>,
        ),
      );

  DocumentSelection collapseDownstream(MutableDocument document) {
    final (_, end) = normalize(document);
    return DocumentSelection.collapsed(end);
  }

  DocumentSelection collapseUpstream(MutableDocument document) {
    final (start, _) = normalize(document);
    return DocumentSelection.collapsed(start);
  }

  /// Returns (start, end) in document order, determined by node order in
  /// [document] and, within a single node, by offset.
  (DocumentPosition, DocumentPosition) normalize(MutableDocument document) {
    if (base.nodeId == extent.nodeId) {
      final baseOffset = _offsetOf(base.nodePosition);
      final extentOffset = _offsetOf(extent.nodePosition);
      if (extentOffset < baseOffset) {
        return (extent, base);
      }
      return (base, extent);
    }
    final baseIndex = document.getNodeIndexById(base.nodeId);
    final extentIndex = document.getNodeIndexById(extent.nodeId);
    if (extentIndex < baseIndex) {
      return (extent, base);
    }
    return (base, extent);
  }

  int _offsetOf(NodePosition position) {
    if (position is TextNodePosition) return position.offset;
    if (position is UpstreamDownstreamNodePosition) {
      return position.isUpstream ? 0 : 1;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is DocumentSelection &&
      other.base == base &&
      other.extent == extent;

  @override
  int get hashCode => Object.hash(base, extent);

  @override
  String toString() => 'DocumentSelection(base: $base, extent: $extent)';
}

/// Holds the current selection and the styles armed for the next keystroke.
/// Mutated only by [Editor].
class DocumentComposer {
  DocumentComposer({this.selection});

  DocumentSelection? selection;
  Set<Attribution> composingAttributions = {};
}
