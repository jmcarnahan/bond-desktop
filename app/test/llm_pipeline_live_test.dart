@Skip('live — needs the bulk server (make fast FAST_SLOTS=4) AND the prose '
    'server (make model). Run: make bench-pipeline '
    '(PIPE_SHAPE=single|lanes, PIPE_WIDTH=…, PIPE_COPIES=…)')
library;

import 'dart:async';

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/ai_workers.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';
import 'fixtures/corpus_seed.dart';
import 'fixtures/test_db.dart';

/// What the BACKLOG costs, end to end, through the real queues.
///
/// `llm_drain_live_test.dart` times triage alone and answers "does this
/// runtime batch?". This one answers the question a person actually asks: how
/// long until the inbox is usable, how long until the drafts are there, and
/// what happens to a message that arrives while all that is going on.
///
/// It runs the same corpus through both SHAPES, on the same tree on the same
/// day — which is a cleaner before/after than two trees a week apart:
///
/// - `PIPE_SHAPE=single` — one worker holding needs-you, extraction and
///   drafting, sharing one gate with the triage drain. The pre-Round-C shape.
/// - `PIPE_SHAPE=lanes` — a fast worker (needs-you, extraction) on the triage
///   gate, and a draft worker on a gate of its own, woken by
///   `ExtractHandler.onDraftQueued` as each draft row is written and again by
///   the fast drain's `onDrained`.
///
/// The late-arrival number is not the same measurement in both, and that is
/// the point of it. In `single` the one worker is mid-pass when the message
/// lands, so the number INCLUDES waiting for that pass — every draft in it —
/// before the extract handler comes round again. In `lanes` the drafts are on
/// another gate, so it should be one triage plus one needs-you plus one
/// extraction. The gap between the two is what T1 is about.
///
/// Two honest limits, stated here because they bound every number below:
///
/// 1. The seed writes messages and NO conversation rows (`seedCorpus`, the
///    drain bench's shape). `ExtractHandler._refreshCard` and `_fileBucket`
///    both return early without one, so the extraction leg measures the model
///    call rather than the card, the bucket filing or the thread embedding.
/// 2. `_embedMessage` still dials the embeddings client once per message. It
///    is pointed at a never-dialled port, so each is a refused connection —
///    milliseconds, but they are in the wall clock.
///
/// `make model` returns when the port binds, while the weights are still
/// loading — poll `/health` for `{"status":"ok"}` before a pass, or the first
/// call of the run gets an HTTP 503.
///
/// A plain `test`, never `testWidgets`: real sockets inside a fake-async zone
/// hang the whole run silently (`app/CLAUDE.md`).
///
/// It asserts nothing about speed and nothing about accuracy — the numbers are
/// printed and written to `$(BENCH_OUT)`, and the ledger in
/// `docs/model-bakeoff.md` is where they are read.

/// How many copies of the fixture corpus are seeded. 3 ≈ 66 messages.
const int pipeCopies = int.fromEnvironment('PIPE_COPIES', defaultValue: 3);

/// How many drafts are at the prose server at once — `AppPrefs.proseParallel`
/// as a define, so a width the shipping default is not can still be measured.
const int pipeWidth = int.fromEnvironment('PIPE_WIDTH', defaultValue: 1);

/// `single` or `lanes`.
const String pipeShape =
    String.fromEnvironment('PIPE_SHAPE', defaultValue: 'lanes');

/// Whether the late-arrival leg runs.
const bool pipeLate = bool.fromEnvironment('PIPE_LATE', defaultValue: true);

/// The id the late arrival is seeded under. Fixed, so a run file can be read
/// against the rows afterwards.
const String lateArrivalId = 'late-arrival';

/// How often the bench asks the rows where the drain has got to.
///
/// A poll rather than a hook, because the two milestones it times are
/// properties of the QUEUE and not of any one pump: in `single` the drafts
/// ride the same drain as the extractions, so "the fast phase is done" cannot
/// be read off a future at all. Quarter-second granularity against passes that
/// run for minutes.
const Duration pipePoll = Duration(milliseconds: 250);

/// How often the bench says where it has got to while a wait is open.
const Duration pipeHeartbeat = Duration(seconds: 30);

/// How long nothing may move before the bench calls it wedged and fails with
/// what it was waiting for.
///
/// Six minutes is more than twice the worst case for ONE item: a prose call
/// times out at 90 s and the worker gives it one retry, so 180 s is the
/// longest a legitimately slow draft can go without the counts changing. What
/// this catches is the state that never moves at all — a kind PARKED on
/// `LlmUnavailableException` leaves its rows `pending`, and nothing in this
/// bench pumps that lane again. Better a named failure in six minutes than
/// forty-five of silence.
const Duration pipeStallAfter = Duration(minutes: 6);

/// A handler that says when its first item STARTS, and is otherwise the
/// handler it wraps.
///
/// The collector cannot answer this: `LlmCallRecord` is recorded when a call
/// comes back, and what the late-arrival leg needs is the moment the prose
/// server started working — which is when a person would first be waiting.
class FirstEntryHandler extends WorkHandler {
  final WorkHandler _inner;
  final Completer<void> firstItem = Completer<void>();

  /// Items inside [run] right now, and how many have ever started. The
  /// heartbeat prints both: "nothing owed is moving and nothing is in flight"
  /// is a parked lane, and "one in flight for four minutes" is a slow server.
  int inFlight = 0;
  int started = 0;

  FirstEntryHandler(this._inner);

  @override
  String get kind => _inner.kind;

  /// Forwarded rather than defaulted: this wrapper must not quietly narrow the
  /// width the run is measuring.
  @override
  int get concurrency => _inner.concurrency;

  @override
  Future<void> run(Map<String, Object?> item) {
    if (!firstItem.isCompleted) firstItem.complete();
    started++;
    inFlight++;
    return _inner.run(item).whenComplete(() => inFlight--);
  }
}

String _secs(int? ms) =>
    ms == null ? '—' : (ms / 1000).toStringAsFixed(1);

void main() {
  test(
    'the backlog through the real queues',
    () async {
      expect(
        const ['single', 'lanes'],
        contains(pipeShape),
        reason: 'PIPE_SHAPE must be single or lanes',
      );

      final db = testDb();
      final store = MessageStore(db);
      addTearDown(() async => db.close());

      // Both servers, each with its own collector: a bulk p50 and a prose p50
      // are different regimes and merging them would describe neither.
      final CallCollector bulk = BenchTarget.bulk.collector();
      final CallCollector prose = BenchTarget.prose.collector();
      final bulkClient = BenchTarget.bulk.client(onCall: bulk.record)
        ..onReasoningLeak = bulk.noteLeak;
      final proseClient = BenchTarget.prose.client(onCall: prose.record)
        ..onReasoningLeak = prose.noteLeak;

      // Thrown away, and on a client with no observer, so the first call's
      // weight-loading cost lands in no table. The PROSE server is warmed by
      // `make bench-pipeline`'s own `bench-verify-prose` leg — with
      // BENCH_VERIFY=0 the first draft carries that cost, which is worth
      // knowing when reading a one-off row.
      final warmupClient = BenchTarget.bulk.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        await runTask(
          warmupClient,
          const TriageTask(),
          TriageInput(emailCorpus.first.message, DateTime.now()),
          think: BenchTarget.allowReasoning,
        );
      }

      await seedCorpus(store, copies: pipeCopies);
      final ungated = ungatedCorpusIds(copies: pipeCopies);

      // What the sync does at ingest: both per-message kinds are queued BEFORE
      // triage has spoken, and `claimPendingWork` holds them back until it
      // has. Caps well past the corpus, so the bench measures the backlog it
      // seeded rather than the store's default slice.
      final floor = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 3650))
          .toIso8601String();
      Future<void> queueBacklog() async {
        await store.enqueueExtractBacklog(sinceIso: floor, cap: 10000);
        await store.enqueueNeedsYouBacklog(sinceIso: floor, cap: 10000);
      }

      await queueBacklog();

      // The embedding server, absent on purpose: a vector is not what this
      // bench is about, and dialling one would put a third server's latency in
      // the wall clock. A refused connection per message is the cost, and it
      // is named in the header.
      final noEmbeddings =
          EmbeddingsClient(baseUrl: 'http://127.0.0.1:1/never-dialled');

      final drafts = FirstEntryHandler(
        DraftHandler(
          store,
          proseClient,
          concurrency: () => pipeWidth,
        ),
      );

      // `late final` because the two are circular by design: extraction wakes
      // the draft lane, and the draft lane is built from the handler above.
      late final AiWorker draftWorker;
      final lanes = pipeShape == 'lanes';

      // Every pump this bench starts, counted in and out. There is no public
      // "is a drain running" on either queue, and this is the cheap honest
      // substitute: it says whether anything is still trying, which is the
      // difference between a slow server and a lane nobody is pumping.
      final pumps = <String, int>{'chain': 0, 'fast': 0, 'draft': 0};
      final pumped = <String, int>{'chain': 0, 'fast': 0, 'draft': 0};
      Future<void> track(String name, Future<void> future) {
        pumps[name] = pumps[name]! + 1;
        pumped[name] = pumped[name]! + 1;
        return future.whenComplete(() => pumps[name] = pumps[name]! - 1);
      }

      final needsYou = NeedsYouHandler(store, bulkClient);
      final extract = ExtractHandler(
        store,
        bulkClient,
        noEmbeddings,
        onDraftQueued:
            lanes ? () => unawaited(track('draft', draftWorker.pump())) : null,
      );

      // The gate the triage drain and the fast work share — the app's
      // `fastDrainGateProvider`, and in `single` the only gate there is.
      final fastGate = DrainGate();

      final worker = AiWorker(
        store,
        handlers: lanes ? [needsYou, extract] : [needsYou, extract, drafts],
        gate: fastGate,
        onDrained:
            lanes ? () => unawaited(track('draft', draftWorker.pump())) : null,
      );
      draftWorker = lanes
          ? AiWorker(store, handlers: [drafts], gate: DrainGate())
          : worker;
      addTearDown(worker.dispose);
      if (lanes) addTearDown(draftWorker.dispose);

      final queue = TriageQueue(
        store,
        bulkClient,
        userAddress: userAddress,
        concurrency: 3,
        gate: fastGate,
        onDrained: () async => unawaited(track('fast', worker.pump())),
      );
      addTearDown(queue.dispose);

      // Pending plus processing rows of one kind.
      Future<int> owed(String kind) async {
        final counts = await store.workCounts(
          kind,
          sources: const ['email', 'teams', 'local'],
        );
        return (counts['pending'] ?? 0) + (counts['processing'] ?? 0);
      }

      // The late arrival's own rows, which the two milestones below must NOT
      // wait for: it is upserted mid-run on purpose, and counting it would
      // fold the thing being measured into the thing it is measured against.
      Future<int> lateOwed(String kind) async {
        final status = await store.workStatusOf(kind, 'email', lateArrivalId);
        return status == 'pending' || status == 'processing' ? 1 : 0;
      }

      Future<bool> drained(List<String> kinds) async {
        for (final kind in kinds) {
          if (await owed(kind) - await lateOwed(kind) > 0) return false;
        }
        return true;
      }

      // Two `workCounts` queries rather than sixty-six `message_progress`
      // reads: terminal work rows for both per-message kinds IS the fast phase
      // being over, and every one of those rows was written before the clock
      // started — so an empty queue here cannot mean "not queued yet".
      Future<bool> fastDone() => drained(const ['needs_you', 'extract']);

      // ── saying where it has got to ──────────────────────────────────────
      // Printed as it happens, never held to the end: a pass that wedges has
      // to leave a trail, and the first version of this bench spent
      // forty-five minutes in silence before a timeout that said nothing
      // about which wait was open.
      final clock = Stopwatch()..start();
      String at() => '[${(clock.elapsedMilliseconds / 1000).toStringAsFixed(0)}s]';

      void say(String line) {
        // ignore: avoid_print
        print('${at()} $line');
      }

      // What the ROWS say, and only that: triage's backlog, each kind's
      // pending/processing/done, and where the late arrival has got to.
      //
      // Split from the rest of the heartbeat line on purpose — this string is
      // also the stall key, and folding the pump counters into it would reset
      // the stall clock every time the re-pump below fired, which is exactly
      // the case the guard exists for.
      Future<String> snapshot() async {
        final triage = await store.triageCounts(sources: const ['email']);
        final kinds = <String>[];
        for (final kind in const ['needs_you', 'extract', 'draft']) {
          final counts = await store.workCounts(
            kind,
            sources: const ['email', 'teams', 'local'],
          );
          kinds.add('$kind ${counts['pending'] ?? 0}/'
              '${counts['processing'] ?? 0}/${counts['done'] ?? 0}');
        }
        final row = await store.getMessageRow('email', lateArrivalId);
        final late = row == null
            ? 'not upserted'
            : '${row['triage_status']} '
                'needs_you=${await store.workStatusOf('needs_you', 'email', lateArrivalId)} '
                'extract=${await store.workStatusOf('extract', 'email', lateArrivalId)}';
        return 'triage ${triage['pending'] ?? 0} pending/'
            '${triage['processing'] ?? 0} processing · ${kinds.join(' · ')} · '
            'late: $late';
      }

      /// What the RUN is doing, which is not what the rows say: a kind owed
      /// with nothing in flight and nothing pumping is a parked lane, and a
      /// kind owed with one item in flight is a slow server.
      String effort() =>
          'drafts in flight ${drafts.inFlight} (started ${drafts.started}) · '
          'pumps chain/fast/draft running '
          '${pumps['chain']}/${pumps['fast']}/${pumps['draft']} '
          'of ${pumped['chain']}/${pumped['fast']}/${pumped['draft']}';

      /// Any per-message or draft work still owed, the late arrival INCLUDED:
      /// a lane parked on the late message's own row needs the same nudge.
      Future<bool> anythingOwed() async {
        for (final kind in const ['needs_you', 'extract', 'draft']) {
          if (await owed(kind) > 0) return true;
        }
        return false;
      }

      String? lastSnapshot;
      var stalledFor = Duration.zero;
      Object? wedged;
      var beating = false;
      final beat = Timer.periodic(pipeHeartbeat, (_) async {
        // A heartbeat that overlapped itself would read the rows twice and
        // report a state neither poll saw.
        if (beating) return;
        beating = true;
        try {
          final line = await snapshot();
          say('$line · ${effort()}');
          if (line == lastSnapshot) {
            stalledFor += pipeHeartbeat;
          } else {
            stalledFor = Duration.zero;
            lastSnapshot = line;
          }

          // The app pumps every lane after each sync, so a lane parked on
          // `LlmUnavailableException` resumes within a minute there. A bench
          // that hung instead would be measuring an absence the app does not
          // have — so this mirrors the tick: anything owed, with no pump of
          // this bench's still running, gets pumped again. It is printed
          // because it is not free: a park's dead time, up to one heartbeat of
          // it, lands in the wall clock of whatever wait is open.
          if (pumps.values.every((running) => running == 0) &&
              await anythingOwed()) {
            say("re-pumped (the app's sync tick would have)");
            unawaited(track('fast', worker.pump()));
            // In `single` there is one worker and `draftWorker` IS it —
            // pumping twice would only set its repump flag.
            if (lanes) unawaited(track('draft', draftWorker.pump()));
          }

          if (stalledFor >= pipeStallAfter && wedged == null) {
            wedged = StateError(
              'the pipeline stopped moving for ${pipeStallAfter.inMinutes} '
              'minutes — the row counts above never changed, through the '
              're-pumps beside them. So this is not a lane nobody pumped: it '
              'is one that is pumped and still gets nowhere — a server that '
              'is down, or a kind failing identically every time. '
              'Last state: $line · ${effort()}',
            );
          }
        } finally {
          beating = false;
        }
      });
      addTearDown(beat.cancel);

      Future<int> waitFor(
        String label,
        Future<bool> Function() done,
      ) async {
        while (!await done()) {
          final stall = wedged;
          if (stall != null) throw stall;
          await Future<void>.delayed(pipePoll);
        }
        final ms = clock.elapsedMilliseconds;
        say('$label at ${(ms / 1000).toStringAsFixed(1)}s');
        return ms;
      }

      // ── the late arrival ────────────────────────────────────────────────
      // One more message, upserted at the moment the prose server starts its
      // first draft, and timed to its extraction being done. In `single` it
      // waits for the pass to come round behind every draft; in `lanes` it
      // should cost one triage plus one needs-you plus one extraction.
      var lateMs = <String, Object?>{};
      Future<void> lateArrival() async {
        await drafts.firstItem.future;
        final entry = emailCorpus.firstWhere((e) => e.expectedGate == null);
        final message = entry.message;
        final since = Stopwatch()..start();
        say('late arrival: upserted');
        await store.upsertMessage({
          'source': message.source,
          'source_message_id': lateArrivalId,
          'conversation_key': 'conv-$lateArrivalId',
          'direction': 'inbound',
          'subject': message.subject,
          'from_name': message.fromName,
          'from_address': message.fromAddress,
          // Now, so the claim order (`created_at DESC`) treats it as the
          // newest mail in the box — which is what it is.
          'received_at': DateTime.now().toUtc().toIso8601String(),
          'body_preview': message.bodyPreview,
          'body_text': message.bodyText,
          'source_meta_json': message.sourceMetaJson,
          'triage_status': 'pending',
        });
        await queueBacklog();
        unawaited(
          track(
            'chain',
            pumpTriageThenWorkers(triage: queue.pump, workers: worker.pump),
          ).catchError((Object _) {}),
        );

        final stages = <String, int>{};
        for (final kind in const ['needs_you', 'extract']) {
          while (true) {
            final status =
                await store.workStatusOf(kind, 'email', lateArrivalId);
            if (status == 'done' || status == 'error') break;
            final stall = wedged;
            if (stall != null) throw stall;
            await Future<void>.delayed(pipePoll);
          }
          stages[kind] = since.elapsedMilliseconds;
          say('late $kind done at '
              '${(since.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
              'after the upsert');
        }
        lateMs = {
          'total_ms': since.elapsedMilliseconds,
          'stages': stages,
        };
      }

      // ── the run ─────────────────────────────────────────────────────────
      final startedAt = DateTime.now();
      say('seeded ${ungated.length} ungated messages, shape $pipeShape, '
          'width $pipeWidth');
      final lateLeg = pipeLate ? lateArrival() : Future<void>.value();

      final chain = track(
        'chain',
        pumpTriageThenWorkers(triage: queue.pump, workers: worker.pump),
      );

      final fastWallMs = await waitFor('fast done', fastDone);
      final draftsWallMs =
          await waitFor('drafts done', () => drained(const ['draft']));
      await chain;
      if (lanes) await track('draft', draftWorker.pump());
      // A corpus that queued no draft at all would leave the late leg waiting
      // on a first draft that never comes. Released here rather than guarded
      // with a timeout: by this line every queue is drained, so the leg still
      // measures a real arrival — just into an idle app, which the row says by
      // carrying a draft count of zero.
      if (!drafts.firstItem.isCompleted) drafts.firstItem.complete();
      await lateLeg;
      clock.stop();
      beat.cancel();

      final fastMsgsPerMin = ungated.length * 60000 / fastWallMs;
      final draftCount = (await store.workCounts(
            'draft',
            sources: const ['email', 'teams', 'local'],
          ))['done'] ??
          0;

      final lateTotal = lateMs['total_ms'] as int?;

      // ignore: avoid_print
      print(
        '\n=== pipeline: shape $pipeShape, width $pipeWidth, '
        '$pipeCopies copies (${ungated.length} ungated messages) ===\n'
        '| metric | value |\n'
        '| --- | --- |\n'
        '| fast wall | ${_secs(fastWallMs)}s |\n'
        '| drafts wall | ${_secs(draftsWallMs)}s |\n'
        '| fast msgs/min | ${fastMsgsPerMin.toStringAsFixed(1)} |\n'
        '| drafts written | $draftCount |\n'
        '| late arrival | ${_secs(lateTotal)}s |\n'
        '\n${bulk.banner}\n\n${bulk.table()}\n'
        '\n${prose.banner}\n\n${prose.table()}\n',
      );

      final path = await writeBenchResult(
        bench: 'pipeline',
        collectors: [bulk, prose],
        accuracy: const [],
        startedAt: startedAt,
        extra: {
          'shape': pipeShape,
          'width': pipeWidth,
          'copies': pipeCopies,
          'messages': ungated.length,
          'fast_wall_ms': fastWallMs,
          'drafts_wall_ms': draftsWallMs,
          'fast_msgs_per_min': fastMsgsPerMin,
          'drafts_written': draftCount,
          'late_arrival_ms': lateTotal,
          'late_arrival_stages': lateMs['stages'],
        },
      );
      // ignore: avoid_print
      if (path != null) print('wrote $path');

      // The only assertions, and neither is about speed: every ungated message
      // was triaged, and the server did not reason its way through the run. A
      // shape that went faster by dropping mail has not got faster.
      for (final id in ungated) {
        final row = await store.getMessageRow('email', id);
        expect(row!['triage_status'], 'triaged', reason: id);
      }
      final leaks = bulk.reasoningLeaks + prose.reasoningLeaks;
      if (BenchTarget.allowReasoning) {
        // ignore: avoid_print
        print('reasoning leaks: $leaks (not asserted — BENCH_THINK is set)');
      } else {
        expect(leaks, 0,
            reason: 'a model reasoned despite enable_thinking');
      }
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
