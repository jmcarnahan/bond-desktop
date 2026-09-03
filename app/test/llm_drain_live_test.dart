@Skip('live — needs the fast llama-server on :8082 (run with FAST_SLOTS=4). '
    'Run: flutter test test/llm_drain_live_test.dart --run-skipped')
library;

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_target.dart';
import 'fixtures/test_db.dart';

import 'fixtures/corpus.dart';

/// What the drain's concurrency is actually worth, measured rather than
/// reasoned about.
///
/// `llm_bench_live_test.dart` times one request at a time, which is the number
/// that tells you whether the MODEL got faster. This one times the whole
/// corpus through the real [TriageQueue] twice — once strictly serial, once at
/// the shipping concurrency of three — because batched decode is a property of
/// the drain, not of any one call, and a per-request bench cannot see it at
/// all.
///
/// It prints rather than asserts on the ratio. What the batch is worth depends
/// on the GPU, on how many slots the server was started with, and on how long
/// the emails are; a threshold pinned here would fail on someone else's laptop
/// for no defect. The assertion is the thing that must be true regardless:
/// both drains triaged the same mail. A concurrency that went faster by losing
/// messages is not a speedup.
///
/// Run the fast server with matching slots or round two measures nothing:
///   make fast FAST_SLOTS=4

void main() {
  /// One whole drain over a fresh store. Returns its wall clock.
  Future<Duration> drainCorpus(int concurrency) async {
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

      final queue = TriageQueue(
        store,
        BenchTarget.bulk.client(),
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
    'the corpus drained serially, then three at a time',
    () async {
      final serial = await drainCorpus(1);
      final batched = await drainCorpus(3);

      final ratio = serial.inMilliseconds / batched.inMilliseconds;
      // ignore: avoid_print
      print(
        '\ndrain concurrency 1: ${serial.inMilliseconds}ms '
        '(${(serial.inMilliseconds / 1000).toStringAsFixed(1)}s)\n'
        'drain concurrency 3: ${batched.inMilliseconds}ms '
        '(${(batched.inMilliseconds / 1000).toStringAsFixed(1)}s)\n'
        'speedup: ${ratio.toStringAsFixed(2)}x\n',
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
