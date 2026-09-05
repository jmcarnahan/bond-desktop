import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart'
    show NeedsYouTask, needsYouDefaultRules, needsYouOutputContract;
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// An [LlmClient] that answers from a script and never opens a socket, with a
/// hook that runs at the moment of the call — which is how the drain-order
/// test below observes the mailbox as extraction found it.
///
/// It keeps the last prompt it was handed, because half of what this handler
/// does happens on the way IN: which rules it read, whether it knew who the
/// owner was, whether it waited on triage.
class FakeLlm extends LlmClient {
  final Map<String, dynamic> answer;
  final Future<void> Function()? onCall;
  int calls = 0;

  /// The last call's two halves, or null before the first call.
  String? system;
  String? user;

  FakeLlm(this.answer, {this.onCall})
      : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    calls++;
    this.system = system;
    this.user = user;
    await onCall?.call();
    return Map<String, dynamic>.from(answer);
  }
}

/// A model server that is there and answers badly. Not [LlmUnavailableException]
/// on purpose: the worker parks on that one, and what the handler owes either
/// way is the same — leave the verdict NULL and let the exception out.
class BrokenLlm extends LlmClient {
  BrokenLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async =>
      throw const LlmFormatException('nothing that parses');
}

/// What the model says about a message that names the owner.
const Map<String, dynamic> needsYouYes = {
  'evidence': 'Priya asks Alex to sign off on the wayfinding sheet.',
  'needs_you': true,
  'confidence': 'high',
};

/// An [EmbeddingsClient] over a scripted socket, so extraction can finish
/// without a server.
EmbeddingsClient fakeEmbeddings() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.6, 0.8]
              }
            ]
          }),
          200,
        );
      }),
    );

const Map<String, dynamic> extraction = {
  'evidence': 'Dana wants the DPA looked at.',
  'topics': ['DPA'],
  'people': ['Dana'],
  'organizations': ['Acme'],
  'project': 'Acme renewal',
  'intent': 'request',
  'importance': 'high',
};

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed({
    String source = 'teams',
    String id = 't1',
    String direction = 'inbound',
    int addressedMe = 1,
    String triageStatus = 'pending',
    String? gateReason,
    String body = 'Legal wants a look at the DPA.',
    String receivedAt = '2026-08-29T10:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'chat-1',
      'direction': direction,
      'from_name': 'Dana',
      'from_address': 'teams:u-1',
      'to_json': '["lo@x.com"]',
      'received_at': receivedAt,
      'body_text': body,
      'addressed_me': addressedMe,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
  }

  /// The shape the model actually gets: mail, below the floor, so the floor
  /// says nothing and the judgement passes to the model branch.
  Future<void> seedAmbiguousMail({
    String id = 'm1',
    String triageStatus = 'pending',
    String body = 'Alex, can you sign off on the wayfinding sheet?',
  }) =>
      seed(
        source: 'email',
        id: id,
        addressedMe: 1,
        triageStatus: triageStatus,
        body: body,
      );

  Future<void> runOne(
    NeedsYouHandler handler, {
    String source = 'teams',
    String id = 't1',
  }) =>
      handler.run({
        'task_kind': 'needs_you',
        'source': source,
        'entity_id': id,
      });

  Future<Map<String, Object?>> verdictOf(String source, String id) async {
    final row = (await store.getMessageRow(source, id))!;
    return {
      'verdict': row['needs_you_verdict'],
      'reason': row['needs_you_reason'],
    };
  }

  group('the deterministic floor', () {
    test('a direct chat is written down as a yes, with its reason', () async {
      await seed();
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm));

      expect(await verdictOf('teams', 't1'),
          {'verdict': 1, 'reason': 'teams_direct'});
      expect(llm.calls, 0, reason: 'the floor settled it');
    });

    test('the floor short-circuits the model, whatever the model would say',
        () async {
      // Raise-only in the direction that matters here: the floor runs first
      // and the model is never asked, so a model that would have answered no
      // cannot take a direct chat off the list.
      await seed();
      final llm = FakeLlm(const {
        'evidence': 'nothing here points at the owner',
        'needs_you': false,
        'confidence': 'high',
      });

      await runOne(NeedsYouHandler(store, llm));

      expect(llm.calls, 0);
      expect((await verdictOf('teams', 't1'))['verdict'], 1);
    });

    test('sole-recipient mail is nothing the floor has an opinion about',
        () async {
      // The floor says nothing about mail, and it must not write when it says
      // nothing: this row's verdict is the model's, which the reason it
      // carries is what proves — `teams_direct` here would be the floor
      // reading "the only address on the envelope" as an answer.
      await seed(source: 'email', id: 'm1', addressedMe: 1);
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.calls, 1);
      expect((await verdictOf('email', 'm1'))['reason'],
          isNot('teams_direct'));
    });

    test('a group chat nobody named goes to the model too', () async {
      await seed(addressedMe: 0);
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm));

      expect(llm.calls, 1);
      expect((await verdictOf('teams', 't1'))['reason'], isNot('teams_direct'));
    });
  });

  group('guards', () {
    test('a message gated after the enqueue is left unjudged', () async {
      // The race this pins: the judgement is queued at sync time while the
      // message is still `pending`; triage then gates it. A newsletter must
      // not come back carrying a verdict.
      await seed(
        source: 'email',
        id: 'm1',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect((await verdictOf('email', 'm1'))['verdict'], isNull);
      expect(llm.calls, 0, reason: 'a gated message costs no model time');
    });

    test('a chat skipped-by-birth is still judged', () async {
      // `teams_source` is the legacy tolerance for chats stored before chats
      // were triaged — not a verdict, so it must not gate this pass either.
      await seed(triageStatus: 'skipped', gateReason: 'teams_source');

      await runOne(NeedsYouHandler(store, FakeLlm(needsYouYes)));

      expect((await verdictOf('teams', 't1'))['verdict'], 1);
    });

    test('the owner writing in their own chat is left unjudged', () async {
      await seed(direction: 'outbound');
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm));

      expect((await verdictOf('teams', 't1'))['verdict'], isNull);
      expect(llm.calls, 0);
    });

    test('a message deleted before the worker reached it completes', () async {
      // Nothing to judge and nothing wrong: the item is done, not failed.
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'gone');

      expect(await store.getMessageRow('email', 'gone'), isNull);
      expect(llm.calls, 0);
    });
  });

  group('the model branch', () {
    test('an ambiguous message is judged, and the evidence is the reason',
        () async {
      // Sole-recipient mail: the floor says nothing about it, which is not a
      // verdict, so the model reads the text.
      await seedAmbiguousMail();
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.calls, 1);
      expect(await verdictOf('email', 'm1'), {
        'verdict': 1,
        'reason': 'Priya asks Alex to sign off on the wayfinding sheet.',
      });
    });

    test('a no is written down as a no, not left as silence', () async {
      // The whole reason this branch exists: NULL is "never judged" and keeps
      // the row on the worklist forever. Only the model may write the 0.
      await seedAmbiguousMail();
      final llm = FakeLlm(const {
        'evidence': 'A newsletter; nothing in it asks the owner for anything.',
        'needs_you': false,
        'confidence': 'high',
      });

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(await verdictOf('email', 'm1'), {
        'verdict': 0,
        'reason': 'A newsletter; nothing in it asks the owner for anything.',
      });
    });

    test('a hesitant yes is a no', () async {
      // The raise policy. The verdict buys an interruption, and "possibly" is
      // not grounds for one.
      await seedAmbiguousMail();
      final llm = FakeLlm(const {
        'evidence': 'It might be asking the owner to look at the numbers.',
        'needs_you': true,
        'confidence': 'low',
      });

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect((await verdictOf('email', 'm1'))['verdict'], 0);
    });

    test('a model that fails leaves the verdict unjudged and throws', () async {
      // The row stays on the worklist and the worker's retry machinery owns
      // what happens next. A handler that swallowed this would write a 0 the
      // model never said.
      await seedAmbiguousMail();

      await expectLater(
        runOne(NeedsYouHandler(store, BrokenLlm()), source: 'email', id: 'm1'),
        throwsA(isA<LlmFormatException>()),
      );
      expect((await verdictOf('email', 'm1'))['verdict'], isNull);
    });

    test('it judges a message triage has not finished with', () async {
      // This stage reads the body, never triage's verdicts: the queue hands
      // over rows whose `triage_status` is still `pending`, and waiting on
      // them would make the verdict depend on which drain got there first.
      await seedAmbiguousMail(triageStatus: 'pending');
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.calls, 1);
      expect(llm.user, contains('Alex, can you sign off'));
      expect((await verdictOf('email', 'm1'))['verdict'], 1);
    });
  });

  group('what the model is told', () {
    test("the owner's rules replace the system prompt's body", () async {
      await seedAmbiguousMail();
      await store.setPref(needsYouRulesKey, 'Invoices always need me.');
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.system, contains('Invoices always need me.'));
      // The body is theirs; the answer's shape never is.
      expect(llm.system, contains(needsYouOutputContract));
      expect(llm.system, isNot(contains(needsYouDefaultRules)));
      // And nothing about the rules is in the user message any more.
      expect(llm.user, isNot(contains('needs_you_rules')));
    });

    test('and an empty pref means the default prompt', () async {
      await seedAmbiguousMail();
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.system, const NeedsYouTask().systemPrompt);
    });

    test('an unchanged pref reuses the very same prompt string', () async {
      // Identity, not equality: llama-server caches the KV prefix on the bytes,
      // so a prompt rebuilt per item would pay to re-prime it every message
      // even though nobody edited anything.
      await seedAmbiguousMail();
      await seedAmbiguousMail(id: 'm2');
      await store.setPref(needsYouRulesKey, 'Invoices always need me.');
      final llm = FakeLlm(needsYouYes);
      final handler = NeedsYouHandler(store, llm);

      await runOne(handler, source: 'email', id: 'm1');
      final first = llm.system;
      await runOne(handler, source: 'email', id: 'm2');
      final second = llm.system;

      expect(identical(first, second), isTrue);
    });

    test('a pref edited mid-drain reaches the next item', () async {
      // Read per item for exactly this: someone who rewrites their rules while
      // the drain is running wants the rest of the drain to use them.
      await seedAmbiguousMail();
      await seedAmbiguousMail(id: 'm2');
      await store.setPref(needsYouRulesKey, 'Invoices always need me.');
      final llm = FakeLlm(needsYouYes);
      final handler = NeedsYouHandler(store, llm);

      await runOne(handler, source: 'email', id: 'm1');
      await store.setPref(needsYouRulesKey, 'Only the studio lease needs me.');
      await runOne(handler, source: 'email', id: 'm2');

      expect(llm.system, contains('Only the studio lease needs me.'));
      expect(llm.system, isNot(contains('Invoices always need me.')));
    });

    test('a pref that just retypes the defaults stays on the default prompt',
        () async {
      // The pane normalizes a default-equal save back to the empty pref, but a
      // pref written any other way must not fork the prompt into a
      // non-const copy of the same words.
      await seedAmbiguousMail();
      await store.setPref(needsYouRulesKey, needsYouDefaultRules);
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(identical(llm.system, const NeedsYouTask().systemPrompt), isTrue);
    });

    test('the owner is named, from the lookup', () async {
      await seedAmbiguousMail();
      final llm = FakeLlm(needsYouYes);
      final handler = NeedsYouHandler(
        store,
        llm,
        owner: () async =>
            (name: 'Alex Rivera', address: 'alex.rivera@rivermail.example.com'),
      );

      await runOne(handler, source: 'email', id: 'm1');

      expect(
        llm.user,
        contains('The owner of this inbox is Alex Rivera '
            '<alex.rivera@rivermail.example.com>.'),
      );
    });

    test('and the lookup is asked once, however many messages it judges',
        () async {
      // It is a keychain read, and the answer only changes on sign-out — which
      // disposes the provider that built the handler.
      await seedAmbiguousMail();
      await seedAmbiguousMail(id: 'm2');
      final llm = FakeLlm(needsYouYes);
      var lookups = 0;
      final handler = NeedsYouHandler(
        store,
        llm,
        owner: () async {
          lookups++;
          return (name: 'Alex Rivera', address: null);
        },
      );

      await runOne(handler, source: 'email', id: 'm1');
      await runOne(handler, source: 'email', id: 'm2');

      expect(llm.calls, 2);
      expect(lookups, 1);
    });

    test('a lookup that failed is not the answer forever', () async {
      // A keychain hiccup on the first read must not be memoized: the item it
      // happened under is judged with no owner named, and the NEXT item asks
      // again rather than inheriting the failure until the app restarts.
      await seedAmbiguousMail();
      await seedAmbiguousMail(id: 'm2');
      final llm = FakeLlm(needsYouYes);
      var lookups = 0;
      final handler = NeedsYouHandler(
        store,
        llm,
        owner: () async {
          lookups++;
          if (lookups == 1) throw StateError('keychain unavailable');
          return (name: 'Alex Rivera', address: null);
        },
      );

      await runOne(handler, source: 'email', id: 'm1');
      expect(llm.user, isNot(contains('The owner of this inbox is')));
      expect((await verdictOf('email', 'm1'))['verdict'], 1);

      await runOne(handler, source: 'email', id: 'm2');
      expect(lookups, 2);
      expect(llm.user, contains('The owner of this inbox is Alex Rivera.'));
    });

    test('a prompt with no owner to name says nothing about one', () async {
      await seedAmbiguousMail();
      final llm = FakeLlm(needsYouYes);

      await runOne(NeedsYouHandler(store, llm), source: 'email', id: 'm1');

      expect(llm.user, isNot(contains('The owner of this inbox is')));
    });
  });

  group('drain order', () {
    test('the verdict is on the row before extraction reads it', () async {
      await seed();
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'Acme renewal',
        'state': 'needs_reply',
        'last_message_at': '2026-08-29T10:00:00Z',
      });
      await store.enqueueWork('extract', 'teams', 't1');
      await store.enqueueWork('needs_you', 'teams', 't1');

      Object? verdictWhenExtractRan;
      final llm = FakeLlm(
        extraction,
        onCall: () async {
          verdictWhenExtractRan =
              (await store.getMessageRow('teams', 't1'))!['needs_you_verdict'];
        },
      );
      // Provider order: needs-you, then extraction. The whole reason for it is
      // this assertion — extraction's pre-gate reads the row as it stands, so
      // a verdict written after it would be a verdict extraction never saw.
      // The seeded row is a direct chat, so the floor settles it and the one
      // model call this drain makes is extraction's.
      final worker = AiWorker(
        store,
        handlers: [
          NeedsYouHandler(store, llm),
          ExtractHandler(store, llm, fakeEmbeddings()),
        ],
      );

      await worker.pump();

      expect(llm.calls, 1, reason: 'extraction really ran');
      expect(verdictWhenExtractRan, 1);
      expect(await store.workCounts('needs_you', sources: const ['teams']),
          {'done': 1});
      expect(await store.workCounts('extract', sources: const ['teams']),
          {'done': 1});
    });
  });
}
