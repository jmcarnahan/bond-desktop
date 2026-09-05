import 'dart:convert';

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attention.dart';
import 'conversation_state.dart';
import 'embed_handler.dart';
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
      // Drafting is enqueued from the end of this method, so an early return
      // is also the last word on whether a reply will ever be suggested. The
      // stage is closed here rather than left `pending`, or the bar would wait
      // forever on work nothing is going to queue.
      await _pipeline.noteDraft(source, id, state: 'skipped');
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
      await _pipeline.noteDraft(source, id, state: 'skipped');
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
    await _embedMessage(source, row);
    await _queueDraft(source, id, row);
  }

  /// Puts this message in front of the drafting model, or closes its draft
  /// stage without one.
  ///
  /// [asksForAReply] is a PRE-GATE and nothing more. The verdict that decides
  /// whether a suggestion is written comes from the 27B behind this queue,
  /// which reads the whole conversation; this only decides which messages are
  /// worth asking about — cost control, so a two-hundred-message backlog does
  /// not spend hours of the big model's time on newsletters. If it proves too
  /// tight, this is the line to widen: the false negatives are silent, and a
  /// message it drops here is never drafted for at all.
  ///
  /// A message it drops is `skipped`, not left waiting: no work row will ever
  /// be written for it, and a bar that waited would wait forever.
  Future<void> _queueDraft(
    String source,
    String id,
    Map<String, Object?> row,
  ) async {
    if (asksForAReply(row)) {
      await _store.enqueueWork('draft', source, id);
      return;
    }
    await _pipeline.noteDraft(source, id, state: 'skipped');
  }

  /// Gives this ONE message its search vector, while the row is already in
  /// hand.
  ///
  /// The fast path for search: by the time a message has been extracted it is
  /// also findable, with no second queue having had to drain first. It carries
  /// [_refreshCard]'s hard constraint — the extraction is already stored, so
  /// nothing here may throw and turn a succeeded item into a retried one — and
  /// drops one of its habits: there is no requeue. The `embed_message` queue
  /// enqueued at sync time IS the healing path, and it parks on the same
  /// unreachable server until `make embed` is running, so queueing anything
  /// from here would only be a second name for the same wait.
  ///
  /// The summary it embeds is TRIAGE's, not this handler's extraction output.
  /// That is deliberate: the card has to be buildable from the message row
  /// alone, or [EmbedHandler] could not produce the same card without
  /// re-running an extraction to get it.
  Future<void> _embedMessage(String source, Map<String, Object?> row) async {
    final outcome = await embedMessageRow(_store, _embeddings, source, row);
    if (outcome == MessageEmbedOutcome.unavailable) {
      _log.note({'message_embed': 'unavailable'});
    }
    if (outcome == MessageEmbedOutcome.rejected) {
      _log.note({'message_embed': 'rejected'});
    }
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

/// Whether a stored message looks, on its own row, like something the user
/// might have to answer.
///
/// Five signals, and any one of them is enough: the needs-you stage read the
/// message and called it the user's to answer, the sender is waiting, the
/// reader has to do something, the message is loud, or it names a date. Read
/// off the row rather than re-judged, because the point is to be cheap — the
/// expensive judgement is the model call this gate decides whether to spend.
///
/// The first is the odd one out: the other four are the fast triage's fields
/// ABOUT the message, while `needs_you_verdict` is the needs-you stage's answer
/// about the message as a whole. It is on the row here because NeedsYouHandler
/// is registered ahead of ExtractHandler in the worker precisely so its verdict
/// is written before this reads it, and it is what puts a message in front of
/// the drafting model when triage saw no reply cue at all. NULL — the handler
/// errored, or never ran — and 0 change nothing, and the gate degrades to
/// exactly the four-signal shape it had.
///
/// Outbound mail answers false. The user's own message needs no reply from
/// them, and extraction only ever sees inbound rows anyway, so this is a guard
/// rather than a case.
///
/// The flags come back as INTEGERs — sqlite has no bool, and a STRICT column
/// holds 0 or 1 — so each is compared against 1 rather than trusted to be
/// truthy.
bool asksForAReply(Map<String, Object?> row) {
  if (row['direction'] != 'inbound') return false;
  return row['needs_you_verdict'] == 1 ||
      row['reply_expected'] == 1 ||
      row['needs_action'] == 1 ||
      row['urgency'] == 'urgent' ||
      row['urgency'] == 'high' ||
      (row['deadline'] as String?)?.isNotEmpty == true;
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

/// How much of a message body reaches its embedding.
///
/// A vector is an average, and averaging over four thousand characters of
/// quoted thread, signature and legal footer produces a vector about email in
/// general rather than about this message. The first 1500 characters are where
/// a person says the thing they wrote to say; everything past that is usually
/// what someone else already said.
const int messageCardBodyCap = 1500;

/// The text ONE MESSAGE is embedded from — the search corpus, where
/// [buildConversationCard] builds the clustering corpus.
///
/// Always four segments joined by ` | `, empty ones included, for the same
/// reason the conversation card is: a fixed shape means the same message
/// produces the same card twice, which is what makes [cardHash] a usable "has
/// anything changed" test. Order runs from most to least stable — subject, who
/// sent it, what triage said it was, what it actually says — so a long body
/// cannot drown out the two lines that identify the message.
String buildMessageCard({
  required String? subject,
  required String sender,
  required String? summary,
  required String? body,
}) {
  final text = (body ?? '').trim();
  final clipped =
      text.length > messageCardBodyCap ? text.substring(0, messageCardBodyCap) : text;
  return [
    stripReFw(subject),
    sender.trim(),
    summary?.trim() ?? '',
    clipped,
  ].join(' | ');
}

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
