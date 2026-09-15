@Skip('live — needs the golden set and a server. Run: make golden (bulk) or '
    'make golden-prose (prose)')
library;

import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures/bench_report.dart';
import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/golden_harness.dart';
import 'fixtures/golden_prices.dart';
import 'fixtures/golden_run.dart';
import 'fixtures/golden_set.dart';

/// The golden set through the app's real tasks, on whatever server the defines
/// point at.
///
/// This is the run behind a golden-ledger row, and it produces BOTH halves of
/// one in a single pass: a run file `golden/tools/score_run.py` scores for
/// accuracy, and the ordinary bench timing JSON beside it for speed and cost.
/// Two passes would be two different sets of answers timed separately, which
/// is one more thing a ledger row could be wrong about.
///
/// **Nothing here judges correctness.** The scorer of record is Python and the
/// rubric judge is a later phase; a Dart opinion about what "right" means would
/// be the second scoring semantics a bakeoff must not grow. So the asserts are
/// shape — an empty category is a broken call, not a debatable label — plus the
/// one thing that is never a judgement call, that `enable_thinking: false` was
/// honoured.
///
/// **What it prints is counts, timings and enums, and never message content.**
/// A per-item line carries the item id, the milliseconds each stage took, and
/// the enum values it answered with. Labels, summaries, evidence sentences and
/// drafted replies go to the run file and nowhere else: the set is real
/// correspondence, this repository is public, and a table pasted out of
/// scrollback into a document is exactly how that leaks.

/// The caveat every `compressed` row is quoted with — the one-line form of the
/// paragraph in `docs/model-bakeoff.md`, "The context ladder" — because a
/// number that arrives without it reads as a measurement of compression rather
/// than of a clipped head of one.
const String _compressedCaveat =
    'ctx compressed: the digest rides as the oldest of the three thread '
    'messages triage and needs-you keep, and both clip a thread message at '
    '300 characters — this rung is a LOWER BOUND on what compression buys';

const String _noneCaveat =
    'ctx none: triage and needs-you saw the message alone';

/// The caveat a Converse row is quoted with, for [_compressedCaveat]'s reason:
/// `temperature` is the one handler parameter that wire cannot carry, so a
/// reader comparing this row with a local one has to know it sampled
/// differently.
const String _converseCaveat =
    'wire converse — temperature not sent (Claude 5 rejects it); sampling at '
    "the model's default";

void main() {
  test(
    'the golden set through triage, needs-you and extraction',
    () async {
      final (set, ctx) = await _loadOrFail();
      final k = checkK(GoldenDefines.k);
      const target = BenchTarget.bulk;

      // Built up front, in set order, so the run file's rows come out in the
      // order the set lists them whatever order the pool finishes in.
      final entries = [
        for (final item in set.items)
          GoldenRunEntry(
            id: item.id,
            stratum: item.stratum,
            difficulty: item.difficulty,
          ),
      ];
      final lines = List<String?>.filled(set.items.length, null);

      // Thrown away, and on a client with no observer, so the first call's
      // weight-loading cost lands nowhere near the table — `bench`'s reasoning
      // exactly. A warmup that fails is a server that is down, and the run
      // stops there rather than spending ninety minutes on timeouts; see
      // [_warmupFailed] for why the failure is re-thrown in other words.
      final warmupClient = target.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        try {
          // Retried like every other call: the warmup is the first burst
          // against a cloud account and so the likeliest throttle, and a 429
          // here would otherwise read as a server that is down.
          await retryingUnavailable(
            () => runTask(
              warmupClient,
              const TriageTask(),
              TriageInput(set.items.first.message, set.items.first.now),
              think: BenchTarget.allowReasoning,
            ),
          );
        } on LlmException catch (e) {
          _warmupFailed('triage', e, target);
        }
      }

      // ONE http client for the whole run, so connections are pooled rather
      // than renegotiated per item, and ONE master collector, so the table's
      // rates stay time-weighted over everything that ran. What is per item is
      // the OBSERVER: under GOLDEN_K > 1 calls from different items interleave,
      // so the collector's `lastFor` would hand a row somebody else's latency,
      // and a per-item map is the only way a row's `calls` are its own.
      final shared = http.Client();
      final master = target.collector();
      // Throttled stages retried, printed with the failures: a cloud row
      // that had to wait is a slower row, and the wall clock above cannot
      // say why on its own.
      var retries = 0;
      final startedAt = DateTime.now();

      try {
        await forEachBounded(set.items.indexed, k, (pair) async {
          final (index, item) = pair;
          final entry = entries[index];
          final itemCalls = <String, LlmCallRecord>{};
          final client = target.client(
            httpClient: shared,
            onCall: (r) {
              master.record(r);
              itemCalls[r.label] = r;
            },
          )..onReasoningLeak = master.noteLeak;

          // Each stage in its own try: a message the model cannot answer must
          // cost its own section and nothing else. The observer has already
          // recorded the failed call with its outcome, so the catch has
          // nothing to do but let the next stage start.
          try {
            final triage = await retryingUnavailable(
              () => runTask(
                client,
                const TriageTask(),
                TriageInput(
                  item.message,
                  item.now,
                  thread: item.threadFor(ctx),
                  attachments: item.attachmentRows,
                ),
                think: BenchTarget.allowReasoning,
              ),
              onRetry: () => retries++,
            );
            entry.triage = triageOut(triage);
          } on LlmException catch (_) {
            // Recorded by the observer, with its outcome.
          }

          if (item.floorSaysYes) {
            // The handler checks the deterministic floor BEFORE it calls, so a
            // replay that asked the model here would be benching a path the
            // app never takes — and paying for a call the app never makes.
            entry.needsYou = floorOut();
          } else {
            try {
              final needsYou = await retryingUnavailable(
                () => runTask(
                  client,
                  const NeedsYouTask(),
                  NeedsYouInput(
                    message: item.message,
                    thread: item.threadFor(ctx),
                    ownerName: GoldenDefines.ownerName,
                    ownerAddress: GoldenDefines.ownerAddress,
                    now: item.now,
                  ),
                  // The handler's own parameters, both of them: a different
                  // temperature or budget measures a pipeline nobody ships.
                  temperature: 0,
                  maxTokens: 256,
                  think: BenchTarget.allowReasoning,
                ),
                onRetry: () => retries++,
              );
              entry.needsYou = needsYouOut(needsYou);
            } on LlmException catch (_) {
              // Recorded by the observer, with its outcome.
            }
          }

          try {
            final extraction = await retryingUnavailable(
              () => runTask(
                client,
                const ExtractTask(),
                ExtractionInput(item.message, item.now),
                temperature: 0,
                think: BenchTarget.allowReasoning,
              ),
              onRetry: () => retries++,
            );
            entry.extract = extractOut(extraction);
          } on LlmException catch (_) {
            // Recorded by the observer, with its outcome.
          }

          for (final call in itemCalls.entries) {
            entry.calls[call.key] = callOf(call.value);
          }

          final triage = entry.triage;
          final extract = entry.extract;
          final needsYou = entry.needsYou;
          final needsYouMs = (needsYou?.floor ?? false)
              ? 'floor'
              : _ms(itemCalls['needs_you']);
          lines[index] = '${item.id.padRight(40)} '
              'triage ${_ms(itemCalls['triage'])}  '
              'needs_you $needsYouMs  '
              'extract ${_ms(itemCalls['extraction'])}  '
              '${triage == null ? '—' : '${triage.category}/${triage.urgency}'
                  '/needs_action=${triage.needsAction}'
                  '/reply_expected=${triage.replyExpected}'}  '
              'ny=${needsYou == null ? '—' : '${needsYou.verdict}'
                  '(${needsYou.confidence ?? 'floor'})'}  '
              '${extract == null ? '—' : '${extract.intent}/${extract.importance}'}';
        });
      } finally {
        shared.close();
        final wall = DateTime.now().difference(startedAt);
        final items = set.items.length;
        final cost = costSummary(
          tasks: master.tasks,
          url: target.url,
          model: target.model,
          items: items,
        );

        // A Converse row samples at the model's default, and a reader
        // comparing it with a local row has to be told so here.
        final caveat =
            target.wire == LlmWire.bedrockConverse ? '$_converseCaveat\n' : '';

        // ignore: avoid_print
        print(
          '\n${master.banner}\n'
          '$caveat'
          '\n${master.table()}\n'
          '\n${lines.whereType<String>().join('\n')}\n'
          '\n${_failureLine(master, retries)}\n'
          '${_ctxLine(ctx, k, items, wall)}\n'
          '\n${_costBlock(cost, target.url)}\n',
        );

        // The rows that attempted anything — the same rule the prose half
        // applies, so the two files mean the same thing by a missing row.
        final written = [
          for (final entry in entries)
            if (entry.attempted) entry,
        ];
        final runPath = BenchTarget.outDir.isEmpty
            ? null
            : await writeGoldenRun(
                written,
                bench: 'golden-bulk',
                label: target.label,
                outDir: BenchTarget.outDir,
              );
        final timingPath = await writeBenchResult(
          bench: 'golden-bulk',
          collectors: [master],
          accuracy: const [],
          startedAt: startedAt,
          extra: {
            'run_file': runPath,
            'ctx': ctx.name,
            'k': k,
            'wire': target.wireName,
            'retries': retries,
            'items': items,
            'wall_ms': wall.inMilliseconds,
            msgsPerMinKey: msgsPerMinute(items, wall),
            costKey: cost,
            'golden': {
              'path': GoldenDefines.setPath,
              'generated': set.generated,
              'items': items,
              'block_mismatches': _blockMismatches(set),
              'directness_mismatches': _directnessMismatches(set),
              'owner_set': GoldenDefines.ownerName != null ||
                  GoldenDefines.ownerAddress != null,
            },
            if (ctx == GoldenCtx.compressed) 'context_caveat': _compressedCaveat,
          },
        );
        _printPaths(runPath, timingPath);
      }

      // Shape, never quality. Every word inside these fields is the model's
      // judgement and is scored by Python; an EMPTY one is a call that went
      // wrong. Failures are not asserted at all — a run that lost three
      // messages to a timeout still scores the ninety-seven it answered, and
      // the table above already says how many.
      expect(entries, hasLength(set.items.length));
      expect(
        master.tasks.any((m) => m.n > 0),
        isTrue,
        reason: 'no call succeeded — is the server up?',
      );
      for (final entry in entries) {
        final triage = entry.triage;
        if (triage != null) {
          expect(triage.category, isNotEmpty, reason: entry.id);
          expect(triage.urgency, isNotEmpty, reason: entry.id);
          expect(triage.label, isNotEmpty, reason: entry.id);
        }
        final extract = entry.extract;
        if (extract != null) {
          expect(extract.intent, isNotEmpty, reason: entry.id);
          expect(extract.importance, isNotEmpty, reason: entry.id);
        }
      }

      _assertNoLeaks(master);
    },
    // A hundred items times three stages, on a candidate that may answer in
    // twenty seconds a call.
    timeout: const Timeout(Duration(minutes: 90)),
  );

  test(
    'the golden set through reply decision and drafts',
    () async {
      final (set, _) = await _loadOrFail();
      final k = checkK(GoldenDefines.k);
      const target = BenchTarget.prose;

      if (set.keep.isEmpty) {
        fail('the set holds no gold-keep items — the prose half has nothing '
            'to decide on');
      }

      // The decision population is gold-keep; the draft population is the
      // items carrying a reply rubric. An entry exists for every item so the
      // pool can index by position, and the ones that ran neither stage are
      // dropped before the file is written rather than written as empty rows.
      final keepIds = {for (final item in set.keep) item.id};
      final entries = [
        for (final item in set.items)
          GoldenRunEntry(
            id: item.id,
            stratum: item.stratum,
            difficulty: item.difficulty,
          ),
      ];
      final lines = List<String?>.filled(set.items.length, null);

      final warmupClient = target.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        try {
          // Retried for the bulk half's reason: a throttled first call is
          // not a server that is down.
          await retryingUnavailable(
            () => runTask(
              warmupClient,
              const ReplyDecisionTask(),
              ReplyDecisionInput(
                context: set.keep.first.tail,
                message: set.keep.first.message,
                now: set.keep.first.now,
              ),
              temperature: 0,
              maxTokens: 256,
              think: BenchTarget.allowReasoning,
            ),
          );
        } on LlmException catch (e) {
          _warmupFailed('reply_decision', e, target);
        }
      }

      final shared = http.Client();
      final master = target.collector();
      // Throttled stages retried, printed with the failures: a cloud row
      // that had to wait is a slower row, and the wall clock above cannot
      // say why on its own.
      var retries = 0;
      final startedAt = DateTime.now();

      try {
        await forEachBounded(set.items.indexed, k, (pair) async {
          final (index, item) = pair;
          final wantsDecision = keepIds.contains(item.id);
          final wantsDraft = item.gold.hasReply;
          if (!wantsDecision && !wantsDraft) return;

          final entry = entries[index];
          final itemCalls = <String, LlmCallRecord>{};
          final client = target.client(
            httpClient: shared,
            onCall: (r) {
              master.record(r);
              itemCalls[r.label] = r;
            },
          )..onReasoningLeak = master.noteLeak;

          if (wantsDecision) {
            try {
              final decision = await retryingUnavailable(
                () => runTask(
                  client,
                  const ReplyDecisionTask(),
                  // The plain tail, whatever GOLDEN_CTX says. The decision
                  // keeps six messages at 500 characters, so the tail already
                  // fits it whole — the ladder is a question about the two
                  // stages that clip, and answering it here would move a
                  // number for a reason that has nothing to do with context.
                  ReplyDecisionInput(
                    context: item.tail,
                    message: item.message,
                    now: item.now,
                  ),
                  temperature: 0,
                  maxTokens: 256,
                  think: BenchTarget.allowReasoning,
                ),
                onRetry: () => retries++,
              );
              entry.decision = decisionOut(decision);
            } on LlmException catch (_) {
              // Recorded by the observer, with its outcome.
            }
          }

          if (wantsDraft) {
            try {
              final draft = await retryingUnavailable(
                () => runTask(
                  client,
                  const DraftTask(),
                  // The tail with the judged message LAST, because that is
                  // what the task reads: `DraftTask` renders only `thread` and
                  // answers its final message, falling back to `replyTo` alone
                  // when the thread is empty — and the handler's
                  // `loadThread(untilIso: received_at)` includes the judged
                  // message the same way. A bare tail would have the model
                  // answer the message BEFORE the one under test, invisibly on
                  // every row with a tail.
                  //
                  // And nothing else: the set carries no style examples, no
                  // about-me, no storyline summary and no directory pack, so a
                  // draft here measures the MODEL rather than the retrieval
                  // that would feed it in the app. An empty stand-in for any of
                  // them would measure neither.
                  DraftInput(
                    thread: [...item.tail, item.message],
                    replyTo: item.message,
                    now: item.now,
                  ),
                  temperature: 0,
                  maxTokens: 1536,
                  think: BenchTarget.allowReasoning,
                ),
                onRetry: () => retries++,
              );
              entry.draft = draftOut(draft);
            } on LlmException catch (_) {
              // Recorded by the observer, with its outcome.
            }
          }

          for (final call in itemCalls.entries) {
            entry.calls[call.key] = callOf(call.value);
          }

          final decision = entry.decision;
          final draft = entry.draft;
          lines[index] = '${item.id.padRight(40)} '
              'decision ${_ms(itemCalls['reply_decision'])} '
              'needs_reply=${decision?.needsReply ?? '—'}  '
              'draft ${_ms(itemCalls['draft_reply'])} '
              'options=${draft == null ? '—' : draft.options.length}';
        });
      } finally {
        shared.close();
        final wall = DateTime.now().difference(startedAt);
        // The rows that attempted anything. An entry for an item in neither
        // population never did, and the run file's rule is that an omitted
        // section means "not attempted" — so a row that attempted nothing is
        // not a row, while one whose only stage failed still is: its `calls`
        // say what went wrong.
        final written = [
          for (final entry in entries)
            if (entry.attempted) entry,
        ];
        final cost = costSummary(
          tasks: master.tasks,
          url: target.url,
          model: target.model,
          items: written.length,
        );

        // A Converse row samples at the model's default, and a reader
        // comparing it with a local row has to be told so here.
        final caveat =
            target.wire == LlmWire.bedrockConverse ? '$_converseCaveat\n' : '';

        // ignore: avoid_print
        print(
          '\n${master.banner}\n'
          '$caveat'
          '\n${master.table()}\n'
          '\n${lines.whereType<String>().join('\n')}\n'
          '\n${_failureLine(master, retries)}\n'
          'ctx tail (fixed), k $k, ${written.length} items in '
          '${wall.inSeconds}s, '
          '${msgsPerMinute(written.length, wall).toStringAsFixed(1)} msgs/min\n'
          '\n${_costBlock(cost, target.url)}\n',
        );

        final runPath = BenchTarget.outDir.isEmpty
            ? null
            : await writeGoldenRun(
                written,
                bench: 'golden-prose',
                label: target.label,
                outDir: BenchTarget.outDir,
              );
        final timingPath = await writeBenchResult(
          bench: 'golden-prose',
          collectors: [master],
          accuracy: const [],
          startedAt: startedAt,
          extra: {
            'run_file': runPath,
            'ctx': 'tail (fixed)',
            'draft_context': 'message + tail only',
            'k': k,
            'wire': target.wireName,
            'retries': retries,
            'items': written.length,
            'decisions': keepIds.length,
            'drafts': set.items.where((i) => i.gold.hasReply).length,
            'wall_ms': wall.inMilliseconds,
            msgsPerMinKey: msgsPerMinute(written.length, wall),
            costKey: cost,
            'golden': {
              'path': GoldenDefines.setPath,
              'generated': set.generated,
              'items': set.items.length,
              'block_mismatches': _blockMismatches(set),
              'directness_mismatches': _directnessMismatches(set),
            },
          },
        );
        _printPaths(runPath, timingPath);
      }

      expect(
        master.tasks.any((m) => m.n > 0),
        isTrue,
        reason: 'no call succeeded — is the server up?',
      );
      // Shape only, and the shape the SCHEMA promises: a string. Neither
      // schema sets a minimum length, so an empty reason or body is a poor
      // answer for the judge to fail, not a broken run for this test to fail —
      // Sonnet 5 on Bedrock returned one empty reason in 76 decisions, and
      // failing the whole row for it would have thrown away the other 75.
      for (final entry in entries) {
        final decision = entry.decision;
        if (decision != null) {
          expect(decision.reason, isA<String>(), reason: entry.id);
        }
        final draft = entry.draft;
        if (draft != null) {
          expect(draft.body, isA<String>(), reason: entry.id);
        }
      }

      _assertNoLeaks(master);
    },
    timeout: const Timeout(Duration(minutes: 90)),
  );
}

/// The set and the rung both halves run on, or a failure that says what to run.
///
/// A missing `GOLDEN_SET` is the one failure worth catching before anything
/// else happens: `loadGoldenSet('')` would report that no file exists at the
/// empty path, which is true and tells nobody what to do about it.
Future<(GoldenSet, GoldenCtx)> _loadOrFail() async {
  if (GoldenDefines.setPath.isEmpty) {
    fail('GOLDEN_SET is not defined — run via make golden / make golden-prose '
        '(the Makefile passes it); a bare flutter test cannot find the set');
  }
  final set = await loadGoldenSet(GoldenDefines.setPath);
  if (set.items.isEmpty) {
    fail('the golden set at ${GoldenDefines.setPath} holds no items — '
        'nothing to replay');
  }
  final ctx = parseGoldenCtx(GoldenDefines.ctxRaw);
  final k = checkK(GoldenDefines.k);
  final owner = GoldenDefines.ownerName != null ||
      GoldenDefines.ownerAddress != null;
  // ignore: avoid_print
  print(
    'golden: ${set.items.length} items, generated ${set.generated}, '
    'block mismatches ${_blockMismatches(set)}, '
    'directness mismatches ${_directnessMismatches(set)}, '
    'owner ${owner ? 'set' : 'NOT set (GOLDEN_OWNER_NAME/ADDRESS empty — '
        'needs-you reads no owner line)'}, '
    'ctx ${ctx.name}, k $k',
  );
  return (set, ctx);
}

/// How many items the app no longer renders into the block the set recorded.
///
/// Printed rather than asserted, and printed on every run: anything above zero
/// means the prompt renderer moved since the set was packed, and every accuracy
/// number below it is measuring a prompt the app does not send.
int _blockMismatches(GoldenSet set) =>
    set.items.where((item) => !item.blockMatches).length;

/// The same count for the directness line — the other half of the round trip,
/// read by triage, needs-you and the reply decision alike, so drift there
/// moves every number with nothing else saying so.
int _directnessMismatches(GoldenSet set) =>
    set.items.where((item) => !item.directnessMatches).length;

/// Fails the run over a dead server WITHOUT repeating what the server said.
///
/// The exception's own text is the one thing this file must not print: an
/// `LlmFormatException` carries a snippet of the model's answer, and the
/// warmup's answer is a summary of a real message. So the failure names the
/// stage, the exception's kind, the status code and the target, and nothing
/// the model wrote.
Never _warmupFailed(String stage, LlmException e, BenchTarget target) => fail(
      'warmup $stage call failed (${e.runtimeType}'
      '${e.statusCode == null ? '' : ', HTTP ${e.statusCode}'}) — '
      'is the server at ${target.url} up?',
    );

String _ms(LlmCallRecord? record) =>
    record == null ? '—' : '${record.durationMs}ms';

/// Failures per stage, from the collector's own buckets. Read rather than
/// `metricsFor`'d: that one creates the bucket it looks in, which would put an
/// empty row for a stage nobody ran into the table and the result JSON.
String _failureLine(CallCollector master, int retries) =>
    'failures: ${[for (final m in master.tasks) '${m.task} ${m.failures}'].join(', ')}'
    ', retried $retries'
    // A retried attempt is a recorded failure that a later attempt answered
    // for, so the two numbers overlap and the line has to say so.
    '${retries == 0 ? '' : ' (each retried attempt is counted among the failures above)'}';

String _ctxLine(GoldenCtx ctx, int k, int items, Duration wall) {
  final head = 'ctx ${ctx.name}, k $k, $items items in ${wall.inSeconds}s, '
      '${msgsPerMinute(items, wall).toStringAsFixed(1)} msgs/min';
  return switch (ctx) {
    GoldenCtx.compressed => '$head\n$_compressedCaveat',
    GoldenCtx.none => '$head\n$_noneCaveat',
    GoldenCtx.tail3 => head,
  };
}

/// The cost block, in dollars nobody has to divide by hand.
///
/// An em dash for an unpriced stage, never a zero, and the note beside the
/// total says which of the two silences it is: a local server costs nothing per
/// token and a remote model the table does not price costs an unknown amount.
String _costBlock(Map<String, Object?> cost, String url) {
  final perStage = cost['per_stage'] as Map<String, Object?>;
  final total = cost['total_usd'] as double?;
  final rows = [
    for (final stage in perStage.entries)
      '  ${stage.key}: '
          '${_usd((stage.value as Map<String, Object?>)['usd'] as double?)}',
  ];
  return 'cost (list prices as of ${cost['prices_dated']}):\n'
      '${rows.join('\n')}\n'
      '  total ${_usd(total)}   per 1K msgs '
      '${_usd(cost[per1kKey] as double?)}'
      '${total == null && !isLocalUrl(url) ? '  (unpriced model — not free, unknown)' : ''}';
}

String _usd(double? value) =>
    value == null ? '—' : '\$${value.toStringAsFixed(4)}';

/// Where the two halves of a run landed, and the command that scores one of
/// them. Printed together because the scoring command is the next thing anyone
/// types, and a path they have to reconstruct by hand is a path they mistype.
void _printPaths(String? runPath, String? timingPath) {
  final lines = [
    if (runPath == null)
      'BENCH_OUT not set — no run file written'
    else
      'wrote $runPath',
    if (timingPath != null) 'wrote $timingPath',
    if (runPath != null) 'next: make golden-score R=$runPath',
  ];
  // ignore: avoid_print
  print(lines.join('\n'));
}

/// The tripwire, exactly as every other bench states it: a build that ignores
/// `enable_thinking` runs at half speed and every latency above would be
/// measuring that instead of the candidate. A model that cannot be told to
/// stop reasoning is the one exception and has to say so deliberately.
void _assertNoLeaks(CallCollector master) {
  if (BenchTarget.allowReasoning) {
    // ignore: avoid_print
    print('reasoning leaks: ${master.reasoningLeaks} '
        '(not asserted — BENCH_THINK is set)');
  } else {
    expect(master.reasoningLeaks, 0,
        reason: 'the model reasoned despite enable_thinking');
  }
}
