import 'attributed_text.dart';

/// A position within a single node's content (interpretation depends on node
/// type).
abstract class NodePosition {
  const NodePosition();

  Map<String, Object?> toJson();
}

NodePosition nodePositionFromJson(Map<String, Object?> json) {
  switch (json['type']) {
    case 'text':
      return TextNodePosition(json['offset'] as int);
    case 'upstreamDownstream':
      return (json['isUpstream'] as bool)
          ? const UpstreamDownstreamNodePosition.upstream()
          : const UpstreamDownstreamNodePosition.downstream();
    default:
      throw ArgumentError('Unknown NodePosition type: ${json['type']}');
  }
}

/// Caret offset into a [TextNode]'s text.
class TextNodePosition extends NodePosition {
  const TextNodePosition(this.offset);

  final int offset;

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'offset': offset};

  @override
  bool operator ==(Object other) =>
      other is TextNodePosition && other.offset == offset;

  @override
  int get hashCode => offset.hashCode;

  @override
  String toString() => 'TextNodePosition($offset)';
}

/// Caret position relative to an atomic block node (image, HR): either just
/// before it (upstream) or just after it (downstream).
class UpstreamDownstreamNodePosition extends NodePosition {
  const UpstreamDownstreamNodePosition._(this.isUpstream);

  const UpstreamDownstreamNodePosition.upstream() : this._(true);
  const UpstreamDownstreamNodePosition.downstream() : this._(false);

  final bool isUpstream;

  @override
  Map<String, Object?> toJson() => {
    'type': 'upstreamDownstream',
    'isUpstream': isUpstream,
  };

  @override
  bool operator ==(Object other) =>
      other is UpstreamDownstreamNodePosition && other.isUpstream == isUpstream;

  @override
  int get hashCode => isUpstream.hashCode;

  @override
  String toString() => isUpstream
      ? 'UpstreamDownstreamNodePosition.upstream()'
      : 'UpstreamDownstreamNodePosition.downstream()';
}

/// A registry mapping a node's JSON `type` tag to a `fromJson` factory, so
/// new node types can register themselves without editing a switch here.
typedef NodeFromJson = DocumentNode Function(Map<String, Object?> json);

final Map<String, NodeFromJson> nodeTypeRegistry = {
  'text': TextNode.fromJson,
  'image': ImageNode.fromJson,
  'horizontalRule': HorizontalRuleNode.fromJson,
};

DocumentNode nodeFromJson(Map<String, Object?> json) {
  final type = json['type'] as String;
  final factory = nodeTypeRegistry[type];
  if (factory == null) {
    throw ArgumentError('Unknown node type in JSON: $type');
  }
  return factory(json);
}

abstract class DocumentNode {
  DocumentNode(this.id, {Map<String, Object?>? metadata})
    : metadata = metadata ?? {};

  final String id;
  Map<String, Object?> metadata;

  String get type;

  Map<String, Object?> toJson();
}

/// Paragraphs, headings, list items, blockquotes, code blocks — all
/// distinguished by `metadata['blockType']`.
class TextNode extends DocumentNode {
  TextNode({
    required String id,
    required this.text,
    Map<String, Object?>? metadata,
  }) : super(id, metadata: metadata);

  AttributedText text;

  String get blockType => metadata['blockType'] as String? ?? 'paragraph';
  int get indent => metadata['indent'] as int? ?? 0;

  @override
  String get type => 'text';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'text': text.toJson(),
    'metadata': metadata,
  };

  factory TextNode.fromJson(Map<String, Object?> json) => TextNode(
    id: json['id'] as String,
    text: AttributedText.fromJson(json['text'] as Map<String, Object?>),
    metadata: Map<String, Object?>.from(
      json['metadata'] as Map<String, Object?>? ?? const {},
    ),
  );
}

class ImageNode extends DocumentNode {
  ImageNode({
    required String id,
    required this.url,
    this.altText,
    Map<String, Object?>? metadata,
  }) : super(id, metadata: metadata);

  String url;
  String? altText;

  @override
  String get type => 'image';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'url': url,
    'altText': altText,
    'metadata': metadata,
  };

  factory ImageNode.fromJson(Map<String, Object?> json) => ImageNode(
    id: json['id'] as String,
    url: json['url'] as String,
    altText: json['altText'] as String?,
    metadata: Map<String, Object?>.from(
      json['metadata'] as Map<String, Object?>? ?? const {},
    ),
  );
}

class HorizontalRuleNode extends DocumentNode {
  HorizontalRuleNode({required String id, Map<String, Object?>? metadata})
    : super(id, metadata: metadata);

  @override
  String get type => 'horizontalRule';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'metadata': metadata,
  };

  factory HorizontalRuleNode.fromJson(Map<String, Object?> json) =>
      HorizontalRuleNode(
        id: json['id'] as String,
        metadata: Map<String, Object?>.from(
          json['metadata'] as Map<String, Object?>? ?? const {},
        ),
      );
}
