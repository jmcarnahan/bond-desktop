import 'dart:convert';

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attention.dart';
import 'conversation_state.dart';
import 'llm/embeddings_client.dart';
import 'llm/extract_task.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';

/// Extracts structured facts from one message, then refreshes its thread's
/// embedding if the thread now reads differently.
///
/// The two halves are deliberately unequal. The extraction is the work and its
/// failure is the item's failure; the embedding is an optimisation on top, and
/// an embedding server that is down must never cost a message the extraction
/// that already succeeded.
class ExtractHandler extends WorkHandler {
  static const String _source = 'email';

  final MessageStore _store;
  final LlmClient _client;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _pipeline;

  ExtractHandler(
    this._store,
    this._client,
    this._embeddings, {
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  @override
  String get kind => 'extract';

  /// Three at a time, where every other kind is one.
  ///
  /// Extraction is the one queue whose items are genuinely independent: each
  /// reads one message and writes that message's own row. The two things it
  /// touches beyond that survive being reordered — the bucket filing is
  /// guarded to the thread's newest inbound message, the embedding refresh is
  /// last-writer-wins exactly as it already was under the serial drain (the
  /// stored hash makes a repeat free, so the next extraction self-heals it),
  /// and the storyline requeue is idempotent by construction (`requeueWork`
  /// on a key that is already queued is the same row).
  ///
  /// Three and not more: it is the batch the fast server is started with slots
  /// for (`FAST_SLOTS`), and past a small batch each individual request slows
  /// down enough that the first result takes longer to reach the screen.
  @override
  int get concurrency => 3;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    await _pipeline.noteExtract(source, id, state: 'running');

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to extract
    // and nothing wrong — the item is done, not failed. The worker would
    // otherwise write `ok` on a row where no model ran, so it is told
    // `skipped` instead.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      await _pipeline.noteExtract(source, id, state: 'skipped');
      return;
    }

    // Queued, then GATED before the worker reached it. Extraction is enqueued
    // at sync time, while every fresh message is still `pending`; triage runs
    // first and flips newsletters, no-reply senders and auto-generated mail to
    // `skipped`. Honouring that verdict here is what keeps a newsletter from
    // costing a model call, growing an embedding, and — since one sender's
    // newsletters are all alike — clustering into a junk storyline
    // suggestion. The `teams_source` exception is legacy tolerance: chats are
    // triaged like mail now, but a row stored before that change is `skipped`
    // for a reason no judgement stands behind, and a straggler the sync's
    // backfill window missed should still get its facts pulled.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      await _pipeline.noteExtract(source, id, state: 'skipped');
      return;
    }

    final result = await runTask(
      _client,
      const ExtractTask(),
      ExtractionInput(Message.fromRow(row), DateTime.now()),
      // Zero, not the default: the same email must yield the same facts twice,
      // or a re-extraction would move a conversation between clusters for no
      // reason a human could see.
      temperature: 0,
    );
    await _store.writeExtraction(source, id, jsonEncode(result.toJson()));
    // After the write and before the two optional passes below: the facts are
    // stored, so the stage is done however the bucket filing and the embedding
    // refresh go.
    await _pipeline.noteExtract(source, id, state: 'done');
    // Enough of the answer to make the activity row readable without opening
    // the extraction itself. Five topics, because the row is one line.
    _log.note({
      'intent': result.intent,
      'importance': result.importance,
      'topics': result.topics.take(5).toList(),
      if (result.project.isNotEmpty) 'project': result.project,
    });

    await _fileBucket(source, row, result);
    await _refreshCard(source, row, result);
  }

  /// Files this message's thread into Later, or out of it, the moment the model
  /// has read it.
  ///
  /// The scoring sweep would reach the same answer on the next list load, so
  /// this is purely about when: extraction runs behind a queue that can be
  /// minutes deep, and without this a message would appear in the inbox, sit
  /// there, and then jump to Later while the user was reading the list. Filing it
  /// as the fact lands means the row is only ever drawn once, where it belongs.
  ///
  /// It shares [bucketFor] with the sweep rather than reimplementing the rule —
  /// two copies would drift, and the symptom would be a thread that changes
  /// bucket depending on which pass ran last.
  Future<void> _fileBucket(
    String source,
    Map<String, Object?> row,
    ExtractionResult result,
  ) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
    if (conversation == null) return;

    // Only the thread's newest inbound message gets to file it. The queue
    // drains newest-first but a backlog can still hand this handler a month-old
    // message, and letting that one decide would file the thread on what its
    // conversation stopped being about.
    final receivedAt = row['received_at'] as String?;
    if (receivedAt == null ||
        receivedAt != conversation['last_inbound_at'] as String?) {
      return;
    }

    // A bucket a person asked for is never re-decided here. `sender_pref` and
    // `user` are both written by an explicit correction, and the automatic pass
    // does not get to overrule someone by arriving later.
    final stored = await _store.getConversationAi(source, key);
    final reason = stored?['bucket_reason'] as String?;
    if (reason == 'user' || reason == 'sender_pref') return;

    final senderPref =
        await _store.getSenderPref(row['from_address'] as String? ?? '');
    final bucket = bucketFor(
      senderPref: senderPref,
      intent: result.intent,
      importance: result.importance,
      needsReply: (conversation['state'] as String?) == 'needs_reply',
    );

    if (bucket != null) {
      await _store.setConversationBucket(
        source,
        key,
        bucket: bucket,
        reason: bucketReasonFor(senderPref),
      );
    } else if (reason == 'low_value') {
      // The thread earned its way back: a message that is no longer low-value
      // clears the guess this pass made last time, and nothing else.
      await _store.setConversationBucket(source, key, bucket: null);
    }
  }

  /// Re-embeds this message's thread, if what the thread says about itself
  /// actually changed.
  ///
  /// Every way this can fail returns quietly, and that is a constraint rather
  /// than a preference: the extraction is already stored by the time it runs,
  /// and an item marked failed here would be re-run — spending a model call to
  /// redo work that succeeded — to retry an optimisation. Nothing below may
  /// throw.
  ///
  /// The storyline requeue is the part that has to survive an embedding server
  /// being down. It used to sit behind a successful embed, which made a
  /// missing server a silent DROP: no vector, no requeue, and the thread was
  /// never considered for a storyline again until something else happened to
  /// re-extract it. Now an unreachable server still queues the work and lets
  /// the storyline pass park on it — which is the one thing that gets the
  /// thread looked at again once `make embed` is running.
  Future<void> _refreshCard(
    String source,
    Map<String, Object?> row,
    ExtractionResult result,
  ) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
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
    final stored = await _store.getConversationAi(source, key);
    if (stored != null && stored['embedded_hash'] == hash) return;

    final embedded = await _embeddings.embedResult(card);
    final vector = embedded.vector;
    if (vector == null) {
      // Either way the old embedding and the old hash are left alone, so the
      // next pass tries again. What differs is whether there is anything to
      // try FOR: a server that is not running will have a vector for this
      // thread later, so the storyline pass is queued now and parks until it
      // does; a server that answered nonsense will answer the same nonsense
      // next time, and queueing a pass that can only park is worse than
      // nothing.
      if (embedded.outcome == EmbedOutcome.unavailable) {
        _log.note({'embed': 'unavailable'});
        await _store.requeueWork('storyline', source, key);
      } else {
        _log.note({'embed': 'rejected'});
      }
      return;
    }

    await _store.upsertConversationAi(
      source,
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: hash,
      embedModel: EmbeddingsClient.modelTag,
    );

    // Only after a vector actually landed, and a REQUEUE rather than an
    // enqueue: what a thread should be grouped with is a function of its
    // embedding, so every time that changes the answer may change with it.
    // `enqueueWork` would ignore the row after the first time it ran, which
    // would mean each thread is only ever considered on its first message.
    await _store.requeueWork('storyline', source, key);
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
