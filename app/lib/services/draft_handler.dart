import 'dart:convert';
import 'dart:typed_data';

import '../data/message_store.dart';
import '../models/draft_provenance.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attachments/attachment_markers.dart';
import 'attachments/attachment_retriever.dart';
import 'context/context_retriever.dart';
import 'llm/draft_task.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/reply_decision_task.dart';
import 'pipeline_progress.dart';

/// Decides whether ONE message needs an answer, and writes one when it does.
///
/// `entity_id` is a source message id — this queue works at the grain of the
/// thing being answered, because that is what a suggestion is about. A thread
/// that gets a second question gets a second decision and a second draft
/// rather than living with the answer to the first.
///
/// Two model calls, and the first is the point. The fast triage's
/// `reply_expected` is a guess made on one message in isolation, and the
/// enqueue in front of this handler treats it as nothing more than a coarse
/// pre-gate; this is where the model that will do the writing reads the actual
/// conversation and says whether writing is warranted. A `no` costs one small
/// call and stores nothing.
///
/// It only ever writes to the `drafts` table. Nothing in this class — and
/// nothing this class calls — touches Microsoft Graph: a suggestion is text in
/// sqlite until a person presses Send, and keeping the model's output on this
/// side of that line is what makes "never auto-send" a property of the code
/// rather than a promise in a comment.
class DraftHandler extends WorkHandler {
  static const String _source = 'email';

  /// A reply is longer than a label. The default 512 is enough to truncate a
  /// 150-word draft mid-sentence, and a cut-off draft is grammar-valid, so
  /// nothing downstream would notice. The answer now carries the two short
  /// options as well as the long form, so the ceiling went up with it.
  static const int _maxTokens = 1536;

  /// A yes/no and one sentence. Room for the sentence to run long, and no room
  /// for the model to start drafting inside the decision.
  static const int _decisionMaxTokens = 256;

  /// Two past replies, clipped: a tone sample, not a second thread.
  static const int _styleExamples = 2;
  static const int _styleExampleCap = 750;

  final MessageStore _store;
  final LlmClient _client;
  final ActivityLog _log;

  /// Finds the passages of this thread's documents worth quoting, or null in a
  /// build that has none.
  ///
  /// Nullable rather than defaulted so a handler built without one drafts
  /// exactly as it did before this existed — which is what every test that
  /// predates retrieval, and any future caller with no embedder, gets.
  final AttachmentRetriever? _attachments;

  /// What the owner's own registered directories know about this message, or
  /// null in a build with none. Nullable on [_attachments]' reasoning: a
  /// handler built without one drafts exactly as it did before this existed.
  final ContextRetriever? _contextDirs;

  /// The embedder the two retrievers below are searched with, so that the
  /// message being answered is turned into a vector ONCE for both of them.
  ///
  /// The handler holds it rather than either retriever, because neither of
  /// them can know the other is about to ask the same question. Null leaves
  /// each retriever to build its own — which is what a handler assembled
  /// without an embedder, and every test that predates this, gets.
  final EmbeddingsClient? _embeddings;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _progress;

  DraftHandler(
    this._store,
    this._client, {
    ActivityLog? activityLog,
    this._attachments,
    // NAMED `contextDirs` rather than taken as `this._contextDirs`: around
    // this handler `context`, `contextDirs` and `contextJson` are three
    // different things, and the call site reads better saying which one it is
    // handing over.
    ContextRetriever? contextDirs,
    EmbeddingsClient? embeddings,
    this._progress = const PipelineProgress.disabled(),
  })  :
        // ignore: prefer_initializing_formals
        _contextDirs = contextDirs,
        // ignore: prefer_initializing_formals
        _embeddings = embeddings,
        _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'draft';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    await _progress.noteDraft(source, id, state: 'running');

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to answer
    // and nothing wrong — the item is done, not failed.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    // The user's own mail. Extraction only ever enqueues inbound messages, so
    // this is the guard rather than a case — and it is here for the reason
    // every guard in this handler is: the queue can hand over a row that has
    // changed since it was written.
    if (row['direction'] != 'inbound') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'outbound'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    // Queued, then GATED before the worker reached it — the [ExtractHandler]
    // exit, at the one other point in the pipeline that can be reached after
    // triage has changed its mind. Answering a newsletter is the waste this
    // stops. The `teams_source` exception is the same legacy tolerance: a chat
    // stored before chats were triaged is `skipped` for a reason no judgement
    // stands behind.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    // Already answered. Two enqueues racing to the same message is benign —
    // the first one's suggestion is as good as the second's — and returning
    // here spends no model time discovering that.
    if (await _store.getDraftForMessage(source, id) != null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'already_drafted'});
      await _progress.noteDraft(source, id, state: 'done');
      return;
    }

    var replyTo = Message.fromRow(row);
    final key = row['conversation_key'] as String? ?? '';
    // Hydrated only when the row says there is something to hydrate —
    // `loadThread` does this for a whole thread; a single-row read has to ask.
    if (row['has_attachments'] == 1) {
      replyTo = replyTo.withAttachments(
        await _store.attachmentRefsFor(source, id, conversationKey: key),
      );
    }
    // The thread AS IT WAS when this message landed. Cutting it off here is
    // what makes the answer to a message the same answer however far behind
    // the queue was when it got here — and it keeps the model from replying to
    // something that was said after the message it is answering.
    final thread = await _store.loadThread(
      key,
      sources: [source],
      untilIso: row['received_at'] as String? ?? row['created_at'] as String?,
    );
    final context = [
      for (final message in thread)
        if (message.id != replyTo.id) message,
    ];
    final aboutMe = await _store.getPref(aboutMeKey);

    // ONE retrieval, read by both model calls below. The decision and the
    // draft are asking about the same message on the same thread, so a second
    // pass would be a second embedding call for an answer that cannot come
    // back different.
    //
    // The thread's ids are passed rather than left to be read: this thread is
    // the thread AS IT WAS when the message landed, and a document attached
    // after it must not be quoted in the answer to it.
    //
    // And ONE embedding, for the same reason again. The two retrievals below
    // search two different indexes with the SAME question — what is this
    // message about — and each of them would otherwise embed the card itself
    // when the queue has not reached it yet. The closure is memoised on the
    // future rather than the value, so two awaits of it are one POST even
    // when they overlap; it is passed rather than called here, because each
    // retriever's cheap `LIMIT 1` guard stands in front of it and a thread
    // with neither documents nor directories must still cost nothing.
    final vector = _queryVectorFor(source, id);

    final excerpts = await _excerptsFor(
      source,
      key,
      id,
      threadMessageIds: [for (final message in thread) message.id],
      pinnedFirst: _pinnedIdsFrom(item['payload_json']),
      queryVector: vector,
    );

    // ONE pack, for the same reason there is one retrieval: both calls below
    // ask about the same message on the same thread, and the directories have
    // not changed between the two.
    final consultFirst = _contextFileIdsFrom(item['payload_json']);
    final consulted = consultFirst.length;
    final pack = await _packFor(
      source,
      key,
      id,
      queryVector: vector,
      consultFirst: consultFirst,
    );

    final decision = await runTask(
      _client,
      const ReplyDecisionTask(),
      ReplyDecisionInput(
        context: context,
        message: replyTo,
        aboutMe: aboutMe,
        attachmentExcerpts: excerpts,
        directories: pack,
        now: DateTime.now(),
      ),
      // Zero, like every judgement in this app: the same message must get the
      // same verdict twice, or a re-drain would offer a suggestion the last
      // one did not.
      temperature: 0,
      maxTokens: _decisionMaxTokens,
    );

    if (!decision.needsReply) {
      // A real END state, not a failure: the model read the conversation and
      // said nobody is waiting. The reason is recorded so a person looking at
      // the activity row can see what it read.
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'no_reply_needed', 'why': decision.reason});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    final result = await runTask(
      _client,
      const DraftTask(),
      DraftInput(
        thread: thread,
        replyTo: replyTo,
        // Mail only. `recentOutboundToSender` matches on `to_json`, which a
        // chat never writes ('[]'), so the skip only makes explicit what the
        // LIKE would answer anyway — and a chat needs it less: the thread tail
        // already carries the owner's own chat voice, turn by turn.
        styleExamples: source == 'email'
            ? await _styleExamplesFor(source, replyTo.fromAddress)
            : const [],
        storylineSummary: await _storylineSummaryFor(source, key),
        aboutMe: aboutMe,
        attachmentExcerpts: excerpts,
        directories: pack,
        now: DateTime.now(),
      ),
      // Zero, like extraction: pressing Regenerate should change the draft
      // because the thread changed, not because the sampler rolled differently.
      temperature: 0,
      maxTokens: _maxTokens,
    );

    if (result.replyBody.isEmpty) {
      // A retryable failure, deliberately. An empty answer from a local model
      // is usually a one-off, and the worker's retry-once policy is exactly the
      // right response — writing the blank draft instead would put an empty
      // composer in front of the user as though it were a suggestion.
      throw const LlmFormatException('The local model drafted an empty reply.');
    }

    // What this reply was written from, distinct and in ranked order. Three
    // passages of one contract are one document to a reader, and three
    // passages of one analysis are three places in one file — so the
    // documents collapse by name and the directory files collapse by the
    // triple that names a place.
    final documents = <String>[];
    for (final excerpt in excerpts) {
      final name = excerpt.name.isEmpty ? 'a file' : excerpt.name;
      if (!documents.contains(name)) documents.add(name);
    }
    final files = <({String dir, String path, String locator, int? fileId})>[];
    final directoryFiles = <String>[];
    for (final excerpt in pack.excerpts) {
      final entry = (
        dir: excerpt.dirName,
        path: excerpt.relPath,
        locator: excerpt.locator,
        // The row id, so the composer's chip can open the file rather than
        // only name it.
        fileId: excerpt.fileId,
      );
      if (!files.contains(entry)) files.add(entry);
      if (!directoryFiles.contains(excerpt.relPath)) {
        directoryFiles.add(excerpt.relPath);
      }
    }
    final provenance = DraftProvenance(
      documents: documents,
      // A pack that rendered nothing named nothing, whatever its own list
      // says. The retriever is the layer that decides which directories
      // contributed and it already answers that way; this is the belt to its
      // braces, because the one thing the caption must never do is tell a
      // person their reply was drafted from a project the model never read.
      directories: pack.isEmpty ? const [] : pack.directories,
      files: files,
      skills: pack.skills,
    );

    await _store.upsertDraft(
      source: source,
      conversationKey: key,
      replyToMessageId: replyTo.id,
      body: result.replyBody,
      evidence: result.evidence,
      // Null rather than `[]`: "the model offered no short replies" and "the
      // options were read and there were none" are the same thing to every
      // reader, and one of the two spellings is shorter.
      optionsJson: result.options.isEmpty
          ? null
          : jsonEncode([
              for (final option in result.options)
                {'stance': option.stance, 'body': option.body},
            ]),
      // The inventory of what went into the prompt, stored WITH the draft
      // rather than only in the activity row — the composer's caption names
      // what was read, and a caption assembled from the activity log would be
      // a join against a table that gets pruned.
      contextJson: provenance.isEmpty ? null : provenance.encode(),
      status: 'suggested',
    );
    await _progress.noteDraft(source, id, state: 'done');
    _log.note({
      'chars': result.replyBody.length,
      // The activity row keeps its own copy, which is not a duplicate of the
      // stored provenance: a person reading the log is asking what the app
      // DID, and the row has to answer after the draft it belongs to has been
      // sent, edited or thrown away.
      if (consulted > 0) 'consulted': consulted,
      if (provenance.documents.isNotEmpty) 'documents': provenance.documents,
      if (provenance.directories.isNotEmpty)
        'directories': provenance.directories,
      if (directoryFiles.isNotEmpty) 'directory_files': directoryFiles,
      if (pack.skills.isNotEmpty) 'skills': pack.skills,
    });
  }

  /// The passages the two prompts read, or none.
  ///
  /// Every failure here is swallowed on purpose. Retrieval is what makes a
  /// draft better; it is not what makes one possible, and an embedding server
  /// that fell over between the thread load and this call must cost the
  /// citations rather than the reply. The reason is noted so the activity row
  /// says why a draft that should have quoted a file did not.
  Future<List<AttachmentExcerpt>> _excerptsFor(
    String source,
    String key,
    String id, {
    required List<String> threadMessageIds,
    required List<String> pinnedFirst,
    Future<Uint8List?> Function()? queryVector,
  }) async {
    final retriever = _attachments;
    if (retriever == null) return const [];
    try {
      return await retriever.excerptsFor(
        source: source,
        conversationKey: key,
        replyToId: id,
        threadMessageIds: threadMessageIds,
        storylineIds: await _store.storylineIdsFor(source, key),
        pinnedFirst: pinnedFirst,
        queryVector: queryVector,
      );
    } catch (e) {
      _log.note({'excerpts_error': '$e'});
      return const [];
    }
  }

  /// What the owner's own directories know about this message, or an empty
  /// pack.
  ///
  /// [_excerptsFor]'s shape and its reasoning. The retriever swallows its own
  /// failures and answers with the half it has; this catch is for the ones
  /// underneath it — a database that went away, a storyline read that threw —
  /// and it is noted rather than raised because a reply written without the
  /// project is still a reply.
  Future<ContextPack> _packFor(
    String source,
    String key,
    String id, {
    Future<Uint8List?> Function()? queryVector,
    List<int> consultFirst = const [],
  }) async {
    final retriever = _contextDirs;
    if (retriever == null) return ContextPack.empty;
    try {
      return await retriever.packFor(
        source: source,
        conversationKey: key,
        replyToId: id,
        storylineIds: await _store.storylineIdsFor(source, key),
        queryVector: queryVector,
        consultFirst: consultFirst,
      );
    } catch (e) {
      _log.note({'context_error': '$e'});
      return ContextPack.empty;
    }
  }

  /// One closure that answers with this message's query vector, however many
  /// times it is called, or null when there is no embedder to build one with.
  ///
  /// The memo holds the FUTURE and not the value, which is what makes it
  /// correct rather than merely thrifty: two retrievers awaiting the same
  /// unfinished POST both get that POST's answer, where a memo on the value
  /// would let the second one start a duplicate before the first had
  /// returned. A null answer is memoised too — an embedding server that is
  /// down is down for both corpora, and asking it twice is two timeouts in
  /// front of one draft.
  Future<Uint8List?> Function()? _queryVectorFor(String source, String id) {
    final embeddings = _embeddings;
    if (embeddings == null) return null;
    Future<Uint8List?>? cached;
    return () => cached ??= replyToQueryVector(_store, embeddings, source, id);
  }

  /// The documents the user named with "Use in reply", off the work item.
  ///
  /// Defensive to the point of paranoia because the payload is the one part of
  /// a work row that is free-form: anything that is not a JSON object with a
  /// list of strings under `pinned_attachment_ids` reads as "none named",
  /// which is the ordinary case anyway. A malformed payload must cost the
  /// pinning, never the draft.
  static List<String> _pinnedIdsFrom(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return const [];
      final ids = decoded['pinned_attachment_ids'];
      if (ids is! List) return const [];
      return [
        for (final id in ids)
          if (id is String && id.isNotEmpty) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// The directory files the user named with "Consult for the reply", off the
  /// work item.
  ///
  /// [_pinnedIdsFrom]'s paranoia over the other list, and one rule of its own:
  /// a `context_files.id` is a positive integer, so anything else — a string,
  /// a zero, a negative — is not an id and reads as "none named". A malformed
  /// payload must cost the consultation, never the draft.
  static List<int> _contextFileIdsFrom(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return const [];
      final ids = decoded['context_file_ids'];
      if (ids is! List) return const [];
      return [
        for (final id in ids)
          if (id is int && id > 0) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// The user's own recent replies to this sender, as writing samples.
  Future<List<String>> _styleExamplesFor(String source, String? address) async {
    if (address == null || address.isEmpty) return const [];
    final rows = await _store.recentOutboundToSender(
      source,
      address,
      limit: _styleExamples,
    );
    final examples = <String>[];
    for (final row in rows) {
      // Markers out, for [buildMessageBlock]'s reason and one of its own: a
      // style example is a sample the model imitates, and `[[att:…]]` in one
      // is a token it would learn to write.
      final body = stripAttachmentMarkers(row['body_text'] as String?).trim();
      final preview =
          stripAttachmentMarkers(row['body_preview'] as String?).trim();
      final text = body.isNotEmpty ? body : preview;
      if (text.isEmpty) continue;
      examples.add(
        text.length > _styleExampleCap
            ? text.substring(0, _styleExampleCap)
            : text,
      );
    }
    return examples;
  }

  /// The first live storyline's summary, when this thread is in one. First
  /// rather than best: `storylineIdsFor` returns them in join order, a thread
  /// is almost always in exactly one, and picking between two summaries is a
  /// judgement this handler has no basis for.
  Future<String?> _storylineSummaryFor(String source, String key) async {
    final ids = await _store.storylineIdsFor(source, key);
    if (ids.isEmpty) return null;
    return (await _store.getStoryline(ids.first))?.summary;
  }
}
