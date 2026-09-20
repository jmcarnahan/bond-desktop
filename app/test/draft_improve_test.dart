import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:bond_inbox/models/draft_request.dart';
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/cloud_drafts.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_auth_session.dart';
import 'fixtures/test_db.dart';

/// **Improve with `<target>`**: the same draft prompt, sent again to a target
/// the owner picked, replacing the suggestion in place.
///
/// The claims this file holds are the ones the button's whole value rests on.
/// The improve call sends the SAME schema the local draft did, so nothing was
/// forked into a second prompt. A failure of any kind costs a sentence and
/// never the local draft. Every prompt that leaves for somebody else's
/// machine is counted BEFORE it goes, so a call that fails still spends its
/// share of the day. And the cap stops all three doors at once: the button,
/// the standing rule, and a prefetch whose draft stage points off this
/// machine.

/// An [LlmClient] that answers from a script and never opens a socket.
///
/// A private copy rather than an import of `draft_handler_test.dart`'s: a
/// test file that imports another test file's helpers ties the two together
/// at exactly the seam each of them exists to pin separately.
class FakeLlm extends LlmClient {
  final List<Object> script;

  /// Which task each call was, in order. The improve call's is `draft_reply`,
  /// because it IS the draft task.
  final List<String> schemaNames = [];

  /// The prompt bytes each call carried, in order — what the phase's whole
  /// claim rests on: an improve sends exactly what the local draft sent.
  final List<String> systems = [];
  final List<String> users = [];

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  int get calls => schemaNames.length;

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
    schemaNames.add(schemaName);
    systems.add(system);
    users.add(user);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// A backend that would notice if a draft test reached for it. None does.
class _NeverMail implements MailBackend {
  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// An activity log that keeps what a handler told it, for the paths that
/// record nothing of their own.
class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};

  @override
  void note(Map<String, Object?> detail) => notes.addAll(detail);
}

/// The reply-decision call's answer, first in every prefetch's script.
Map<String, dynamic> decision() =>
    {'needs_reply': true, 'reason': 'Robin is waiting on a date.'};

Map<String, dynamic> answer({
  String evidence = 'Robin is asking whether the review still lands Thursday.',
  String replyBody = 'Thursday still works. I will send the notes today.',
  List<Map<String, String>> options = const [],
}) =>
    {'evidence': evidence, 'reply_body': replyBody, 'options': options};

/// The box on the tunnel: local, so nothing about it is third party.
const LlmTargetSpec boxTarget = LlmTargetSpec(
  id: 't-box',
  name: 'Box 27B',
  url: 'http://localhost:18100/v1/chat/completions',
  model: 'qwen3.8',
);

/// Somebody else's machine, by its wire.
const LlmTargetSpec cloudTarget = LlmTargetSpec(
  id: 't-cloud',
  name: 'Claude',
  url: 'https://example.com/converse',
  model: 'a-big-model',
  wire: LlmWire.bedrockConverse,
  streams: false,
);

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedInbound({
    String id = 'm1',
    String key = 'conv-1',
    bool needsYou = false,
    String urgency = 'normal',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Re: Review date',
      'from_name': 'Robin Ellery',
      'from_address': 'robin@example.com',
      'received_at': '2026-09-18T10:00:00Z',
      'body_text': 'Does Thursday still work for the review?',
      'triage_status': 'pending',
    });
    // The needs-you pass writes these, not the ingest — so they are set the
    // way the pass sets them rather than squeezed into the upsert.
    await db.customUpdate(
      'UPDATE messages SET needs_you_verdict = ?, urgency = ? '
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(needsYou ? 1 : 0),
        Variable(urgency),
        Variable('email'),
        Variable(id),
      ],
    );
  }

  Future<void> seedDraft({
    String id = 'm1',
    String key = 'conv-1',
    String body = 'The local model wrote this one.',
    String? contextJson,
  }) =>
      store.upsertDraft(
        source: 'email',
        conversationKey: key,
        replyToMessageId: id,
        body: body,
        evidence: 'The local evidence sentence.',
        contextJson: contextJson,
      );

  /// One `cloud` count against today, as the handler would have written it.
  Future<void> seedCloudUse({int count = 1}) => store.recordActivity(
        kind: 'draft_improve',
        status: 'ok',
        source: 'email',
        entityId: 'm0',
        detailJson: jsonEncode({'cloud': count}),
      );

  DraftRoutes routes({
    LlmTargetSpec? draft,
    LlmTargetSpec? improve,
    bool standing = false,
    CloudDraftLedger? ledger,
  }) =>
      DraftRoutes(
        draftTarget: () => draft,
        improveTarget: () => improve,
        standing: () => standing,
        ledger: ledger,
      );

  CloudDraftLedger ledgerOf(int cap) =>
      CloudDraftLedger(store, cap: () => cap);

  Future<List<Map<String, Object?>>> improveRows() async => [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'draft_improve') row,
      ];

  Future<Map<String, Object?>> lastImproveRow() async {
    final rows = await improveRows();
    expect(rows, hasLength(1));
    return rows.first;
  }

  Map<String, Object?> detailOf(Map<String, Object?> row) =>
      jsonDecode(row['detail_json'] as String? ?? '{}')
          as Map<String, Object?>;

  group('the button', () {
    test('rewrites the body, the evidence and the options in place', () async {
      await seedInbound();
      await seedDraft();
      final improveLlm = FakeLlm([
        answer(
          evidence: 'The improved evidence.',
          replyBody: 'Thursday works, and I will bring the notes.',
          options: [
            {'stance': 'Confirm', 'reply_body': 'Thursday works.'},
          ],
        ),
      ]);
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: improveLlm,
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );

      expect(await handler.improve('email', 'm1'), isNull);

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['body'], 'Thursday works, and I will bring the notes.');
      expect(draft['evidence'], 'The improved evidence.');
      expect(draft['status'], 'suggested');
      expect(draft['options_json'], contains('Confirm'));
      expect(
        DraftProvenance.decode(draft['context_json'] as String?)?.improvedBy,
        't-box',
      );
      // The SAME task, not a second prompt of its own.
      expect(improveLlm.schemaNames, ['draft_reply']);
    });

    test('sends the very bytes the local draft sent', () async {
      // The phase's whole claim, pinned: a prefetch writes the local draft
      // through the queue, then the button rewrites it — and the two draft
      // prompts are one string, system and user alike.
      await seedInbound();
      final draftLlm = FakeLlm([decision(), answer()]);
      final improveLlm = FakeLlm([answer(replyBody: 'The better answer.')]);
      final handler = DraftHandler(
        store,
        draftLlm,
        improveClient: improveLlm,
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );
      await handler.run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm1',
        'payload_json': DraftRequest().encode(),
      });
      expect(draftLlm.schemaNames, ['reply_decision', 'draft_reply']);

      expect(await handler.improve('email', 'm1'), isNull);

      expect(improveLlm.systems.single, draftLlm.systems.last);
      expect(improveLlm.users.single, draftLlm.users.last);
    });

    test('records one row naming the target, and no cloud count for a local '
        'one', () async {
      await seedInbound();
      await seedDraft();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([answer(replyBody: 'Improved.')]),
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );

      await handler.improve('email', 'm1');

      final row = await lastImproveRow();
      expect(row['status'], 'ok');
      expect(row['entity_id'], 'm1');
      final detail = detailOf(row);
      expect(detail['target'], 't-box');
      expect(detail['chars'], 'Improved.'.length);
      expect(detail.containsKey('cloud'), isFalse);
    });

    test('a third-party target counts one against the day', () async {
      await seedInbound();
      await seedDraft();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([answer(replyBody: 'Improved.')]),
        activityLog: ActivityLog(store),
        routes: routes(improve: cloudTarget, ledger: ledgerOf(50)),
      );

      await handler.improve('email', 'm1');

      expect(detailOf(await lastImproveRow())['cloud'], 1);
    });

    test('a server that is not answering keeps the local draft, and the '
        'prompt that left still counts', () async {
      await seedInbound();
      await seedDraft();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([
          const LlmUnavailableException('the target is not answering'),
        ]),
        activityLog: ActivityLog(store),
        routes: routes(improve: cloudTarget, ledger: ledgerOf(50)),
      );

      // A category and the target's NAME, never the client's own sentence:
      // that one spells out the endpoint it dialled.
      expect(
        await handler.improve('email', 'm1'),
        'Improve failed. Claude did not answer.',
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['body'], 'The local model wrote this one.');
      final row = await lastImproveRow();
      expect(row['status'], 'error');
      expect(detailOf(row)['cloud'], 1);
      expect(detailOf(row)['error'], 'unavailable');
      expect(row['detail_json'], isNot(contains('never-dialled')));
    });

    test('a third-party target with nothing counting it is a wiring bug, '
        'not an uncapped call', () async {
      await seedInbound();
      await seedDraft();
      final improveLlm = FakeLlm([answer()]);
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: improveLlm,
        activityLog: ActivityLog(store),
        routes: routes(improve: cloudTarget),
      );

      await expectLater(
        handler.improve('email', 'm1'),
        throwsA(isA<StateError>()),
      );
      expect(improveLlm.calls, 0);
    });

    test('an empty answer is a sentence, and the local draft stays', () async {
      await seedInbound();
      await seedDraft();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([answer(replyBody: '')]),
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );

      expect(
        await handler.improve('email', 'm1'),
        'The target returned an empty draft, so the local one is kept.',
      );
      expect(
        (await store.getDraftForMessage('email', 'm1'))!['body'],
        'The local model wrote this one.',
      );
      expect(detailOf(await lastImproveRow())['error'], 'empty');
    });

    test('at the cap it says so and dials nothing', () async {
      await seedInbound();
      await seedDraft();
      await seedCloudUse();
      await seedCloudUse();
      final improveLlm = FakeLlm([answer(replyBody: 'Never written.')]);
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: improveLlm,
        activityLog: ActivityLog(store),
        routes: routes(improve: cloudTarget, ledger: ledgerOf(2)),
      );

      expect(
        await handler.improve('email', 'm1'),
        "Cloud drafts are at today's cap of 2. Raise it under Settings, "
        'Processing.',
      );
      expect(improveLlm.calls, 0);
      expect(
        (await store.getDraftForMessage('email', 'm1'))!['body'],
        'The local model wrote this one.',
      );
      final rows = await improveRows();
      // The two seeded rows are `draft_improve` too, so the newest is this
      // attempt's and the older two are the day's history.
      expect(rows.first['status'], 'skipped');
      expect(detailOf(rows.first)['reason'], 'cloud_cap');
    });

    test('the cap does not apply to a target on this machine', () async {
      await seedInbound();
      await seedDraft();
      await seedCloudUse();
      await seedCloudUse();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([answer(replyBody: 'Improved locally.')]),
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget, ledger: ledgerOf(2)),
      );

      expect(await handler.improve('email', 'm1'), isNull);
      expect(
        (await store.getDraftForMessage('email', 'm1'))!['body'],
        'Improved locally.',
      );
    });

    test('an unrouted stage says where to point it, and dials nothing',
        () async {
      await seedInbound();
      await seedDraft();
      final improveLlm = FakeLlm([answer()]);
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: improveLlm,
        activityLog: ActivityLog(store),
        routes: routes(),
      );

      expect(
        await handler.improve('email', 'm1'),
        'Pick a target for Improve a draft under Settings, Models first.',
      );
      expect(improveLlm.calls, 0);
      final row = await lastImproveRow();
      expect(row['status'], 'skipped');
      expect(detailOf(row)['reason'], 'unrouted');
    });

    test('a message that is gone, and a message with no draft, each say so',
        () async {
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        improveClient: FakeLlm([answer()]),
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );

      expect(
        await handler.improve('email', 'gone'),
        'This message is no longer stored.',
      );

      await seedInbound();
      expect(
        await handler.improve('email', 'm1'),
        'There is no draft to improve yet.',
      );

      final reasons = [
        for (final row in await improveRows()) detailOf(row)['reason'],
      ];
      expect(reasons, containsAll(<String>['deleted', 'no_draft']));
    });

    test('a routed stage with no client is a wiring bug, not a sentence',
        () async {
      await seedInbound();
      await seedDraft();
      final handler = DraftHandler(
        store,
        FakeLlm([answer()]),
        activityLog: ActivityLog(store),
        routes: routes(improve: boxTarget),
      );

      await expectLater(
        handler.improve('email', 'm1'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the standing rule', () {
    /// A prefetched draft for an urgent message that needs the owner.
    Future<_Recorder> runStanding({
      bool standing = true,
      bool needsYou = true,
      String urgency = 'urgent',
      bool asked = false,
      LlmTargetSpec? draft,
      LlmTargetSpec? improve = cloudTarget,
      CloudDraftLedger? ledger,
      required FakeLlm improveLlm,
    }) async {
      await seedInbound(needsYou: needsYou, urgency: urgency);
      final log = _Recorder();
      final handler = DraftHandler(
        store,
        // An asked-for draft makes no decision call, so its script is the
        // draft answer alone.
        FakeLlm(asked ? [answer()] : [decision(), answer()]),
        improveClient: improveLlm,
        activityLog: log,
        routes: routes(
          draft: draft,
          improve: improve,
          standing: standing,
          ledger: ledger,
        ),
      );
      await handler.run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm1',
        'payload_json': DraftRequest(asked: asked).encode(),
      });
      return log;
    }

    test('replaces the local draft with the target\'s answer, on one row',
        () async {
      final improveLlm = FakeLlm([answer(replyBody: 'The better answer.')]);
      final log = await runStanding(
        improveLlm: improveLlm,
        ledger: ledgerOf(50),
      );

      expect(improveLlm.calls, 1);
      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['body'], 'The better answer.');
      expect(
        DraftProvenance.decode(draft['context_json'] as String?)?.improvedBy,
        't-cloud',
      );
      expect(log.notes['improved'], 't-cloud');
      expect(log.notes['improved_chars'], 'The better answer.'.length);
      expect(log.notes['cloud'], 1);
    });

    test('a third-party DRAFT stage as well counts two prompts leaving',
        () async {
      final log = await runStanding(
        improveLlm: FakeLlm([answer(replyBody: 'The better answer.')]),
        draft: cloudTarget,
        ledger: ledgerOf(50),
      );

      expect(log.notes['cloud'], 2);
      expect(log.notes['improve_target'], 't-cloud');
    });

    test('off, not urgent, not needing you, or asked for: one call only',
        () async {
      for (final case_ in <Map<String, Object?>>[
        {'standing': false},
        {'urgency': 'normal'},
        {'needsYou': false},
        {'asked': true},
      ]) {
        await db.customUpdate('DELETE FROM messages');
        await db.customUpdate('DELETE FROM drafts');
        final improveLlm = FakeLlm([answer(replyBody: 'Never written.')]);
        await runStanding(
          improveLlm: improveLlm,
          standing: case_['standing'] as bool? ?? true,
          needsYou: case_['needsYou'] as bool? ?? true,
          urgency: case_['urgency'] as String? ?? 'urgent',
          asked: case_['asked'] as bool? ?? false,
          ledger: ledgerOf(50),
        );

        expect(improveLlm.calls, 0, reason: '$case_');
        expect(
          (await store.getDraftForMessage('email', 'm1'))!['body'],
          startsWith('Thursday still works.'),
          reason: '$case_',
        );
      }
    });

    test('a failure leaves the local draft and notes the reason', () async {
      final log = await runStanding(
        improveLlm: FakeLlm([const LlmException('the target refused')]),
        ledger: ledgerOf(50),
      );

      expect(
        (await store.getDraftForMessage('email', 'm1'))!['body'],
        startsWith('Thursday still works.'),
      );
      // The category, not the client's sentence.
      expect(log.notes['improve_error'], 'llm');
      expect(log.notes.containsKey('improved'), isFalse);
    });

    test('at the cap it notes the refusal and dials nothing', () async {
      await seedCloudUse();
      final improveLlm = FakeLlm([answer(replyBody: 'Never written.')]);
      final log = await runStanding(improveLlm: improveLlm, ledger: ledgerOf(1));

      expect(improveLlm.calls, 0);
      expect(log.notes['improve'], 'cloud_cap');
      expect(
        (await store.getDraftForMessage('email', 'm1'))!['body'],
        startsWith('Thursday still works.'),
      );
    });

    test('a routed stage with no client is a wiring bug here too', () async {
      await seedInbound(needsYou: true, urgency: 'high');
      final handler = DraftHandler(
        store,
        FakeLlm([decision(), answer()]),
        activityLog: _Recorder(),
        routes: routes(improve: boxTarget, standing: true),
      );

      await expectLater(
        handler.run({
          'task_kind': 'draft',
          'source': 'email',
          'entity_id': 'm1',
          'payload_json': DraftRequest().encode(),
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('a prefetch on a third-party draft stage', () {
    Future<_Recorder> runPrefetch({
      required bool asked,
      required CloudDraftLedger ledger,
      required FakeLlm llm,
      FakeLlm? decisionLlm,
    }) async {
      await seedInbound();
      final log = _Recorder();
      final handler = DraftHandler(
        store,
        llm,
        // Its own stage and its own client, as the app builds it. The cap is
        // checked AFTER the decision on purpose: the decision is a cheap
        // yes/no that usually runs on a local server, and the thing the cap
        // is about is the prose prompt that would leave.
        decisionClient: decisionLlm,
        activityLog: log,
        routes: routes(draft: cloudTarget, ledger: ledger),
      );
      await handler.run({
        'task_kind': 'draft',
        'source': 'email',
        'entity_id': 'm1',
        'payload_json': DraftRequest(asked: asked).encode(),
      });
      return log;
    }

    test('is skipped at the cap, before the prose prompt is dialled', () async {
      await seedCloudUse();
      final llm = FakeLlm([answer()]);

      final log = await runPrefetch(
        asked: false,
        ledger: ledgerOf(1),
        llm: llm,
        decisionLlm: FakeLlm([decision()]),
      );

      expect(llm.calls, 0);
      expect(log.notes['reason'], 'cloud_cap');
      expect(await store.getDraftForMessage('email', 'm1'), isNull);
    });

    test('but a draft a person pressed for is written anyway', () async {
      await seedCloudUse();
      final llm = FakeLlm([answer()]);

      final log = await runPrefetch(asked: true, ledger: ledgerOf(1), llm: llm);

      expect(llm.calls, 1);
      expect(log.notes['cloud'], 1);
      expect(await store.getDraftForMessage('email', 'm1'), isNotNull);
    });
  });

  group('the notifier', () {
    DraftNotifier notifierFor({
      Future<String?> Function(String source, String messageId)? improve,
      Future<String?> Function()? cloudRefusal,
    }) {
      final notifier = DraftNotifier(
        store,
        FakeAuthSession(signedIn: true),
        _NeverMail(),
        (source: 'email', conversationKey: 'conv-1'),
        improve: improve,
        cloudRefusal: cloudRefusal,
      );
      addTearDown(notifier.dispose);
      return notifier;
    }

    test('improve() flips the flag, then reads the rewritten row', () async {
      await seedInbound();
      await seedDraft();
      final flags = <bool>[];
      final notifier = notifierFor(improve: (source, id) async {
        await seedDraft(body: 'The rewritten answer.');
        return null;
      });
      await pumpEventQueue();
      notifier.addListener((state) => flags.add(state.improving));

      await notifier.improve();

      expect(flags, containsAllInOrder(<bool>[true, false]));
      expect(notifier.state.improving, isFalse);
      expect(notifier.state.body, 'The rewritten answer.');
      expect(notifier.state.error, isNull);
    });

    test('a line from the handler leaves the draft alone and is shown',
        () async {
      await seedInbound();
      await seedDraft();
      final notifier =
          notifierFor(improve: (source, id) async => 'The target refused.');
      await pumpEventQueue();

      await notifier.improve();

      expect(notifier.state.error, 'The target refused.');
      expect(notifier.state.body, 'The local model wrote this one.');
      expect(notifier.state.improving, isFalse);
    });

    test('with nothing wired, improve() does nothing at all', () async {
      await seedInbound();
      await seedDraft();
      final notifier = notifierFor();
      await pumpEventQueue();

      await notifier.improve();

      expect(notifier.state.improving, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('generate() refused by the cap deletes nothing and queues nothing',
        () async {
      await seedInbound();
      await seedDraft();
      final notifier = notifierFor(
        cloudRefusal: () async => "Cloud drafts are at today's cap of 2.",
      );
      await pumpEventQueue();

      await notifier.generate();

      expect(notifier.state.error, "Cloud drafts are at today's cap of 2.");
      expect(notifier.state.generating, isFalse);
      expect(await store.getDraftForMessage('email', 'm1'), isNotNull);
      expect(await store.workCounts('draft'), isEmpty);
    });
  });
}
