import 'package:flutter/foundation.dart' show immutable;

/// What `message_ai.extraction_json` holds for one message, decoded.
///
/// Deliberately not stored as columns — see `MessageStore.writeExtraction`.
/// [toJson] is the stored form and [fromJson] reads it back, so the two must
/// stay each other's inverse.
///
/// Since the decision-model round the text stage writes `{topics, project,
/// intent, importance}`: topics and project from `MessageTextTask`, intent and
/// importance from the decision model. [evidence], [people] and
/// [organizations] were the retired extraction call's; they are read back from
/// rows an older build wrote (the Why panel still shows them there) and are
/// left OUT of [toJson] when empty, so a new row never claims to have asked.
@immutable
class ExtractionResult {
  /// The retired extraction call's one-sentence "what is this about". Empty on
  /// every row written since the text stage replaced it.
  final String evidence;

  final List<String> topics;

  /// Old rows only, like [evidence].
  final List<String> people;

  /// Old rows only, like [evidence].
  final List<String> organizations;

  /// A short stable label for the project this message belongs to. Empty when
  /// the message belongs to none.
  final String project;

  final String intent;
  final String importance;

  const ExtractionResult({
    this.evidence = '',
    required this.topics,
    this.people = const [],
    this.organizations = const [],
    required this.project,
    required this.intent,
    required this.importance,
  });

  /// Nothing claimed, and the quiet middle for both labels.
  factory ExtractionResult.fallback() => const ExtractionResult(
        topics: [],
        project: '',
        intent: 'fyi',
        importance: 'normal',
      );

  factory ExtractionResult.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? raw) => [
          for (final entry in raw is List ? raw : const []) entry.toString(),
        ];
    return ExtractionResult(
      evidence: json['evidence'] as String? ?? '',
      topics: strings(json['topics']),
      people: strings(json['people']),
      organizations: strings(json['organizations']),
      project: json['project'] as String? ?? '',
      intent: json['intent'] as String? ?? 'fyi',
      importance: json['importance'] as String? ?? 'normal',
    );
  }

  Map<String, dynamic> toJson() => {
        if (evidence.isNotEmpty) 'evidence': evidence,
        'topics': topics,
        if (people.isNotEmpty) 'people': people,
        if (organizations.isNotEmpty) 'organizations': organizations,
        'project': project,
        'intent': intent,
        'importance': importance,
      };
}
