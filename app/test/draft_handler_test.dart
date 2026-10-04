import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:bond_inbox/models/draft_request.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attachments/attachment_retriever.dart';
import 'package:bond_inbox/services/backend/backend_types.dart'
    show ReconsentRequired;
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/calendar/ask_reader.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/draft_slot_refresher.dart';
import 'package:bond_inbox/services/calendar/draft_slots.dart';
import 'package:bond_inbox/services/calendar/find_time.dart'
    show
        FindTimeWindow,
        findTimeReplyLine,
        findTimeSlotLine,
        findTimeWindowUtc;
import 'package:bond_inbox/services/calendar/overlaps.dart' show FreeSlot;
import 'package:bond_inbox/services/cloud_drafts.dart' show DraftRoutes;
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/draft_stream.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTargetSpec;
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/fake_embed_server.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

/// A client scripted by TASK rather than by position. The handler makes one
/// model call, `draft_reply`: whether a reply is wanted was decided at triage
/// and is read from the store.
///
/// [chunks] is what a STREAMED draft call pushes through `onText`; the plain
/// calls never touch it. A streamed call still answers with its [draft] step,
/// which is either the chunks [decoded] or the failure the stream dies with.
ScriptedLlm draftClient({
  Object? draft,
  List<String> chunks = draftChunks,
}) {
  final llm = ScriptedLlm();
  if (draft != null) llm.answer('draft_reply', draft);
  llm.streamChunks = chunks;
  return llm;
}

/// The whole answer a run of chunks reassembles into.
Map<String, dynamic> decoded(List<String> chunks) =>
    jsonDecode(chunks.join()) as Map<String, dynamic>;

/// A store whose `upsertDraft` refuses. Everything else is the real thing:
/// the handler reads a real thread out of it and only the write fails, which
/// is the shape of a disk that filled up between the answer and the row.
class RefusingStore extends MessageStore {
  RefusingStore(super.db);

  @override
  Future<void> upsertDraft({
    required String source,
    required String conversationKey,
    required String replyToMessageId,
    required String body,
    String? evidence,
    String? optionsJson,
    String? contextJson,
    String status = 'suggested',
  }) async {
    throw StateError('the disk is full');
  }
}

/// One draft answer, cut into three. The chunks split it in awkward places —
/// mid-key, mid-word, mid-escape.
const List<String> draftChunks = [
  '{"evidence":"Sarah is waiting on a date.","options":[{"stance":"Conf',
  'irm","reply_body":"Thursday still works."},{"stance":"Push","reply_bo'
      'dy":"Friday is safer."}],"reply_body":"Hi Sarah — Thursday',
  ' still works. I will send the addendum today."}',
];

/// A retriever that answers from a fixture and records what it was asked.
///
/// A subclass rather than an interface, because the seam that matters is the
/// one method: everything else about a retriever — its scope arithmetic, its
/// budget — is what [attachment_retriever_test.dart] pins, and a second fake
/// shape would let the two drift.
class FakeRetriever extends AttachmentRetriever {
  final List<AttachmentExcerpt> answer;
  final Object? throws;

  /// Every `pinnedFirst` it was handed, in order. The list's LENGTH is the
  /// "one retrieval, two prompts" assertion.
  final List<List<String>> pinnedSeen = [];
  final List<List<String>?> threadIdsSeen = [];

  FakeRetriever(MessageStore store, {this.answer = const [], this.throws})
      : super(store, _neverDialled);

  int get calls => pinnedSeen.length;

  @override
  Future<List<AttachmentExcerpt>> excerptsFor({
    required String source,
    required String conversationKey,
    required String replyToId,
    List<String>? threadMessageIds,
    List<String> storylineIds = const [],
    List<String> pinnedFirst = const [],
    Future<Uint8List?> Function()? queryVector,
    int budgetChars = 2500,
    int perAttachment = 3,
    int k = 6,
  }) async {
    pinnedSeen.add(pinnedFirst);
    threadIdsSeen.add(threadMessageIds);
    final failure = throws;
    if (failure != null) throw failure;
    return answer;
  }
}

/// A directory retriever that answers from a fixture and counts its calls.
///
/// [FakeRetriever]'s shape and its reasoning: the seam that matters is the one
/// method, and `context_retriever_test.dart` is where the scope arithmetic,
/// the fusion and the budget are pinned.
class FakeContextRetriever extends ContextRetriever {
  final ContextPack answer;
  final Object? throws;

  /// Every `storylineIds` it was handed, in order. The list's LENGTH is the
  /// "one pack, two prompts" assertion.
  final List<List<String>> storylinesSeen = [];

  /// Every `consultFirst` it was handed — the files the person named.
  final List<List<int>> consultSeen = [];

  FakeContextRetriever(
    MessageStore store,
    ContextStore context, {
    this.answer = ContextPack.empty,
    this.throws,
  }) : super(store, context, _neverDialled);

  int get calls => storylinesSeen.length;

  @override
  Future<ContextPack> packFor({
    required String source,
    required String conversationKey,
    required String replyToId,
    required List<String> storylineIds,
    List<int> consultFirst = const [],
    Future<Uint8List?> Function()? queryVector,
    int budgetChars = 2500,
    int perFile = 3,
    int k = 6,
  }) async {
    storylinesSeen.add(storylineIds);
    consultSeen.add(consultFirst);
    final failure = throws;
    if (failure != null) throw failure;
    return answer;
  }
}

/// What the owner's own directories hand back, as the retriever ranked them.
ContextPack directoryPack() => const ContextPack(
      directories: ['acme'],
      briefs: [
        ContextBriefLine(dirName: 'acme', about: 'A renewal pricing model.'),
      ],
      guidance: [
        ContextGuidance(label: 'guidance', text: 'Answer in two lines.'),
      ],
      excerpts: [
        ContextExcerpt(
          dirName: 'acme',
          relPath: 'docs/pricing.md',
          locator: 'Pricing > Q4 rates',
          modified: '2026-08-30',
          text: 'Q4 rates hold at nine.',
          fileId: 1,
          dirId: 'd1',
        ),
        ContextExcerpt(
          dirName: 'acme',
          relPath: 'analysis.html',
          locator: 'digest',
          modified: '2026-08-31',
          text: 'What the rung schedule concluded.',
          fileId: 2,
          dirId: 'd1',
        ),
      ],
      skills: ['vendor-replies'],
    );

/// An activity log that keeps what the handler told it.
class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};

  @override
  void note(Map<String, Object?> detail) => notes.addAll(detail);
}

/// Never reached: [FakeRetriever] answers before any of it is used.
final _neverDialled =
    EmbeddingsClient(baseUrl: 'http://127.0.0.1:1/never-dialled');

AttachmentExcerpt excerpt({
  String name = 'Lease Addendum.pdf',
  String text = 'The rent rises to 2,600 on 1 January.',
  String attachmentId = 'a1',
}) =>
    AttachmentExcerpt(
      name: name,
      locator: 'part 2',
      sender: 'Sarah',
      date: '2026-08-28',
      text: text,
      ref: AttachmentRef(
        source: 'email',
        messageId: 'm2',
        attachmentId: attachmentId,
      ),
    );

Map<String, dynamic> answer({
  String evidence = 'Jordan is asking whether the launch still lands on Thursday.',
  String replyBody = 'Hi Sarah — Friday works. I will send the addendum today.',
  List<Map<String, String>> options = const [],
}) =>
    {'evidence': evidence, 'reply_body': replyBody, 'options': options};


void main() {
  late BondDatabase db;
  late MessageStore store;
  late PipelineProgress progress;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    progress = PipelineProgress(store);
  });

  tearDown(() async => db.close());

  Future<void> seedInbound({
    String id = 'm2',
    String key = 'conv-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String address = 'sarah@x.com',
    String body = 'Can we still ship on Thursday?',
    String triageStatus = 'pending',
    String? gateReason,
    Map<String, String>? headers,
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': address,
      'received_at': receivedAt,
      'body_text': body,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
      // The shape the detail fetch stores them in, which is what a machine
      // sender is read off.
      'source_meta_json':
          headers == null ? null : jsonEncode({'headers': headers}),
    });
  }

  Future<void> seedOutbound({
    String id = 'o1',
    String key = 'conv-1',
    String receivedAt = '2026-08-27T10:00:00Z',
    String to = 'sarah@x.com',
    String body = 'Thanks Sarah — I will check and come back to you. — Jo',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'outbound',
      'to_json': '["$to"]',
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  Future<void> seedChat({
    String id = 'chat-1-m1',
    String key = 'chat-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String body = 'Any word on the CD?',
    int hasAttachments = 0,
  }) async {
    await store.upsertMessage({
      'source': 'teams',
      'has_attachments': hasAttachments,
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      // A namespaced Graph id, which is what the connector stores. There is no
      // address to match a past reply against.
      'from_address': 'teams:u1',
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  /// The work item is keyed on the MESSAGE now: `entity_id` is a source
  /// message id, not a conversation key.
  Future<void> runOne(
    DraftHandler handler, {
    String id = 'm2',
    String source = 'email',
  }) =>
      handler.run({'task_kind': 'draft', 'source': source, 'entity_id': id});

  Future<Map<String, Object?>> progressOf(
    String id, {
    String source = 'email',
  }) async =>
      (await db
              .customSelect(
                'SELECT * FROM message_progress '
                'WHERE source = ? AND source_message_id = ?',
                variables: [Variable(source), Variable(id)],
              )
              .getSingle())
          .data;

  group('the happy path', () {
    test('writes a suggested draft against the message it was queued for',
        () async {
      await seedInbound(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress), id: 'm1');

      // m1, not the thread's newest message: the queue works at the grain of
      // the thing being answered.
      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['status'], 'suggested');
      expect(draft['conversation_key'], 'conv-1');
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
      expect(
        draft['evidence'],
        'Jordan is asking whether the launch still lands on Thursday.',
      );
      expect(draft['graph_draft_id'], isNull,
          reason: 'nothing here has touched Graph');
      expect((await progressOf('m1'))['draft_state'], 'done');
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('one model call, the draft, at zero and at the draft budget',
        () async {
      await seedInbound();
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      // Zero: the same message must get the same reply twice. Whether a reply
      // is wanted was decided at triage and costs no call here.
      expect(llm.schemaNames, ['draft_reply']);
      expect(llm.temperatures, [0.0]);
      expect(llm.tokenBudgets, [DraftHandler.draftMaxTokens]);
    });

    test('the draft stage lands done and stamps the row', () async {
      await seedInbound();

      await runOne(
        DraftHandler(
          store,
          draftClient(draft: answer()),
          progress: progress,
        ),
      );

      final row = await progressOf('m2');
      expect(row['draft_state'], 'done');
      expect(row['draft_at'], isNotNull);
    });

    test('and it closes the row when it is the last stage left', () async {
      await seedInbound();
      await progress.noteTriage('email', 'm2', state: 'done');
      await progress.noteExtract('email', 'm2', state: 'done');
      await progress.noteStoryline('email', 'conv-1', state: 'done');
      await progress.noteSettled(
        'email',
        'm2',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      // The toast has already gone out; the row is not finished until the
      // suggestion is in sqlite.
      expect((await progressOf('m2'))['outcome'], 'pending');

      await runOne(
        DraftHandler(
          store,
          draftClient(draft: answer()),
          progress: progress,
        ),
      );

      expect((await progressOf('m2'))['outcome'], 'done');
    });
  });

  group('the decision', () {
    // What triage stored, read BEFORE `_gather`: the decision model's
    // reply_expected probability, or the triage column for a row it never
    // read.
    Future<void> decide(double replyP, {String id = 'm2'}) =>
        store.writeDecision(
          'email',
          id,
          fakeDecision(fakeAnswers(replyExpected: replyP)),
          qhash: decisionQhash,
          ownerKnown: true,
        );
    Future<void> storeReplyExpected(int? value, {String id = 'm2'}) =>
        db.customUpdate(
          'UPDATE messages SET reply_expected = ? '
          'WHERE source = ? AND source_message_id = ?',
          variables: [Variable(value), Variable('email'), Variable(id)],
        );

    test('a no from the decision model stores nothing and spends nothing',
        () async {
      await seedInbound();
      await decide(0.12);
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty,
          reason: 'the drafting model is never reached');
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      // A real end state: the model read the message and said no reply is
      // owed.
      expect((await progressOf('m2'))['draft_state'], 'skipped');
    });

    test('a no pays for no gathering: no retrieval, no pack, no embedding',
        () async {
      await seedInbound();
      await decide(0.2);
      final embed = FakeEmbedServer();
      final retriever = FakeRetriever(store);
      final directories = FakeContextRetriever(store, ContextStore(db));
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(
        store,
        llm,
        attachments: retriever,
        contextDirs: directories,
        embeddings: embed.client,
        progress: progress,
      ));

      expect(retriever.calls, 0);
      expect(directories.calls, 0);
      expect(embed.calls, 0);
      expect(llm.schemaNames, isEmpty,
          reason: 'no context_select and no draft');
    });

    test('a no records the verdict and the probability behind it', () async {
      // `_skip`'s payload: the item is `skipped` rather than `ok`, `reason`
      // says which end, and `why` says what the decision model said.
      await seedInbound();
      await decide(0.123);
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        progress: progress,
      ));

      expect(log.notes['reason'], 'no_reply_needed');
      expect(log.notes['why'],
          'The decision model put the chance a reply is expected at 0.12.');
      expect(log.notes['decision'], 'decision_model');
      expect(log.notes['reply_p'], 0.12);
    });

    test('a yes proceeds to the draft and says what decided it', () async {
      await seedInbound();
      await decide(0.87);
      final llm = draftClient(draft: answer());
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        llm,
        activityLog: log,
        progress: progress,
      ));

      expect(llm.schemaNames, ['draft_reply']);
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
      expect(log.notes['decision'], 'decision_model');
      expect(log.notes['reply_p'], 0.87);
      expect(log.notes['reason'], isNull);
    });

    test('the threshold is replyYes: exactly at it is a yes', () async {
      await seedInbound();
      await decide(0.5);
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.schemaNames, ['draft_reply']);
    });

    test('a row decided before the decision model falls back to triage',
        () async {
      // No `message_decisions` row: the stored `reply_expected` column says.
      await seedInbound();
      await storeReplyExpected(0);
      final llm = draftClient(draft: answer());
      final retriever = FakeRetriever(store);
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        llm,
        attachments: retriever,
        activityLog: log,
        progress: progress,
      ));

      expect(llm.userMessages, isEmpty);
      expect(retriever.calls, 0);
      expect((await progressOf('m2'))['draft_state'], 'skipped');
      expect(log.notes['reason'], 'no_reply_needed');
      expect(log.notes['why'], 'Triage judged no reply is expected.');
      expect(log.notes['decision'], 'stored');
    });

    for (final value in [1, null]) {
      test('and a stored reply_expected of $value lets the draft proceed',
          () async {
        await seedInbound();
        await storeReplyExpected(value);
        final llm = draftClient(draft: answer());
        final log = _Recorder();

        await runOne(DraftHandler(
          store,
          llm,
          activityLog: log,
          progress: progress,
        ));

        expect(llm.schemaNames, ['draft_reply']);
        expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
        expect(log.notes['decision'], 'stored');
      });
    }

    test('the decision model outranks the stored column', () async {
      await seedInbound();
      await storeReplyExpected(1);
      await decide(0.1);
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
    });

    test('the draft reads the message and the thread before it', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.single, contains('It expires Wednesday.'));
      expect(llm.userMessages.single, contains('What is the current expiry?'));
    });

    test('and never a message that landed after the one it is answering',
        () async {
      await seedInbound(
        id: 'm1',
        receivedAt: '2026-08-20T10:00:00Z',
        body: 'Can we still ship on Thursday?',
      );
      await seedInbound(
        id: 'm2',
        receivedAt: '2026-08-29T10:00:00Z',
        body: 'Never mind, we shipped it.',
      );
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress), id: 'm1');

      // The thread is cut off at the message being answered, so the answer to
      // m1 is the same answer however far behind the queue was.
      for (final prompt in llm.userMessages) {
        expect(prompt, contains('Can we still ship on Thursday?'));
        expect(prompt, isNot(contains('Never mind, we shipped it.')));
      }
    });

    test('a draft a person asked for skips the decision entirely', () async {
      await seedInbound();
      // Even a decision that says no: pressing the button is the answer.
      await decide(0.05);
      final llm = draftClient(draft: answer());
      final log = _Recorder();

      await DraftHandler(store, llm, activityLog: log, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{"asked":true}',
      });

      // ONE call, and it is the drafting one. Pressing the button IS the
      // decision; a model answering "no" would leave an empty box.
      expect(llm.schemaNames, ['draft_reply']);
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
      expect(log.notes['decision'], 'asked');
      expect((await progressOf('m2'))['draft_state'], 'done');
    });

    test('an asked-for draft carries its pinned and consulted ids too',
        () async {
      await seedInbound();
      final retriever = FakeRetriever(store);
      final directories = FakeContextRetriever(store, ContextStore(db));
      final llm = draftClient(draft: answer());

      await DraftHandler(
        store,
        llm,
        attachments: retriever,
        contextDirs: directories,
      ).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{"pinned_attachment_ids":["att-survey"],'
            '"context_file_ids":[7],"asked":true}',
      });

      expect(llm.schemaNames, ['draft_reply']);
      expect(retriever.pinnedSeen.single, ['att-survey']);
      expect(directories.consultSeen.single, [7]);
    });

    test('a malformed payload still runs the decision', () async {
      await seedInbound();
      await decide(0.9);
      final llm = draftClient(draft: answer());
      final log = _Recorder();

      await DraftHandler(store, llm, activityLog: log, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{not json at all',
      });

      // Unreadable is "nobody asked", never "skip the judgement": the flag
      // only ever skips work when it was definitely set.
      expect(llm.schemaNames, ['draft_reply']);
      expect(log.notes['decision'], 'decision_model');
    });

    test('only the literal true skips it', () async {
      await seedInbound();
      await decide(0.05);
      final llm = draftClient(draft: answer());

      await DraftHandler(store, llm, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        // A string somebody hand-edited into the table is not a person
        // pressing a button.
        'payload_json': '{"asked":"true"}',
      });

      expect(llm.schemaNames, isEmpty,
          reason: 'not asked, so the decision says no');
    });

    test('a message a machine wrote costs no call at all', () async {
      // Asked here as well as at the draft queue, because a row can reach this
      // handler from an older build's queue and because the headers that answer
      // the question may only have arrived since. Nothing gated this message:
      // the headers are the whole of the evidence.
      await seedInbound(headers: {'List-Unsubscribe': '<https://x.example.com/u>'});
      final llm = draftClient(draft: answer());
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        llm,
        activityLog: log,
        progress: progress,
      ));

      // Not even the reply decision: the suppression is asked first.
      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      expect((await progressOf('m2'))['draft_state'], 'skipped');
      expect(log.notes['reason'], 'automated_sender');
      expect(log.notes['why'], 'a machine wrote this message');
    });

    test('and it runs ahead of the retrievers, not after them', () async {
      // The skip sits before `_gather`, which is an embedding call and a set of
      // attachment reads. A skip after them would spend most of the work it
      // exists to save.
      await seedInbound(headers: {'Auto-Submitted': 'auto-generated'});
      final retriever = FakeRetriever(store);

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        attachments: retriever,
        progress: progress,
      ));

      expect(retriever.pinnedSeen, isEmpty);
    });

    test('but a person who presses Draft reply gets one anyway', () async {
      // The owner overruling this, exactly as an asked-for draft overrules the
      // decision call. A press that produced an empty box and no sentence would
      // be a button that silently does nothing.
      await seedInbound(headers: {'List-Id': 'news.x.example.com'});
      final llm = draftClient(draft: answer());

      await DraftHandler(store, llm, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{"asked":true}',
      });

      expect(llm.schemaNames, ['draft_reply']);
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
      expect((await progressOf('m2'))['draft_state'], 'done');
    });
  });

  group('what goes into the drafting prompt', () {
    test('the user\'s past replies to this sender, as a tone sample', () async {
      // On an OLDER thread to the same person: a past reply is a sample only
      // when it is not already in the thread being answered.
      await seedOutbound(
        key: 'conv-0',
        body: 'Sounds good — I will confirm by noon. — Jo',
      );
      await seedInbound();

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('style_examples'));
      expect(llm.userMessages.last, contains('I will confirm by noon'));
    });

    test('and nothing when the user has never written to them', () async {
      await seedOutbound(key: 'conv-0', to: 'someone.else@x.com');
      await seedInbound();

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, isNot(contains('style_examples')));
    });

    test("the owner's own turn in the thread replaces the style examples",
        () async {
      // The owner has replied to this sender before, on an older thread — so
      // the sample exists and the fence appears. Put their own turn INTO the
      // thread being answered and it goes away: a reply they wrote on this
      // subject, to this person, is the better tone sample, and it is already
      // in the prompt.
      await seedOutbound(
        key: 'conv-0',
        body: 'Sounds good — I will confirm by noon. — Jo',
      );
      await seedInbound();

      final quiet = draftClient(draft: answer());
      await runOne(DraftHandler(store, quiet, progress: progress));
      expect(quiet.userMessages.last, contains('style_examples'));

      // A second thread with the same two people, and the owner has spoken in
      // it. Its own message is answered, so the first thread's draft is not in
      // the way.
      await seedOutbound(
        id: 'o2',
        key: 'conv-2',
        receivedAt: '2026-08-28T10:00:00Z',
        body: 'Checking with the team now. — Jo',
      );
      await seedInbound(id: 'm3', key: 'conv-2');

      final spoken = draftClient(draft: answer());
      await runOne(DraftHandler(store, spoken, progress: progress), id: 'm3');

      expect(spoken.userMessages.last, isNot(contains('style_examples')));
      expect(spoken.userMessages.last, contains('Checking with the team now.'));
    });

    test("an owner turn older than the rendered tail does not drop the examples",
        () async {
      // The prompt shows only the newest five turns. An owner reply six turns
      // back is not in it, so it cannot stand in for the style examples — the
      // rule reads the window the prompt renders, not the whole thread.
      await seedOutbound(key: 'conv-0', body: 'Yes, noon works. — Jo');
      await seedOutbound(
        id: 'o3',
        key: 'conv-3',
        receivedAt: '2026-08-28T08:00:00Z',
        body: 'Looping in the team now. — Jo',
      );
      for (var i = 0; i < 5; i++) {
        await seedInbound(
          id: 'm3$i',
          key: 'conv-3',
          receivedAt: '2026-08-28T${(9 + i).toString().padLeft(2, '0')}:00:00Z',
          body: 'Follow-up number $i about the venue.',
        );
      }

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress), id: 'm34');

      final prompt = llm.userMessages.last;
      expect(prompt, contains('style_examples'));
      // The owner's older turn is not in the rendered thread — it shows up,
      // correctly, as one of the style examples instead.
      final thread = prompt.substring(
        prompt.indexOf('<untrusted_data source="thread">'),
        prompt.indexOf('</untrusted_data>', prompt.indexOf('source="thread"')),
      );
      expect(thread, isNot(contains('Looping in the team now.')));
      expect('Follow-up number'.allMatches(thread).length, 5);
    });

    test('the about-me preference, read from the store', () async {
      await seedInbound();
      await store.setPref(aboutMeKey, 'I own the website redesign and the launch.');

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      // Both calls get it: who the owner is decides whether THEY have to
      // answer as much as it decides how the answer reads.
      for (final prompt in llm.userMessages) {
        expect(prompt, contains('about_me'));
        expect(prompt, contains('I own the website redesign'));
      }
    });

    test('the storyline summary, when the thread is in one', () async {
      await seedInbound();
      await store.insertStoryline(
        id: 's1',
        title: 'Website redesign',
        summary: 'Closing 9/15, lock expires 9/10.',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('s1', 'email', 'conv-1', addedBy: 'auto');

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('storyline_summary'));
      expect(llm.userMessages.last, contains('lock expires 9/10'));
    });

    test('the whole thread, both directions', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('What is the current expiry?'));
      expect(llm.userMessages.last, contains('It expires Wednesday.'));
    });

    test('the email channel note, alongside the style fence', () async {
      await seedOutbound(
        key: 'conv-0',
        body: 'Sounds good — I will confirm by noon. — Jo',
      );
      await seedInbound();

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('This is an email thread.'));
      expect(llm.userMessages.last, contains('style_examples'));
    });

    test('a tone sample carries no attachment marker', () async {
      // A style example is a sample the model imitates, so a `[[att:…]]` in
      // one is a token it would learn to write.
      await seedOutbound(
        key: 'conv-0',
        body: 'Signed copy [[att:file-1]] attached — Jo',
      );
      await seedInbound();

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, isNot(contains('[[att:')));
      expect(llm.userMessages.last, contains('Signed copy attached'));
    });

    test('a tone sample carries no link target', () async {
      // The same reason one step on: an example whose sentences trail
      // hundred-character addresses teaches the model to write them into the
      // reply, and what is being sampled is how this person words things.
      // The address is checked by host, because the fence escapes its
      // brackets to `&lt;` on the way into the prompt.
      await seedOutbound(
        key: 'conv-0',
        body: 'The deck <https://files.example.com/d/Q3> is attached — Jo',
      );
      await seedInbound();

      final llm = draftClient(draft: answer());
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('style_examples'));
      expect(llm.userMessages.last, isNot(contains('files.example.com')));
      expect(llm.userMessages.last, contains('The deck is attached'));
    });
  });

  group('a chat drafts through the same handler', () {
    test('a file-only chat message reaches the draft as what was shared',
        () async {
      // A body that is nothing but a marker would read to the drafting model
      // like a message that said nothing at all.
      await seedChat(body: '[[att:a1]]', hasAttachments: 1);
      await store.upsertAttachments('teams', 'chat-1-m1', [
        {
          'attachment_id': 'a1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Contract-v2.docx',
          'size': 0,
        },
      ]);
      final llm = draftClient(draft: answer());

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.single,
          contains('Shared a file: Contract-v2.docx'));
      expect(llm.userMessages.single, isNot(contains('[[att:')));
    });

    test('and gets the chat channel note, not the email one', () async {
      await seedChat();
      final llm = draftClient(
        draft: answer(replyBody: 'Sending it over now.'),
      );

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(
        llm.userMessages.last,
        contains('This is an instant-message chat.'),
      );
      expect(
        llm.userMessages.last,
        isNot(contains('This is an email thread.')),
      );
      expect((await store.getDraftForMessage('teams', 'chat-1-m1'))!['body'],
          'Sending it over now.');
    });

    test('with no style fence — a chat has no addressed past replies',
        () async {
      // `recentOutboundToSender` matches on `to_json`, which a chat never
      // writes, so this is the skip made visible: the sample the LIKE could
      // never have found does not appear as an empty fence either.
      await seedChat();
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-o1',
        'conversation_key': 'chat-1',
        'direction': 'outbound',
        'received_at': '2026-08-28T10:00:00Z',
        'body_text': 'On it — will check this afternoon.',
      });
      final llm = draftClient(draft: answer());

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.last, isNot(contains('style_examples')));
      // The owner's own chat voice is already in the thread, turn by turn.
      expect(
        llm.userMessages.last,
        contains('On it — will check this afternoon.'),
      );
    });

    test('and its thread lines name the sender rather than the Graph id',
        () async {
      await seedChat();
      final llm = draftClient(draft: answer());

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.last, contains('From: Sarah Whitfield'));
      expect(llm.userMessages.last, isNot(contains('teams:u1')));
    });
  });

  group('the documents in the prompt', () {
    test('one retrieval reaches the draft', () async {
      await seedInbound();
      final llm = draftClient(draft: answer());
      final retriever = FakeRetriever(store, answer: [excerpt()]);

      await runOne(DraftHandler(store, llm, attachments: retriever));

      expect(retriever.calls, 1);
      expect(llm.userMessages.length, 1);
      for (final sent in llm.userMessages) {
        expect(sent, contains('<untrusted_data source="attachment_excerpts">'));
        expect(sent, contains('The rent rises to 2,600'));
        expect(sent, contains('Lease Addendum.pdf'));
      }
    });

    test('the thread it searches is the thread as of the message answered',
        () async {
      await seedInbound(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      final retriever = FakeRetriever(store);

      await runOne(
        DraftHandler(store, draftClient(draft: answer()),
            attachments: retriever),
        id: 'm1',
      );

      // m2 landed after m1, so a document attached to m2 cannot be quoted in
      // the reply to m1.
      expect(retriever.threadIdsSeen.single, ['m1']);
    });

    test('a handler built with no retriever drafts exactly as before',
        () async {
      await seedInbound();
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm));

      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          startsWith('Hi Sarah — Friday works.'));
      for (final sent in llm.userMessages) {
        expect(sent, isNot(contains('attachment_excerpts')));
      }
    });

    test('Use in reply hands the named file to the retriever first', () async {
      await seedInbound();
      final retriever = FakeRetriever(store);

      await DraftHandler(
        store,
        draftClient(draft: answer()),
        attachments: retriever,
      ).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': jsonEncode({
          'pinned_attachment_ids': ['att-survey'],
        }),
      });

      expect(retriever.pinnedSeen.single, ['att-survey']);
    });

    test('a payload nobody can read costs the pinning, never the draft',
        () async {
      await seedInbound();
      final retriever = FakeRetriever(store);

      await DraftHandler(
        store,
        draftClient(draft: answer()),
        attachments: retriever,
      ).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{not json at all',
      });

      expect(retriever.pinnedSeen.single, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });

    test('a retriever that throws costs no draft', () async {
      await seedInbound();
      final retriever =
          FakeRetriever(store, throws: StateError('the index fell over'));

      await runOne(
        DraftHandler(store, draftClient(draft: answer()),
            attachments: retriever),
      );

      // The draft is the product; the citations are what make it better.
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });
  });

  group("the owner's own directories in the prompt", () {
    test('one pack reaches the draft', () async {
      await seedInbound();
      final llm = draftClient(draft: answer());
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());

      await runOne(DraftHandler(store, llm, contextDirs: directories));

      expect(directories.calls, 1);
      final sent = llm.userMessages.single;
      expect(sent, contains('<untrusted_data source="directory_excerpts">'));
      expect(sent, contains('Q4 rates hold at nine.'));
      expect(sent, contains('source="directory_guidance"'));
    });

    test('the storylines the thread is in reach the retriever', () async {
      await seedInbound();
      await store.insertStoryline(
        id: 'story-7',
        title: 'Marrowfield renewal',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('story-7', 'email', 'conv-1',
          addedBy: 'auto');
      final directories = FakeContextRetriever(store, ContextStore(db));

      await runOne(
        DraftHandler(store, draftClient(draft: answer()),
            contextDirs: directories),
      );

      expect(directories.storylinesSeen.single, ['story-7']);
    });

    test('what was read is stored on the draft row', () async {
      await seedInbound();
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());

      await runOne(
        DraftHandler(
          store,
          draftClient(draft: answer()),
          attachments: FakeRetriever(store, answer: [excerpt()]),
          contextDirs: directories,
        ),
      );

      final row = (await store.getDraftForMessage('email', 'm2'))!;
      final provenance =
          DraftProvenance.decode(row['context_json'] as String?)!;
      expect(provenance.documents, ['Lease Addendum.pdf']);
      expect(provenance.directories, ['acme']);
      expect(provenance.files, [
        (
          dir: 'acme',
          path: 'docs/pricing.md',
          locator: 'Pricing > Q4 rates',
          // The row id, which is what makes each of these a door rather than
          // only a name.
          fileId: 1,
        ),
        (dir: 'acme', path: 'analysis.html', locator: 'digest', fileId: 2),
      ]);
      expect(provenance.skills, ['vendor-replies']);
    });

    test('a draft written from nothing but the thread stores no inventory',
        () async {
      await seedInbound();

      await runOne(
        DraftHandler(store, draftClient(draft: answer())),
      );

      final row = (await store.getDraftForMessage('email', 'm2'))!;
      // Null rather than an empty object: "nothing was read" and "the column
      // was never written" are the same thing to the composer, and one of the
      // two spellings is shorter.
      expect(row['context_json'], isNull);
    });

    test('a pack that named a directory and rendered nothing stores no '
        'inventory', () async {
      // A room with a directory linked and nothing in it yet. The retriever
      // is the layer that decides whether a directory contributed, and this
      // pins the handler's side of that contract: an empty pack writes no
      // provenance, whatever it says about itself, so the composer cannot
      // claim the reply was drafted from a project the model never read.
      await seedInbound();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        contextDirs: FakeContextRetriever(
          store,
          ContextStore(db),
          answer: const ContextPack(
            directories: ['acme'],
            briefs: [],
            guidance: [],
            excerpts: [],
            skills: [],
          ),
        ),
      ));

      final row = (await store.getDraftForMessage('email', 'm2'))!;
      expect(row['context_json'], isNull);
    });

    test('the activity row names the project, the files and the skills',
        () async {
      await seedInbound();
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        attachments: FakeRetriever(store, answer: [excerpt()]),
        contextDirs: FakeContextRetriever(store, ContextStore(db),
            answer: directoryPack()),
      ));

      expect(log.notes['chars'], isA<int>());
      expect(log.notes['documents'], ['Lease Addendum.pdf']);
      expect(log.notes['directories'], ['acme']);
      expect(log.notes['directory_files'],
          ['docs/pricing.md', 'analysis.html']);
      expect(log.notes['skills'], ['vendor-replies']);
    });

    test('Consult for the reply hands the file to the retriever first',
        () async {
      await seedInbound();
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());
      final log = _Recorder();

      await DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: directories,
      ).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{"context_file_ids":[7]}',
      });

      expect(directories.consultSeen.single, [7]);
      expect(log.notes['consulted'], 1);
    });

    test('a payload nobody can read costs the consultation, never the draft',
        () async {
      await seedInbound();
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());
      final log = _Recorder();

      await DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: directories,
      ).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        // A `context_files.id` is a positive integer. Neither of these is.
        'payload_json': '{"context_file_ids":["x",-1]}',
      });

      expect(directories.consultSeen.single, isEmpty);
      expect(log.notes['consulted'], isNull);
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });

    test('a draft nobody named a file for consults nothing', () async {
      await seedInbound();
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: directories,
      ));

      expect(directories.consultSeen.single, isEmpty);
      expect(log.notes['consulted'], isNull);
    });

    test('what the section pick did, and what it could not do, are noted',
        () async {
      await seedInbound();
      final log = _Recorder();
      // A pack that both read a section whole AND could not be asked about a
      // second one. Both are the retriever's own report on the same pass, and
      // the row a person reads afterwards has to carry each: one says what
      // the reply was written from, the other says what did not happen.
      final directories = FakeContextRetriever(
        store,
        ContextStore(db),
        answer: const ContextPack(
          directories: ['acme'],
          briefs: [],
          guidance: [],
          excerpts: [
            ContextExcerpt(
              dirName: 'acme',
              relPath: 'docs/pricing.md',
              locator: 'Pricing',
              modified: '2026-08-30',
              text: 'Q4 rates hold at nine.',
              fileId: 1,
              dirId: 'd1',
              expanded: true,
            ),
          ],
          skills: [],
          expanded: ['docs/pricing.md § Pricing'],
          selectError: 'Exception: the fast server is down',
        ),
      );

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: directories,
      ));

      expect(log.notes['expanded'], 1);
      expect(log.notes['select_error'],
          contains('the fast server is down'));
    });

    test('a pack that asked for nothing says nothing about it', () async {
      await seedInbound();
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: FakeContextRetriever(store, ContextStore(db),
            answer: directoryPack()),
      ));

      expect(log.notes.containsKey('expanded'), isFalse);
      expect(log.notes.containsKey('select_error'), isFalse);
    });

    test('a retriever that throws costs the citations, not the reply',
        () async {
      await seedInbound();
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        draftClient(draft: answer()),
        activityLog: log,
        contextDirs: FakeContextRetriever(store, ContextStore(db),
            throws: StateError('the index fell over')),
      ));

      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
      expect(log.notes['context_error'], contains('the index fell over'));
    });

    test('two corpora, one embedding of the message', () async {
      if (!ensureSqliteVecLoaded()) return;
      // The real retrievers, over one thread that has BOTH a document on it
      // and a directory linked to it, answering a message the embed queue has
      // not reached yet. Each retriever knows how to embed the card itself,
      // and neither can know the other is about to ask the same question — so
      // the handler asks it once for the two of them.
      final vecDb = vecTestDb();
      addTearDown(vecDb.close);
      final vecStore = MessageStore(vecDb);
      final directories = ContextStore(vecDb);
      final embed = FakeEmbedServer();

      await vecStore.upsertMessage({
        'source_message_id': 'm2',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'Re: Renewal quote',
        'from_name': 'Sarah',
        'from_address': 'sarah@x.com',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'What does the renewal come to?',
      });
      // No `upsertMessageVector`: this is the case that costs a POST.
      await vecStore.upsertAttachments('email', 'm2', [
        {
          'attachment_id': 'a1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Lease.pdf',
          'content_type': 'application/pdf',
          'size': 4096,
        },
      ]);
      final chunkIds = await vecStore.replaceChunks('email', 'm2', 'a1', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays 2,400 monthly.'),
      ]);
      await vecStore.setChunkEmbedding(
        chunkIds.single,
        embedding: encodeEmbedding(axes({1: 1.0})),
        dims: embedDims,
        embedModel: EmbeddingsClient.documentModelTag,
      );
      await vecStore.indexPendingChunks();

      final dir = await directories.registerDirectory(
          path: '/a', displayName: 'acme');
      final fileId = await directories.upsertFile(
        dirId: dir,
        relPath: 'docs/pricing.md',
        size: 400,
        mtime: '2026-08-30T09:00:00.000Z',
        sha256: 'sha-a',
        kind: 'doc',
        claudeChain: const [],
        textChars: 400,
      );
      final chunkId = await directories.appendChunk(
        fileId,
        locator: '',
        text: 'docs/pricing.md\nQ4 rates hold at nine.',
      );
      await directories.setChunkEmbedding(
        chunkId,
        embedding: encodeEmbedding(axes({1: 1.0})),
        dims: embedDims,
        embedModel: EmbeddingsClient.documentModelTag,
      );
      await directories.indexPendingChunks();
      await directories.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      await DraftHandler(
        vecStore,
        draftClient(draft: answer()),
        attachments: AttachmentRetriever(vecStore, embed.client),
        contextDirs: ContextRetriever(vecStore, directories, embed.client),
        embeddings: embed.client,
      ).run({'task_kind': 'draft', 'source': 'email', 'entity_id': 'm2'});

      expect(await vecStore.getDraftForMessage('email', 'm2'), isNotNull);
      // One. Two would be the same card, embedded twice, in front of every
      // draft on a thread that has both.
      expect(embed.calls, 1);
    });

    test('a handler built with no retriever drafts exactly as before',
        () async {
      await seedInbound();
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm));

      for (final sent in llm.userMessages) {
        expect(sent, isNot(contains('directory_')));
      }
    });
  });

  group('the cases that spend no model time', () {
    test('a message that already has an answer is left alone', () async {
      await seedInbound();
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'an existing draft',
      );
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          'an existing draft');
      // Done, not skipped: this message has its suggestion.
      expect((await progressOf('m2'))['draft_state'], 'done');
    });

    test('a message that vanished is done, not failed', () async {
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('the user\'s own message is skipped', () async {
      await seedOutbound();
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress), id: 'o1');

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'o1'), isNull);
      expect((await progressOf('o1'))['draft_state'], 'skipped');
    });

    test('a message triage gated after the enqueue is skipped', () async {
      await seedInbound(triageStatus: 'skipped', gateReason: 'newsletter');
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      expect((await progressOf('m2'))['draft_state'], 'skipped');
    });

    test('but a chat skipped by birth still gets an answer', () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-m1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Sarah Whitfield',
        'from_address': 'teams:u1',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Any word on the CD?',
        'triage_status': 'skipped',
        'gate_reason': 'teams_source',
      });
      final llm = draftClient(draft: answer());

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(await store.getDraftForMessage('teams', 'chat-1-m1'), isNotNull);
    });
  });

  group('the short replies', () {
    test('are stored beside the long form, stance and body', () async {
      await seedInbound();
      final llm = draftClient(
        draft: answer(options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
          {'stance': 'Propose Monday', 'reply_body': 'Could we say Monday?'},
        ]),
      );

      await runOne(DraftHandler(store, llm, progress: progress));

      final draft = (await store.getDraftForMessage('email', 'm2'))!;
      final stored = jsonDecode(draft['options_json'] as String) as List;
      expect(stored, [
        {'stance': 'Confirm Thursday', 'body': 'Thursday still works.'},
        {'stance': 'Propose Monday', 'body': 'Could we say Monday?'},
      ]);
      expect(draft['options_dismissed'], 0);
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
    });

    test('are null, not an empty array, when the model offered none', () async {
      // The two spellings say the same thing to every reader, and one of them
      // is shorter.
      await seedInbound();

      await runOne(
        DraftHandler(
          store,
          draftClient(draft: answer()),
          progress: progress,
        ),
      );

      expect((await store.getDraftForMessage('email', 'm2'))!['options_json'],
          isNull);
    });

    test('a half-written option does not reach the row', () async {
      await seedInbound();
      final llm = draftClient(
        draft: answer(options: const [
          {'stance': '', 'reply_body': 'unlabelled'},
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
        ]),
      );

      await runOne(DraftHandler(store, llm, progress: progress));

      final draft = (await store.getDraftForMessage('email', 'm2'))!;
      expect(jsonDecode(draft['options_json'] as String), [
        {'stance': 'Confirm Thursday', 'body': 'Thursday still works.'},
      ]);
    });
  });

  group('an empty draft', () {
    test('throws rather than storing a blank suggestion, options or not',
        () async {
      // The long form is the product; options that arrived alongside a blank
      // reply are not a reason to store a draft the worker should retry.
      await seedInbound();
      final llm = draftClient(
        draft: answer(replyBody: '   ', options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday works.'},
        ]),
      );

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('throws rather than storing a blank suggestion', () async {
      await seedInbound();
      final llm =
          draftClient(draft: answer(replyBody: '   '));

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('and the worker retries it once, then gives up', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final llm =
          draftClient(draft: answer(replyBody: ''));
      final worker = AiWorker(
        store,
        handlers: [DraftHandler(store, llm, progress: progress)],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await worker.pump();

      expect(await store.workCounts('draft'), {'error': 1});
      expect(llm.userMessages, hasLength(2),
          reason: 'one retry, then the item is left alone');
      // Red only once the retries are gone — a bar that showed it in between
      // would report a state the pipeline does not consider final.
      expect((await progressOf('m2'))['draft_state'], 'error');
    });
  });

  group('through the worker', () {
    test('a queued message is drafted and marked done', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            draftClient(draft: answer()),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'done': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });

    test('a server that is down during the DRAFT leaves the item queued',
        () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            draftClient(
              draft: const LlmUnavailableException('not reachable'),
            ),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'pending': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      expect((await progressOf('m2'))['draft_state'], 'pending');
    });
  });

  group('concurrency', () {
    test('one at a time when nobody says otherwise', () {
      // What every test in this file, every bench and a single-slot
      // llama-server gets.
      expect(
        DraftHandler(store, draftClient()).concurrency,
        1,
      );
    });

    test('it reads the closure, every time it is asked', () {
      // The width is a fact about wherever `draft_reply` points, resolved at
      // the press, and `AiWorker._drainAll` asks before each launch. A
      // handler that cached
      // the number would leave a change waiting for the next launch of the
      // app; `ai_worker_lanes_test.dart` pins the other half, that the worker
      // re-reads it mid-drain.
      var width = 2;
      final handler = DraftHandler(
        store,
        draftClient(),
        concurrency: () => width,
      );

      expect(handler.concurrency, 2);
      width = 8;
      expect(handler.concurrency, 8);
    });
  });

  group('streaming', () {
    test('publishes the words a person reads, and nothing else', () async {
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = <DraftStreamEvent>[];
      Map<String, Object?>? rowWhenDone;
      final sub = bus.stream.listen((event) async {
        events.add(event);
        if (event.done) {
          rowWhenDone = await store.getDraftForMessage('email', 'm2');
        }
      });
      addTearDown(sub.cancel);

      await runOne(
        DraftHandler(
          store,
          draftClient(draft: decoded(draftChunks)),
          progress: progress,
          stream: bus,
        ),
      );
      // Let the listener's own read land.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final deltas = events.where((e) => !e.done).toList();
      expect(deltas, isNotEmpty);
      for (final event in deltas) {
        expect(event.source, 'email');
        expect(event.conversationKey, 'conv-1');
        expect(event.sourceMessageId, 'm2');
      }

      String textOf(String path) => deltas
          .where((e) => e.path == path)
          .map((e) => e.delta)
          .join();

      expect(textOf('reply_body'),
          'Hi Sarah — Thursday still works. I will send the addendum today.');
      expect(textOf('options[0].stance'), 'Confirm');
      expect(textOf('options[0].reply_body'), 'Thursday still works.');
      expect(textOf('options[1].stance'), 'Push');
      expect(textOf('options[1].reply_body'), 'Friday is safer.');
      // Never the evidence: it is the model's note to the app about what it
      // read, and nobody watches that being typed.
      expect(deltas.map((e) => e.path), isNot(contains('evidence')));

      // Exactly one, and only once the row it points at exists.
      expect(events.where((e) => e.done).length, 1);
      expect(events.last.done, isTrue);
      expect(rowWhenDone, isNotNull);
    });

    test('a handler with no bus makes the plain call it always made',
        () async {
      await seedInbound();
      final llm = draftClient(draft: answer());

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.streamedCalls, 0);
      // Through `completeJson` — which is what every other test in this file,
      // and every other fake in the suite, relies on.
      expect(llm.schemaNames, ['draft_reply']);
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          startsWith('Hi Sarah — Friday works.'));
    });

    test('a target that does not stream makes the plain call', () async {
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = <DraftStreamEvent>[];
      final sub = bus.stream.listen(events.add);
      addTearDown(sub.cancel);
      final llm = draftClient(draft: answer());

      await runOne(
        DraftHandler(
          store,
          llm,
          progress: progress,
          // An enabled bus AND a target that cannot stream — one on the
          // Converse wire has nothing to stream at all — so the bus is live
          // and the call is still the plain one.
          stream: bus,
          streams: () => false,
        ),
      );

      expect(llm.streamedCalls, 0);
      expect(llm.schemaNames, ['draft_reply']);
      expect(events, isEmpty);
      // And the draft still lands, which is the whole point of degrading
      // rather than refusing.
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          startsWith('Hi Sarah — Friday works.'));
    });

    test('and a closure saying true leaves the streamed path alone', () async {
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final llm =
          draftClient(draft: decoded(draftChunks));

      await runOne(
        DraftHandler(
          store,
          llm,
          progress: progress,
          stream: bus,
          streams: () => true,
        ),
      );

      expect(llm.streamedCalls, 1);
    });

    test('a draft call that fails still says it has stopped', () async {
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = <DraftStreamEvent>[];
      final sub = bus.stream.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
        runOne(
          DraftHandler(
            store,
            draftClient(
              draft: const LlmFormatException('cut off mid-object'),
            ),
            progress: progress,
            stream: bus,
          ),
        ),
        throwsA(isA<LlmFormatException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The listener's rule is "done, so read the row". A failed call wrote no
      // row, and the preview has to stop either way.
      expect(events.last.done, isTrue);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('a row that refuses to store still says the draft has stopped',
        () async {
      // The `finally` is the whole point: the reader is watching a preview,
      // and every way this can end has to take it away — including the ways
      // that are nobody's fault but the disk's.
      final refusing = RefusingStore(db);
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = <DraftStreamEvent>[];
      final sub = bus.stream.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
        runOne(
          DraftHandler(
            refusing,
            draftClient(draft: decoded(draftChunks)),
            progress: progress,
            stream: bus,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events.where((e) => e.done).length, 1);
      expect(events.last.done, isTrue);
    });

    test('an empty reply is a failure that still says it has stopped',
        () async {
      await seedInbound();
      final bus = DraftStreamBus();
      addTearDown(bus.dispose);
      final events = <DraftStreamEvent>[];
      final sub = bus.stream.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
        runOne(
          DraftHandler(
            store,
            draftClient(draft: decoded(const [
                '{"evidence":"nothing to say","options":[],"reply_body":""}',
              ]), chunks: const [
                '{"evidence":"nothing to say","options":[],"reply_body":""}',
              ]),
            progress: progress,
            stream: bus,
          ),
        ),
        throwsA(isA<LlmFormatException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events.last.done, isTrue);
    });
  });

  group("a scheduling ask's draft offers real times", () {
    const dana = 'dana@fabrikam.com';
    const me = 'me@contoso.com';
    late CalendarZone la;
    late ActivityLog log;
    late _SlotsBackend backend;
    late List<FreeSlot> offered;

    setUpAll(() async {
      await initCalendarZones();
    });

    setUp(() {
      la = CalendarZone.tryNamed('America/Los_Angeles')!;
      log = ActivityLog(store);
      // Two slots a week out, whenever the test runs: 10:00 and 14:00
      // local, ranked by Graph's confidence in that order.
      final day = la.dateOf(DateTime.now().toUtc()).addDays(7);
      DateTime at(int h) => la.localDateTime(day, h, 0).toUtc();
      offered = [
        FreeSlot(at(10), at(10).add(const Duration(minutes: 30))),
        FreeSlot(at(14), at(14).add(const Duration(minutes: 30))),
      ];
      backend = _SlotsBackend([
        MeetingTimeSuggestion(
            startUtc: offered[0].startUtc,
            endUtc: offered[0].endUtc,
            confidence: 90),
        MeetingTimeSuggestion(
            startUtc: offered[1].startUtc,
            endUtc: offered[1].endUtc,
            confidence: 50),
      ]);
    });

    /// A needs-reply thread with Dana and the owner whose one message, an
    /// hour old, the decision model read as [intent] at p 0.9, a reply
    /// expected.
    Future<void> seedAsk({
      String body = 'Could we find half an hour this week to go over the '
          'budget?',
      String subject = 'Budget',
      String intent = 'scheduling',
      double replyExpected = 0.9,
    }) async {
      final received = MessageStore.isoStamp(
          DateTime.now().toUtc().subtract(const Duration(hours: 1)));
      await store.upsertMessage({
        'source_message_id': 'm-ask',
        'conversation_key': 'c-ask',
        'direction': 'inbound',
        'subject': subject,
        'from_name': 'Dana',
        'from_address': dana,
        'received_at': received,
        'body_text': body,
        'triage_status': 'done',
      });
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c-ask',
        'subject': subject,
        'participants_json':
            '[{"name":"Dana","email":"$dana"},{"name":"Me","email":"$me"}]',
        'state': 'needs_reply',
        'message_count': 1,
        'last_inbound_at': received,
        'last_message_at': received,
      });
      await store.writeDecision(
        'email',
        'm-ask',
        fakeDecision(fakeAnswers(
            intent: intent, choiceP: 0.9, replyExpected: replyExpected)),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );
    }

    /// The model reader off unless a test reads with one: the rules alone.
    DraftCalendar calendarFor({
      AskReader? reader,
      bool available = true,
      Set<String> owner = const {me},
    }) =>
        DraftCalendar(
          store: CalendarStore(db),
          backend: backend,
          mailbox: () async => null,
          zone: () async => la,
          reader: reader ??
              AskReader(
                store: store,
                client: () => ScriptedLlm.never(label: 'ask_read off'),
                log: log,
                zone: () => la,
                enabled: false,
              ),
          ownerAddresses: () async => owner,
          available: () => available,
        );

    Map<String, dynamic> withOptions() => answer(
          replyBody: 'Hi Dana — happy to go over the budget.',
          options: const [
            {'stance': 'Yes', 'reply_body': 'Happy to — let us meet.'},
            {'stance': 'Later', 'reply_body': 'Could it wait a week?'},
          ],
        );

    Future<Map<String, Object?>> runAsk(
      ScriptedLlm llm, {
      DraftCalendar? calendar,
    }) async {
      await runOne(
        DraftHandler(store, llm,
            activityLog: log, calendar: calendar ?? calendarFor()),
        id: 'm-ask',
      );
      return (await store.getDraftForMessage('email', 'm-ask'))!;
    }

    Map<String, Object?>? calendarOf(Map<String, Object?> draft) =>
        DraftProvenance.decode(draft['context_json'] as String?)?.calendar;

    Future<List<Map<String, Object?>>> findTimeRows() async => [
          for (final r in await store.recentActivity())
            if (r['kind'] == 'find_time') r,
        ];

    test('the body and every option end with the real times', () async {
      await seedAsk();
      final draft = await runAsk(draftClient(draft: withOptions()));

      final line = findTimeReplyLine(offered, la);
      expect(draft['body'],
          'Hi Dana — happy to go over the budget.\n\n$line');
      final options =
          (jsonDecode(draft['options_json'] as String) as List).cast<Map>();
      expect([for (final o in options) o['body']], [
        'Happy to — let us meet.\n\n$line',
        'Could it wait a week?\n\n$line',
      ]);
      expect([for (final o in options) o['stance']], ['Yes', 'Later']);

      final calendar = calendarOf(draft)!;
      expect(calendar['slots'], [
        for (final s in offered)
          {
            'start_utc': MessageStore.isoStamp(s.startUtc),
            'end_utc': MessageStore.isoStamp(s.endUtc),
          },
      ]);
      expect(calendar['read'], 'rules');
      expect(calendar['source'], 'graph');
      expect(calendar['window'], 'this_week');
      expect(calendar['minutes'], 30);
      expect(calendar['graph_calls'] as int, greaterThanOrEqualTo(1));
      expect(backend.asked.first, [dana],
          reason: 'the thread\'s other people, the owner left out');

      final row = (await findTimeRows()).single;
      expect(row['status'], 'ok');
      expect(jsonDecode(row['detail_json'] as String), {
        'action': 'draft',
        'source': 'graph',
        'slots': 2,
        'people': 1,
        'window': 'this_week',
        'graph_calls': calendar['graph_calls'],
        'read': 'rules',
      });
    });

    test('the model never saw the times', () async {
      await seedAsk();
      final llm = draftClient(draft: withOptions());
      await runAsk(llm);

      final prompt = llm.users.single;
      expect(prompt, isNot(contains('Would any of these work')));
      for (final s in offered) {
        expect(prompt, isNot(contains(findTimeSlotLine(s, la))));
      }
    });

    test("the model's reading drives the window", () async {
      await seedAsk(
          subject: 'Dinner', body: 'Could we do dinner on Friday?');
      final reading = ScriptedLlm(answers: {
        'ask_read': {
          'evidence': 'Dana asks to have dinner on Friday.',
          'asks_for_time': true,
          'when': ['Friday'],
          'time': '',
          'duration': '',
          'meal': 'dinner',
        },
      });
      // Each day's ask answered with its own opening, so the slot sits
      // inside the evening Graph was asked about.
      backend.answerFor = (start, end) => [
            MeetingTimeSuggestion(
                startUtc: start,
                endUtc: start.add(const Duration(minutes: 90))),
          ];
      final draft = await runAsk(
        draftClient(draft: answer()),
        calendar: calendarFor(
          reader: AskReader(
            store: store,
            client: () => reading,
            log: log,
            zone: () => la,
          ),
        ),
      );

      expect(reading.schemaNames, ['ask_read']);
      final asked = la.toLocal(backend.windows.first.$1);
      expect(asked.weekday, DateTime.friday,
          reason: 'the Friday the model copied');
      expect(asked.hour, greaterThanOrEqualTo(17),
          reason: 'dinner is the evening');
      expect(backend.minutes.first, 90, reason: "dinner's own length");
      final calendar = calendarOf(draft)!;
      expect(calendar['read'], 'model');
      expect(calendar['window'], 'theirs');
      expect(calendar['minutes'], 90);
      expect(await store.askReading('email', 'm-ask'), isNotNull,
          reason: 'the draft lane pre-warms the reading the Day column reads');
    });

    test("a model reading that kept nothing falls back to the rules' day",
        () async {
      // "Thurs" is the ask's word; the model's "Thursday" is not in the text,
      // so the literal guard drops it and the reading keeps nothing.
      await seedAsk(subject: 'Call', body: 'Free for a call Thurs?');
      final reading = ScriptedLlm(answers: {
        'ask_read': {
          'evidence': 'Dana asks for a call on Thursday.',
          'asks_for_time': true,
          'when': ['Thursday'],
          'time': '',
          'duration': '',
          'meal': 'none',
        },
      });
      final draft = await runAsk(
        draftClient(draft: answer()),
        calendar: calendarFor(
          reader: AskReader(
            store: store,
            client: () => reading,
            log: log,
            zone: () => la,
          ),
        ),
      );

      expect(reading.schemaNames, ['ask_read']);
      expect(la.toLocal(backend.windows.first.$1).weekday, DateTime.thursday,
          reason: "the rules' Thursday, not this week");
      final calendar = calendarOf(draft)!;
      expect(calendar['read'], 'rules');
      expect(calendar['window'], 'theirs');
    });

    test('a multi-day model reading offers one slot on each day', () async {
      await seedAsk(
          subject: 'Catch up',
          body: 'Could we meet Tuesday or Thursday afternoon?');
      final reading = ScriptedLlm(answers: {
        'ask_read': {
          'evidence': 'Dana offers two afternoons.',
          'asks_for_time': true,
          'when': ['Tuesday', 'Thursday'],
          'time': 'afternoon',
          'duration': '',
          'meal': 'none',
        },
      });
      // Each day's call answered with an opening just inside it, so the
      // day being today never makes its slot one that has begun.
      backend.answerFor = (start, end) {
        final at = start.add(const Duration(minutes: 5));
        return [
          MeetingTimeSuggestion(
              startUtc: at, endUtc: at.add(const Duration(minutes: 30))),
        ];
      };
      final draft = await runAsk(
        draftClient(draft: answer()),
        calendar: calendarFor(
          reader: AskReader(
            store: store,
            client: () => reading,
            log: log,
            zone: () => la,
          ),
        ),
      );

      final calendar = calendarOf(draft)!;
      expect(calendar['read'], 'model');
      final slots = draftSlotsOf(calendar);
      expect({for (final s in slots) la.toLocal(s.startUtc).weekday},
          {DateTime.tuesday, DateTime.thursday});
      final body = draft['body'] as String;
      expect(body, endsWith('\n\n${findTimeReplyLine(slots, la)}'));
      for (final s in slots) {
        expect(body, contains(findTimeSlotLine(s, la)));
      }
    });

    test("the handler's own clock decides which slots have begun", () async {
      await seedAsk();
      // A clock a minute into the first offered slot: that slot has begun
      // by it, though not by the wall clock.
      final fixed = offered[0].startUtc.add(const Duration(minutes: 1));
      await runOne(
        DraftHandler(store, draftClient(draft: withOptions()),
            activityLog: log, calendar: calendarFor(), clock: () => fixed),
        id: 'm-ask',
      );

      final draft = (await store.getDraftForMessage('email', 'm-ask'))!;
      expect(draft['body'],
          endsWith('\n\n${findTimeReplyLine([offered[1]], la)}'));
      expect(calendarOf(draft)!['slots'], hasLength(1));
    });

    test('not a scheduling ask: no calendar call', () async {
      await seedAsk(intent: 'question');
      final draft = await runAsk(draftClient(draft: withOptions()));

      expect(backend.asked, isEmpty);
      expect(draft['body'], 'Hi Dana — happy to go over the budget.');
      expect(calendarOf(draft), isNull);
      expect(await findTimeRows(), isEmpty);
    });

    test('the calendar unavailable: the draft stands', () async {
      await seedAsk();
      final draft = await runAsk(draftClient(draft: withOptions()),
          calendar: calendarFor(available: false));

      expect(backend.asked, isEmpty);
      expect(draft['body'], 'Hi Dana — happy to go over the budget.');
      expect(calendarOf(draft), isNull);
    });

    test('a calendar error skips the times, not the draft', () async {
      await seedAsk();
      backend.throws = const CalendarTransient('Graph answered 503.');
      final draft = await runAsk(draftClient(draft: withOptions()));

      expect(backend.asked, isNotEmpty);
      expect(draft['body'], 'Hi Dana — happy to go over the budget.');
      expect(calendarOf(draft), isNull);
      final row = (await findTimeRows()).single;
      expect(row['status'], 'skipped');
      expect(jsonDecode(row['detail_json'] as String),
          {'action': 'draft', 'reason': 'transient'});
    });

    test('a lapsed consent still parks the drain', () async {
      await seedAsk();
      backend.throws = const ReconsentRequired();
      await expectLater(
        runOne(
          DraftHandler(store, draftClient(draft: withOptions()),
              activityLog: log, calendar: calendarFor()),
          id: 'm-ask',
        ),
        throwsA(isA<ReconsentRequired>()),
      );
    });

    test('a slot the mirror shows busy is not offered', () async {
      await seedAsk();
      // Two slots inside the week the search reads (its overlaps come from
      // the mirror over the window's own days), both still ahead.
      final w = findTimeWindowUtc(FindTimeWindow.thisWeek,
          now: DateTime.now(), zone: la, durationMinutes: 30);
      final a = w.startUtc.add(const Duration(minutes: 5));
      final inWeek = [
        FreeSlot(a, a.add(const Duration(minutes: 30))),
        FreeSlot(a.add(const Duration(minutes: 30)),
            a.add(const Duration(minutes: 60))),
      ];
      backend.answerFor = (_, _) => [
            MeetingTimeSuggestion(
                startUtc: inWeek[0].startUtc,
                endUtc: inWeek[0].endUtc,
                confidence: 90),
            MeetingTimeSuggestion(
                startUtc: inWeek[1].startUtc,
                endUtc: inWeek[1].endUtc,
                confidence: 50),
          ];
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'busy-1',
          subject: 'Planning',
          startUtc: inWeek[0].startUtc,
          endUtc: inWeek[0].endUtc,
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      final draft = await runAsk(draftClient(draft: withOptions()));

      expect(draft['body'],
          endsWith('\n\n${findTimeReplyLine([inWeek[1]], la)}'));
      expect(calendarOf(draft)!['slots'], hasLength(1));
    });

    test('an Improve keeps the offered times, unseen by its target too',
        () async {
      await seedAsk();
      final improver = ScriptedLlm()
        ..answer('draft_reply', answer(replyBody: 'Hi Dana — glad to.'));
      final handler = DraftHandler(
        store,
        draftClient(draft: withOptions()),
        activityLog: log,
        calendar: calendarFor(),
        improveClient: improver,
        routes: DraftRoutes(
          draftTarget: () => null,
          improveTarget: () => _localTarget,
          standing: () => false,
        ),
      );
      await runOne(handler, id: 'm-ask');

      expect(await handler.improve('email', 'm-ask'), isNull);
      final draft = (await store.getDraftForMessage('email', 'm-ask'))!;
      expect(draft['body'],
          'Hi Dana — glad to.\n\n${findTimeReplyLine(offered, la)}');
      expect(calendarOf(draft)!['slots'], hasLength(2));
      expect(calendarOf(draft)!['improved'], isTrue);
      expect(improver.users.single,
          isNot(contains('Would any of these work')));
      expect(backend.asked, hasLength(1),
          reason: 'the stored times are kept, not searched again');
    });

    test('an Improve drops a stored time that has gone since', () async {
      await seedAsk();
      final improver = ScriptedLlm()
        ..answer('draft_reply', answer(replyBody: 'Hi Dana — glad to.'));
      final handler = DraftHandler(
        store,
        draftClient(draft: withOptions()),
        activityLog: log,
        calendar: calendarFor(),
        improveClient: improver,
        routes: DraftRoutes(
          draftTarget: () => null,
          improveTarget: () => _localTarget,
          standing: () => false,
        ),
      );
      await runOne(handler, id: 'm-ask');
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'busy-1',
          startUtc: offered[0].startUtc,
          endUtc: offered[0].endUtc,
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');

      expect(await handler.improve('email', 'm-ask'), isNull);
      final draft = (await store.getDraftForMessage('email', 'm-ask'))!;
      expect(draft['body'],
          'Hi Dana — glad to.\n\n${findTimeReplyLine([offered[1]], la)}');
      expect(calendarOf(draft)!['slots'], hasLength(1));
    });

    test('the standing improve keeps them too', () async {
      await seedAsk();
      await db.customUpdate(
        "UPDATE messages SET urgency = 'urgent' "
        "WHERE source_message_id = 'm-ask'",
      );
      await store.writeNeedsYouP('email', 'm-ask', p: 0.95);
      final improver = ScriptedLlm()
        ..answer('draft_reply', answer(replyBody: 'Hi Dana — glad to.'));
      await runOne(
        DraftHandler(
          store,
          draftClient(draft: withOptions()),
          activityLog: log,
          calendar: calendarFor(),
          improveClient: improver,
          routes: DraftRoutes(
            draftTarget: () => null,
            improveTarget: () => _localTarget,
            standing: () => true,
          ),
        ),
        id: 'm-ask',
      );

      expect(improver.calls, hasLength(1), reason: 'the standing rule ran');
      final draft = (await store.getDraftForMessage('email', 'm-ask'))!;
      expect(draft['body'],
          'Hi Dana — glad to.\n\n${findTimeReplyLine(offered, la)}');
      expect(calendarOf(draft)!['slots'], hasLength(2));
      expect(calendarOf(draft)!['improved'], isTrue,
          reason: 'a rewrite that may have been a cloud call is never '
              'redrafted');
      expect(improver.users.single,
          isNot(contains('Would any of these work')));
    });

    test('an older message of an ask thread gets no times', () async {
      await seedAsk();
      await store.upsertMessage({
        'source_message_id': 'm-old',
        'conversation_key': 'c-ask',
        'direction': 'inbound',
        'subject': 'Budget',
        'from_name': 'Dana',
        'from_address': dana,
        'received_at': MessageStore.isoStamp(
            DateTime.now().toUtc().subtract(const Duration(hours: 3))),
        'body_text': 'Could we meet this week?',
        'triage_status': 'done',
      });
      await runOne(
        DraftHandler(store, draftClient(draft: withOptions()),
            activityLog: log, calendar: calendarFor()),
        id: 'm-old',
      );

      final draft = (await store.getDraftForMessage('email', 'm-old'))!;
      expect(draft['body'], 'Hi Dana — happy to go over the budget.');
      expect(calendarOf(draft), isNull);
      expect(backend.asked, isEmpty,
          reason: 'the one rule names the thread\'s NEWEST inbound message');
    });

    test('a lapsed consent on one day of several still parks the drain',
        () async {
      await seedAsk(
          subject: 'Catch up',
          body: 'Could we meet Tuesday or Thursday afternoon?');
      final reading = ScriptedLlm(answers: {
        'ask_read': {
          'evidence': 'Dana offers two afternoons.',
          'asks_for_time': true,
          'when': ['Tuesday', 'Thursday'],
          'time': 'afternoon',
          'duration': '',
          'meal': 'none',
        },
      });
      backend.answerFor = (start, end) => [
            MeetingTimeSuggestion(
                startUtc: start,
                endUtc: start.add(const Duration(minutes: 30))),
          ];
      backend.throwOn = (n) => n == 1 ? const ReconsentRequired() : null;

      await expectLater(
        runOne(
          DraftHandler(store, draftClient(draft: withOptions()),
              activityLog: log,
              calendar: calendarFor(
                reader: AskReader(
                  store: store,
                  client: () => reading,
                  log: log,
                  zone: () => la,
                ),
              )),
          id: 'm-ask',
        ),
        throwsA(isA<ReconsentRequired>()),
      );
      expect(backend.asked, hasLength(2), reason: 'one call per day named');
    });

    test('no owner address known: the owner is asked about too', () async {
      // Today's behaviour, pinned: before the account is read the owner is
      // nobody to leave out, and Graph is asked about them as an attendee —
      // harmless, they are the organiser anyway.
      await seedAsk();
      await runAsk(draftClient(draft: withOptions()),
          calendar: calendarFor(owner: const {}));
      expect(backend.asked.first, [dana, me]);
    });

    test('an asked-for draft whose times went stale is redrafted, still '
        'asked', () async {
      // Reply not expected: only the press gets this message a draft.
      await seedAsk(replyExpected: 0.1);
      final asked = const DraftRequest(asked: true).encode();
      Future<void> runAsked() async {
        final item = {
          'task_kind': 'draft',
          'source': 'email',
          'entity_id': 'm-ask',
          'payload_json': await store.workPayload('draft', 'email', 'm-ask'),
        };
        await DraftHandler(store, draftClient(draft: withOptions()),
                activityLog: log, calendar: calendarFor())
            .run(item);
      }

      await store.requeueWork('draft', 'email', 'm-ask', payloadJson: asked);
      await db.customUpdate(
          "UPDATE work_items SET status = 'done' WHERE entity_id = 'm-ask'");
      await runAsked();
      expect(calendarOf((await store.getDraftForMessage('email', 'm-ask'))!),
          isNotNull);

      // A meeting lands on the first offered time.
      await CalendarStore(db).upsertEvents([
        CalendarEvent(
          id: 'busy-1',
          startUtc: offered[0].startUtc,
          endUtc: offered[0].endUtc,
          showAs: 'busy',
        ),
      ], syncRun: 'run-1');
      final refresher = DraftSlotRefresher(
          store: store, calendar: CalendarStore(db), log: log);
      expect(await refresher.refresh(now: DateTime.now(), zone: la), 1);
      expect(await store.getDraftForMessage('email', 'm-ask'), isNull);
      expect(await store.workPayload('draft', 'email', 'm-ask'), asked,
          reason: 'the press survives the re-queue');

      await runAsked();
      final redrafted = await store.getDraftForMessage('email', 'm-ask');
      expect(redrafted, isNotNull,
          reason: 'neither no_reply_needed nor already_drafted skipped it');
      expect(redrafted!['body'],
          startsWith('Hi Dana — happy to go over the budget.\n\n'));
    });

    test('no calendar wired: the draft is what it always was', () async {
      await seedAsk();
      await runOne(
        DraftHandler(store, draftClient(draft: withOptions()),
            activityLog: log),
        id: 'm-ask',
      );
      final draft = (await store.getDraftForMessage('email', 'm-ask'))!;
      expect(draft['body'], 'Hi Dana — happy to go over the budget.');
      expect(draft['context_json'], isNull);
      expect(backend.asked, isEmpty);
    });
  });
}

/// A local improve target: nothing about it is third party.
const LlmTargetSpec _localTarget = LlmTargetSpec(
  id: 't-box',
  name: 'Box 27B',
  url: 'http://localhost:18100/v1/chat/completions',
  model: 'qwen3.8',
);

/// `find_meeting_times` answering [slots] (or [answerFor] by each call's
/// window, or throwing [throws]), each call recorded; every other method
/// throws.
class _SlotsBackend extends Fake implements CalendarBackend {
  _SlotsBackend(this.slots);

  final List<MeetingTimeSuggestion> slots;
  final List<List<String>> asked = [];
  final List<int> minutes = [];
  final List<(DateTime, DateTime)> windows = [];
  List<MeetingTimeSuggestion> Function(DateTime start, DateTime end)?
      answerFor;
  Object? throws;

  /// When set, what call number [n] (from 0, in call order) throws, or null
  /// to answer it.
  Object? Function(int n)? throwOn;

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
    String activityDomain = 'work',
  }) async {
    final n = asked.length;
    asked.add(attendees);
    minutes.add(durationMinutes);
    windows.add((windowStartUtc, windowEndUtc));
    final failure = throws ?? throwOn?.call(n);
    if (failure != null) throw failure;
    return MeetingTimes(
        suggestions: answerFor?.call(windowStartUtc, windowEndUtc) ?? slots);
  }
}
