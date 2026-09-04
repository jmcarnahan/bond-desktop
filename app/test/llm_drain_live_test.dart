@Skip('live — needs a bulk-work server with at least max(BENCH_K) slots '
    '(make fast FAST_SLOTS=4). Run: make drain (BENCH_K=1,3,6 to race more)')
library;

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/test_db.dart';

import 'fixtures/corpus.dart';

/// What the drain's concurrency is actually worth, measured rather than
/// reasoned about.
///
/// `llm_bench_live_test.dart` times one request at a time, which is the number
/// that tells you whether the MODEL got faster. This one times the whole
/// corpus through the real [TriageQueue] once per concurrency in `BENCH_K`,
/// because batched decode is a property of the drain and not of any one call:
/// a per-request bench cannot see it at all.
///
/// It points wherever the other benches do — `BENCH_URL` and friends — so a
/// candidate runtime's batching can be measured with one command and no code
/// edit, which matters more here than anywhere else in the bakeoff. Two
/// runtimes can generate at the same tokens per second and differ by a factor
/// of three on a backlog, purely on whether concurrent requests are batched or
/// queued, and that difference is invisible to every other bench.
///
/// Start the server with at least max(K) slots or the high rounds measure
/// queue-wait rather than batching:
///   make fast FAST_SLOTS=4
///   make drain BENCH_K=1,3
///
/// It prints rather than asserts on the ratio. What the batch is worth depends
/// on the GPU, on how many slots the server was started with, and on how long
/// the emails are; a threshold pinned here would fail on someone else's laptop
/// for no defect. The assertion is the thing that must be true regardless:
/// every drain triaged the same mail. A concurrency that went faster by losing
/// messages is not a speedup.

/// The mean of `durationMs − prompt_ms − predicted_ms` over the triage calls
/// that reported server timings, or null when none did.
///
/// Both server numbers are subtracted, not just generation: prefill is real
/// work the server did on this request, and calling it queue-wait would make
/// every long email look like a congested server. What is left over is queue
/// plus HTTP — the overhead continuous batching exists to shrink, and the
/// single number that separates a runtime that batches from one that quietly
/// serializes. A runtime that queues holds its generation rate flat while this
/// climbs with K; one that batches holds this flat instead.
double? meanQueueWaitMs(CallCollector collector) {
  var total = 0;
  var counted = 0;
  for (final record in collector.metricsFor('triage').ok) {
    final prompt = record.serverPromptMs;
    final predicted = record.serverPredictedMs;
    if (prompt == null || predicted == null) continue;
    total += record.durationMs - prompt - predicted;
    counted++;
  }
  return counted == 0 ? null : total / counted;
}

/// Generation tokens per second across every call this collector saw, summed
/// and divided ONCE — the same invariant [TaskMetrics.genTps] holds, applied
/// across tasks rather than within one.
double? aggregateGenTps(CallCollector collector) {
  var tokens = 0;
  var ms = 0;
  for (final metrics in collector.tasks) {
    for (final record in metrics.ok) {
      final completion = record.completionTokens;
      if (completion == null) continue;
      tokens += completion;
      ms += record.durationMs;
    }
  }
  return ms <= 0 ? null : tokens * 1000 / ms;
}

String _rate(double? value) =>
    value == null ? '—' : value.toStringAsFixed(1);

void main() {
  /// One whole drain over a fresh store, watched by [collector]. Returns its
  /// wall clock.
  Future<Duration> drainCorpus(int concurrency, CallCollector collector) async {
    final db = testDb();
    final store = MessageStore(db);
    try {
      // Body, headers and all, the way a delta page plus a detail fetch would
      // have left it — the queue is given no `ensureBody`, so what is stored
      // here is all it will ever have to read.
      for (final entry in emailCorpus) {
        final message = entry.message;
        await store.upsertMessage({
          'source': message.source,
          'source_message_id': entry.id,
          'conversation_key': entry.conversationKey,
          'direction': message.outbound ? 'outbound' : 'inbound',
          'subject': message.subject,
          'from_name': message.fromName,
          'from_address': message.fromAddress,
          'received_at': message.receivedAt,
          'body_preview': message.bodyPreview,
          'body_text': message.bodyText,
          'source_meta_json': message.sourceMetaJson,
          'triage_status': 'pending',
        });
      }

      // Observed, which the old version could not be: a wall clock around
      // `pump()` says how long the backlog took and nothing about where the
      // time went. The records carry per-call latency and the server's own
      // prefill and decode milliseconds, which is what makes the queue-wait
      // column above possible at all.
      final client = BenchTarget.bulk.client(onCall: collector.record);
      client.onReasoningLeak = collector.noteLeak;

      final queue = TriageQueue(
        store,
        client,
        userAddress: userAddress,
        concurrency: concurrency,
      );

      final watch = Stopwatch()..start();
      await queue.pump();
      watch.stop();

      // The only assertion, and it is about correctness rather than speed: a
      // drain that went faster by dropping messages has not got faster.
      for (final entry in emailCorpus.where((e) => e.expectedGate == null)) {
        final row = await store.getMessageRow('email', entry.id);
        expect(row!['triage_status'], 'triaged', reason: entry.id);
      }

      return watch.elapsed;
    } finally {
      db.close();
    }
  }

  test(
    'the corpus drained at every concurrency BENCH_K names',
    () async {
      final rounds = parseDrainK();
      // What the throughput number is over: the gated entries never reach the
      // model, so counting them would credit the server with mail it never
      // saw.
      final triagedCount =
          emailCorpus.where((e) => e.expectedGate == null).length;

      // Thrown away, and on a client with no observer, so the first call's
      // weight-loading cost lands in no round's table. Cold against warm is a
      // 20x difference on this machine; one cold call does not move round
      // one's numbers, it replaces them — and round one is what every later
      // round's speedup is divided by.
      final warmupClient = BenchTarget.bulk.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        await runTask(
          warmupClient,
          const TriageTask(),
          TriageInput(emailCorpus.first.message, DateTime.now()),
          think: BenchTarget.allowReasoning,
        );
      }

      final startedAt = DateTime.now();

      final collectors = <CallCollector>[];
      final results = <Map<String, Object?>>[];
      final lines = <String>[];

      for (final k in rounds) {
        // One collector PER ROUND, never one shared. Merged latencies would
        // average two different concurrency regimes into a p50 that describes
        // neither — and the gap between the regimes IS the measurement.
        final collector = CallCollector(
          label: '${BenchTarget.bulk.label} K=$k',
          url: BenchTarget.bulk.url,
          model: BenchTarget.bulk.model,
        );
        collectors.add(collector);

        final wall = await drainCorpus(k, collector);
        final wallMs = wall.inMilliseconds;
        final msgsPerMin = triagedCount * 60000 / wallMs;
        final queueWait = meanQueueWaitMs(collector);

        results.add({
          'k': k,
          'wall_ms': wallMs,
          'msgs_per_min': msgsPerMin,
          'queue_wait_ms': queueWait,
        });

        lines.add(
          'K=${k.toString().padLeft(2)}  '
          'wall ${(wallMs / 1000).toStringAsFixed(1)}s  '
          '${msgsPerMin.toStringAsFixed(1)} msgs/min  '
          'gen ${_rate(aggregateGenTps(collector))} t/s  '
          'queue-wait ${queueWait == null ? '—' : '${queueWait.toStringAsFixed(0)}ms'}',
        );
      }

      // Against K=1 only, and only when it was run: a speedup is a ratio to
      // the serial baseline, and quoting one against whatever round happened
      // to come first would make `BENCH_K=3,6` claim a 1.00x for K=3.
      final serial = [for (final round in results) if (round['k'] == 1) round];
      if (serial.isNotEmpty) {
        final baseMs = serial.first['wall_ms'] as int;
        for (final round in results) {
          final k = round['k'] as int;
          if (k == 1) continue;
          final ratio = baseMs / (round['wall_ms'] as int);
          lines.add('speedup vs K=1: ${ratio.toStringAsFixed(2)}x  (K=$k)');
        }
      }

      // ignore: avoid_print
      print(
        '\n=== drain: $triagedCount messages per round, '
        'K=${rounds.join(',')} ===\n'
        '${lines.join('\n')}\n'
        '\n${collectors.map((c) => '${c.banner}\n\n${c.table()}\n').join('\n')}',
      );

      // `accuracy` is empty: nothing here judges a label. The per-round
      // numbers go to `extra` because they are properties of a ROUND rather
      // than of a task, which is the only shape the target list can hold.
      final path = await writeBenchResult(
        bench: 'drain',
        collectors: collectors,
        accuracy: const [],
        startedAt: startedAt,
        extra: {
          'k_rounds': results,
          'triaged_count': triagedCount,
        },
      );
      // ignore: avoid_print
      if (path != null) print('wrote $path');

      // Summed across rounds: a leak is a property of the server, so it does
      // not matter which round saw it. Not a judgement call either — a build
      // that ignores enable_thinking runs at half speed, and every number
      // above would be measuring that instead of the drain.
      final leaks =
          collectors.fold(0, (sum, c) => sum + c.reasoningLeaks);
      if (BenchTarget.allowReasoning) {
        // ignore: avoid_print
        print('reasoning leaks: $leaks (not asserted — BENCH_THINK is set)');
      } else {
        expect(leaks, 0,
            reason: 'the model reasoned despite enable_thinking');
      }
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
