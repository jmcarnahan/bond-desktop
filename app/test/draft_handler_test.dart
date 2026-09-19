import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attachments/attachment_retriever.dart';
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/draft_stream.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

/// An [LlmClient] that answers from a script, records what it was asked, and
/// never opens a socket.
class FakeLlm extends LlmClient {
  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];
  final List<int> tokenBudgets = [];

  /// Which task each call was, in order — `reply_decision` then `draft_reply`
  /// on the eager path, and `draft_reply` alone when a person asked.
  final List<String> schemaNames = [];

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    userMessages.add(user);
    schemaNames.add(schemaName);
    temperatures.add(temperature);
    tokenBudgets.add(maxTokens);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

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

/// A [FakeLlm] whose DRAFT call streams, in chunks that split the answer in
/// awkward places — mid-key, mid-word, mid-escape.
///
/// It overrides only the new method. `completeJson` is inherited untouched, so
/// the decision call still runs exactly as it does in every other test here,
/// and a handler given no bus still reaches the inherited one.
class StreamingFakeLlm extends FakeLlm {
  StreamingFakeLlm(super.script, {this.chunks = draftChunks, this.throws});

  /// The draft, in pieces. Concatenated they are the whole answer.
  final List<String> chunks;

  /// Thrown after the last chunk, for the failure case.
  final Object? throws;

  int streamedCalls = 0;

  @override
  Future<Map<String, dynamic>> completeJsonStreamed({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
    required void Function(String delta) onText,
  }) async {
    streamedCalls++;
    userMessages.add(user);
    schemaNames.add(schemaName);
    temperatures.add(temperature);
    tokenBudgets.add(maxTokens);
    for (final chunk in chunks) {
      onText(chunk);
      await Future<void>.delayed(Duration.zero);
    }
    final failure = throws;
    if (failure != null) throw failure;
    return jsonDecode(chunks.join()) as Map<String, dynamic>;
  }
}

/// One draft answer, cut into three.
const List<String> draftChunks = [
  '{"evidence":"Sarah is waiting on a date.","options":[{"stance":"Conf',
  'irm","reply_body":"Thursday still works."},{"stance":"Push","reply_bo'
      'dy":"Friday is safer."}],"reply_body":"Hi Sarah — Thursday',
  ' still works. I will send the addendum today."}',
];

/// The reply-decision call's answer. It comes FIRST in every script: the
/// handler asks whether a reply is owed before it spends anything writing one.
Map<String, dynamic> decision({
  bool needsReply = true,
  String reason = 'Sarah is waiting on a date.',
}) =>
    {'needs_reply': needsReply, 'reason': reason};

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
      final llm = FakeLlm([decision(), answer()]);

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

    test('the decision runs first, cheap, and the draft after it', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      // Both at zero: the same message must get the same verdict and the same
      // reply twice. The budgets differ because the answers do — a yes/no and
      // a sentence, then a reply long enough to send.
      expect(llm.temperatures, [0.0, 0.0]);
      expect(llm.tokenBudgets, [256, DraftHandler.draftMaxTokens]);
    });

    test('the draft stage lands done and stamps the row', () async {
      await seedInbound();

      await runOne(
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
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
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
      );

      expect((await progressOf('m2'))['outcome'], 'done');
    });
  });

  group('the decision', () {
    test('a no stores nothing and spends one call', () async {
      await seedInbound();
      final llm = FakeLlm([
        decision(needsReply: false, reason: 'A receipt, nobody is waiting.'),
        answer(),
      ]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, hasLength(1),
          reason: 'the drafting model is never reached');
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      // A real end state: the model read the thread and said no reply is owed.
      expect((await progressOf('m2'))['draft_state'], 'skipped');
    });

    test('a no records both the verdict and the sentence behind it', () async {
      // `_skip`'s payload, pinned once for the four ends that share it: the
      // item is `skipped` rather than `ok`, `reason` says which end, and `why`
      // carries the model's own sentence — which only this end has.
      await seedInbound();
      final log = _Recorder();

      await runOne(DraftHandler(
        store,
        FakeLlm([
          decision(
            needsReply: false,
            reason: 'A receipt, nobody is waiting.',
          ),
          answer(),
        ]),
        activityLog: log,
        progress: progress,
      ));

      expect(log.notes['reason'], 'no_reply_needed');
      expect(log.notes['why'], 'A receipt, nobody is waiting.');
    });

    test('reads the message and the thread before it', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.first, contains('It expires Wednesday.'));
      expect(llm.userMessages.first, contains('What is the current expiry?'));
      expect(llm.userMessages.first, contains('Decide about ONLY this'));
    });

    test('and never a message that landed after the one it is judging',
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
      final llm = FakeLlm([decision(), answer()]);

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
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);

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
      final llm = FakeLlm([decision(), answer()]);
      final log = _Recorder();

      await DraftHandler(store, llm, activityLog: log, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        'payload_json': '{not json at all',
      });

      // Unreadable is "nobody asked", never "skip the judgement": the flag
      // only ever skips work when it was definitely set.
      expect(llm.schemaNames, ['reply_decision', 'draft_reply']);
      expect(log.notes['decision'], isNull);
    });

    test('only the literal true skips it', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer()]);

      await DraftHandler(store, llm, progress: progress).run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm2',
        // A string somebody hand-edited into the table is not a person
        // pressing a button.
        'payload_json': '{"asked":"true"}',
      });

      expect(llm.schemaNames, ['reply_decision', 'draft_reply']);
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

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('style_examples'));
      expect(llm.userMessages.last, contains('I will confirm by noon'));
    });

    test('and nothing when the user has never written to them', () async {
      await seedOutbound(key: 'conv-0', to: 'someone.else@x.com');
      await seedInbound();

      final llm = FakeLlm([decision(), answer()]);
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

      final quiet = FakeLlm([decision(), answer()]);
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

      final spoken = FakeLlm([decision(), answer()]);
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

      final llm = FakeLlm([decision(), answer()]);
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

      final llm = FakeLlm([decision(), answer()]);
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

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('storyline_summary'));
      expect(llm.userMessages.last, contains('lock expires 9/10'));
    });

    test('the whole thread, both directions', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');

      final llm = FakeLlm([decision(), answer()]);
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

      final llm = FakeLlm([decision(), answer()]);
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

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, isNot(contains('[[att:')));
      expect(llm.userMessages.last, contains('Signed copy attached'));
    });
  });

  group('a chat drafts through the same handler', () {
    test('a file-only chat message reaches the model as what was shared',
        () async {
      // The reply-decision call is the one that matters: it is asked whether a
      // message needs an answer, and a body that is nothing but a marker looks
      // to it like a message that said nothing at all.
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
      final llm = FakeLlm([decision(), answer()]);

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.first, contains('Shared a file: Contract-v2.docx'));
      expect(llm.userMessages.first, isNot(contains('[[att:')));
    });

    test('and gets the chat channel note, not the email one', () async {
      await seedChat();
      final llm = FakeLlm([
        decision(),
        answer(replyBody: 'Sending it over now.'),
      ]);

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
      final llm = FakeLlm([decision(), answer()]);

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
      final llm = FakeLlm([decision(), answer()]);

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
    test('one retrieval reaches both the decision and the draft', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer()]);
      final retriever = FakeRetriever(store, answer: [excerpt()]);

      await runOne(DraftHandler(store, llm, attachments: retriever));

      // ONE call, two prompts. A second pass would be a second embedding call
      // for an answer that cannot come back different.
      expect(retriever.calls, 1);
      expect(llm.userMessages.length, 2);
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
        DraftHandler(store, FakeLlm([decision(), answer()]),
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
      final llm = FakeLlm([decision(), answer()]);

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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        DraftHandler(store, FakeLlm([decision(), answer()]),
            attachments: retriever),
      );

      // The draft is the product; the citations are what make it better.
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });
  });

  group("the owner's own directories in the prompt", () {
    test('one pack reaches both the decision and the draft', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer()]);
      final directories = FakeContextRetriever(store, ContextStore(db),
          answer: directoryPack());

      await runOne(DraftHandler(store, llm, contextDirs: directories));

      // ONE call, two prompts. The directories cannot have changed between
      // the two, so a second pass would buy nothing and cost a vector read.
      expect(directories.calls, 1);
      expect(llm.userMessages.length, 2);
      for (final sent in llm.userMessages) {
        expect(sent, contains('<untrusted_data source="directory_excerpts">'));
        expect(sent, contains('Q4 rates hold at nine.'));
      }
      // The guidance is the draft's alone: whether an answer is OWED is not a
      // question about how one should read.
      expect(llm.userMessages.last, contains('source="directory_guidance"'));
      expect(llm.userMessages.first,
          isNot(contains('source="directory_guidance"')));
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
        DraftHandler(store, FakeLlm([decision(), answer()]),
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
          FakeLlm([decision(), answer()]),
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

      await runOne(DraftHandler(store, FakeLlm([decision(), answer()])));

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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
        FakeLlm([decision(), answer()]),
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
      final llm = FakeLlm([decision(), answer()]);

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
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          'an existing draft');
      // Done, not skipped: this message has its suggestion.
      expect((await progressOf('m2'))['draft_state'], 'done');
    });

    test('a message that vanished is done, not failed', () async {
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('the user\'s own message is skipped', () async {
      await seedOutbound();
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress), id: 'o1');

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'o1'), isNull);
      expect((await progressOf('o1'))['draft_state'], 'skipped');
    });

    test('a message triage gated after the enqueue is skipped', () async {
      await seedInbound(triageStatus: 'skipped', gateReason: 'newsletter');
      final llm = FakeLlm([decision(), answer()]);

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
      final llm = FakeLlm([decision(), answer()]);

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
      final llm = FakeLlm([
        decision(),
        answer(options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
          {'stance': 'Propose Monday', 'reply_body': 'Could we say Monday?'},
        ]),
      ]);

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
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
      );

      expect((await store.getDraftForMessage('email', 'm2'))!['options_json'],
          isNull);
    });

    test('a half-written option does not reach the row', () async {
      await seedInbound();
      final llm = FakeLlm([
        decision(),
        answer(options: const [
          {'stance': '', 'reply_body': 'unlabelled'},
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
        ]),
      ]);

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
      final llm = FakeLlm([
        decision(),
        answer(replyBody: '   ', options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday works.'},
        ]),
      ]);

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('throws rather than storing a blank suggestion', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer(replyBody: '   ')]);

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('and the worker retries it once, then gives up', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final llm = FakeLlm([
        decision(),
        answer(replyBody: ''),
        decision(),
        answer(replyBody: ''),
      ]);
      final worker = AiWorker(
        store,
        handlers: [DraftHandler(store, llm, progress: progress)],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await worker.pump();

      expect(await store.workCounts('draft'), {'error': 1});
      expect(llm.userMessages, hasLength(4),
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
            FakeLlm([decision(), answer()]),
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

    test('a server that is down during the DECISION leaves the item queued',
        () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([const LlmUnavailableException('not reachable')]),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'pending': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      // Waiting, not finished and not failed: nothing about this message went
      // wrong, and the stage must not read terminal.
      expect((await progressOf('m2'))['draft_state'], 'pending');
    });

    test('and one that goes down during the DRAFT does the same', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([
              decision(),
              const LlmUnavailableException('not reachable'),
            ]),
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
      expect(DraftHandler(store, FakeLlm([decision()])).concurrency, 1);
    });

    test('it reads the closure, every time it is asked', () {
      // The width is a SETTING — Settings › Models › Drafts in flight — and
      // `AiWorker._drainAll` asks before each launch. A handler that cached
      // the number would leave a change waiting for the next launch of the
      // app; `ai_worker_lanes_test.dart` pins the other half, that the worker
      // re-reads it mid-drain.
      var width = 2;
      final handler = DraftHandler(
        store,
        FakeLlm([decision()]),
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
          StreamingFakeLlm([decision()]),
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
      final llm = StreamingFakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.streamedCalls, 0);
      // Decision then draft, both through `completeJson` — which is what every
      // other test in this file, and every other fake in the suite, relies on.
      expect(llm.schemaNames.length, 2);
      expect(llm.schemaNames.last, 'draft_reply');
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          startsWith('Hi Sarah — Friday works.'));
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
            StreamingFakeLlm(
              [decision()],
              throws: const LlmFormatException('cut off mid-object'),
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
            StreamingFakeLlm([decision()]),
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
            StreamingFakeLlm(
              [decision()],
              chunks: const [
                '{"evidence":"nothing to say","options":[],"reply_body":""}',
              ],
            ),
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
}
