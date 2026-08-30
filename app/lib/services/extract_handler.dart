import 'dart:convert';

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'ai_worker.dart';
import 'conversation_state.dart';
import 'llm/embeddings_client.dart';
import 'llm/extract_task.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';

/// Extracts structured facts from one message, then refreshes its thread's
/// embedding if the thread now reads differently.
///
/// The two halves are deliberately unequal. The extraction is the work and its
/// failure is the item's failure; the embedding is an optimisation on top, and
/// an embedding server that is down must never cost a message the extraction
/// that already succeeded.
class ExtractHandler implements WorkHandler {
  static const String _source = 'email';

  final MessageStore _store;
  final LlmClient _client;
  final EmbeddingsClient _embeddings;

  ExtractHandler(this._store, this._client, this._embeddings);

  @override
  String get kind => 'extract';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    final row = _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to extract
    // and nothing wrong — the item is done, not failed.
    if (row == null) return;

    final result = await runTask(
      _client,
      const ExtractTask(),
      ExtractionInput(Message.fromRow(row), DateTime.now()),
      // Zero, not the default: the same email must yield the same facts twice,
      // or a re-extraction would move a conversation between clusters for no
      // reason a human could see.
      temperature: 0,
    );
    _store.writeExtraction(source, id, jsonEncode(result.toJson()));

    await _refreshCard(source, row, result);
  }

  /// Re-embeds this message's thread, if what the thread says about itself
  /// actually changed.
  ///
  /// Every way this can fail returns quietly. The extraction is already stored
  /// by the time it runs, and an item marked failed here would be re-run —
  /// spending a model call to redo work that succeeded — to retry an
  /// optimisation.
  Future<void> _refreshCard(
    String source,
    Map<String, Object?> row,
    ExtractionResult result,
  ) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = _store.getConversationRow(source, key);
    if (conversation == null) return;

    final card = buildConversationCard(
      subject: stripReFw(conversation['subject'] as String?),
      participants: _participants(conversation['participants_json']),
      topics: result.topics,
      // The triage summary, when there is one. It is the only sentence on the
      // row written to describe the thread rather than to label it.
      summary: row['summary'] as String?,
    );
    final hash = cardHash(card);

    // The whole reason a hash is stored: re-extracting the same thread's tenth
    // message must not spend an embedding call to arrive at the same vector.
    final stored = _store.getConversationAi(source, key);
    if (stored != null && stored['embedded_hash'] == hash) return;

    final vector = await _embeddings.embed(card);
    // Server down, or an answer that did not parse. Leave the old embedding
    // and the old hash alone so the next pass tries again, and say nothing:
    // this thread simply has no vector yet, which every reader of the column
    // already has to handle.
    if (vector == null) return;

    _store.upsertConversationAi(
      source,
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: hash,
      embedModel: EmbeddingsClient.modelTag,
    );
  }

  /// Display names, falling back to the address — what a human would call the
  /// other people on the thread.
  static List<String> _participants(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final names = <String>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final name = entry['name'] as String?;
      final display = (name != null && name.isNotEmpty)
          ? name
          : (entry['email'] as String? ?? '');
      if (display.isNotEmpty) names.add(display);
    }
    return names;
  }
}

/// The text a conversation is embedded from.
///
/// Always four segments joined by ` | `, empty ones included: the shape is
/// fixed so the same thread produces the same card twice, which is what makes
/// [cardHash] a usable "has anything changed" test. Order runs from most to
/// least stable — subject, who is on it, what it is about, what was last said
/// — so a passing remark moves the vector less than a change of topic.
String buildConversationCard({
  required String? subject,
  required List<String> participants,
  required List<String> topics,
  required String? summary,
}) =>
    [
      subject?.trim() ?? '',
      participants.join(', '),
      topics.join(', '),
      summary?.trim() ?? '',
    ].join(' | ');

/// A cheap content hash: the card's length, then FNV-1a over its UTF-8 bytes.
///
/// FNV-1a and not SHA-256 because nothing adversarial rides on this. It is
/// compared only against the previous card of the SAME conversation, and the
/// cost of the one-in-2^64 collision is a stale embedding on one thread. The
/// length prefix is free and catches the truncations a hash alone would not
/// make obvious in a database dump.
String cardHash(String card) {
  const int prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(card)) {
    hash ^= byte;
    // Dart's int is 64-bit two's complement on this platform and multiplication
    // wraps, which is exactly the arithmetic FNV-1a specifies.
    hash = hash * prime;
  }
  final high = (hash >> 32) & 0xFFFFFFFF;
  final low = hash & 0xFFFFFFFF;
  return '${card.length}-'
      '${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}
