import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/vec_test_db.dart';

/// The digest's requeue, run through the REAL provider graph.
///
/// `attachment_digest_handler_test.dart` hands the handler a counting
/// `onRequeue` closure and could never have caught this: the defect was in
/// the closure the provider supplies. It read the fast lane's own provider —
/// `ref.read(aiWorkerProvider)` — from inside that provider's own build, and
/// Riverpod's `_debugAssertCanDependOn` refuses that on a `read` exactly as it
/// does on a `watch`. Every debug build therefore threw
/// `A provider cannot depend on itself` out of the handler's `run`, and the
/// first digest on a message that carried an ask ended as a failed work row
/// instead of waking the pass that would re-judge it.
///
/// So the pin is at PROVIDER level: the lane is read from a container, drained
/// for real, and the assertion is that the digest finished clean and the
/// needs-you pass it asked for actually ran.
void main() {
  late bool available;
  late BondDatabase db;
  late MessageStore store;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    db = vecTestDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// A document that asks for something, which is the only kind of digest
  /// that requeues anything at all.
  Map<String, Object?> digestAnswer() => {
        'evidence': 'A lease addendum sent for the owner to sign.',
        'kind': 'contract',
        'summary': 'The rent rises to 2,600 in January.',
        'facts': ['Rent rises to 2,600 on 1 January'],
        'asks': ['Sign page four'],
      };

  /// The re-judgement's answer, and `false` on purpose: the digest refuses to
  /// requeue a message already judged `1`, so a `yes` here would let this
  /// test pass for the wrong reason the day the needs-you pass ran first.
  const Map<String, dynamic> needsYouAnswer = {
    'evidence': 'The addendum asks for a signature, not the owner specifically.',
    'needs_you': false,
    'confidence': 'high',
  };

  Future<void> seed() async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'conv-m1',
      'direction': 'inbound',
      'subject': 'Renewal paperwork',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-09-04T10:00:00.000Z',
      'body_text': 'The lease is attached.',
      'triage_status': 'triaged',
    });
    await store.upsertAttachments('email', 'm1', const [
      {
        'attachment_id': 'a1',
        'ordinal': 0,
        'kind': 'file',
        'name': 'Lease Addendum.pdf',
        'content_type': 'application/pdf',
        'size': 240 * 1024,
      },
    ]);
    await store.setAttachmentText(
      'email',
      'm1',
      'a1',
      status: 'done',
      text: 'The tenant pays 2,400 on the fourth of each month.',
    );
  }

  Future<Map<String, Object?>?> workRow(String kind, String entityId) async {
    final rows = await db.customSelect(
      'SELECT * FROM work_items WHERE task_kind = ? AND entity_id = ?',
      variables: [Variable(kind), Variable(entityId)],
    ).get();
    return rows.isEmpty ? null : rows.first.data;
  }

  test(
      'the digest\'s requeue wakes the drain it runs in without reading its '
      'own provider', () async {
    if (!available) return;
    await seed();
    await store.enqueueWork('attachment_digest', 'email', 'm1|a1');

    // The two lanes the fast drain wakes, replaced by idle workers so this
    // test starts no drain that would dial anything — `llm_routing_test`'s
    // shape for the same reason.
    final idleStoryline =
        AiWorker(store, handlers: const [], gate: DrainGate());
    final idleDraft = AiWorker(store, handlers: const [], gate: DrainGate());
    addTearDown(idleStoryline.dispose);
    addTearDown(idleDraft.dispose);

    final digest = ScriptedLlm(label: 'attachment_digest')
      ..scriptFor('attachment_digest', [digestAnswer()]);
    final needsYou = ScriptedLlm(label: 'needs_you')
      ..scriptFor('needs_you', const [needsYouAnswer]);
    // Every other stage gets a client that throws if it is dialled: nothing
    // else in this drain has a row to work on, and a call that landed
    // elsewhere would be the news.
    final unused = ScriptedLlm.never(label: 'unused');

    final container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        embeddingsClientProvider.overrideWithValue(FakeEmbedServer().client),
        storylineWorkerProvider.overrideWithValue(idleStoryline),
        draftWorkerProvider.overrideWithValue(idleDraft),
        stageLlmClientProvider.overrideWith((ref, id) {
          switch (id) {
            case 'attachment_digest':
              return digest;
            case 'needs_you':
              return needsYou;
            default:
              return unused;
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appPrefsProvider.notifier).ready;
    // Set rather than trusted to the preference's default: an off lane never
    // drains, and this test is not about where the switch starts.
    container.read(processingProvider.notifier).set(true);

    final worker = container.read(aiWorkerProvider);
    await worker.pump();
    await pumpEventQueue();

    // The row the assertion used to land on: the requeue is called from
    // inside `run`, so a throw there fails the digest itself.
    final digestRow = (await workRow('attachment_digest', 'm1|a1'))!;
    expect(digestRow['error'], isNull);
    expect(digestRow['status'], 'done');

    // The requeue landed, and the pass it woke ran on THIS drain rather than
    // the next one — which is the whole point of waking the worker at all.
    final judgement = (await workRow('needs_you', 'm1'))!;
    expect(judgement['error'], isNull);
    expect(judgement['status'], 'done');
    expect(needsYou.callsFor('needs_you'), 1);

    // And the lane was never rebuilt: the worker the handler woke is the
    // worker that was draining.
    expect(identical(container.read(aiWorkerProvider), worker), isTrue);
  });
}
