@Skip('live — needs the golden set, and a server for all of it but the gate '
    'replay. Run: make golden (bulk), make golden-prose (prose), '
    'make golden-storyline (storyline confirm) or make golden-gate (the '
    "app's own gates, offline)")
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/clustering_card.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/message_block.dart'
    show threadDigestCap;
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures/bench_stats.dart';
import 'fixtures/bench_target.dart';
import 'fixtures/golden_gate.dart';
import 'fixtures/golden_harness.dart';
import 'fixtures/golden_prices.dart';
import 'fixtures/golden_registry.dart';
import 'fixtures/golden_run.dart';
import 'fixtures/golden_set.dart';
import 'fixtures/golden_storyline.dart';
import 'fixtures/golden_sweep.dart';
import 'fixtures/live_bench.dart';
import 'fixtures/storyline_seed.dart';
import 'fixtures/vec_test_db.dart';

/// The golden set through the app's real tasks, on whatever server the defines
/// point at.
///
/// This is the run behind a golden-ledger row, and it produces BOTH halves of
/// one in a single pass: a run file `golden/tools/score_run.py` scores for
/// accuracy, and the ordinary bench timing JSON beside it for speed and cost.
/// Two passes would be two different sets of answers timed separately, which
/// is one more thing a ledger row could be wrong about.
///
/// **One of the four tests needs no server at all.** `make golden-gate`
/// replays the app's own gates, which are pure functions over what the set
/// carries, so that one has no warmup, no timing JSON and no cost block —
/// `fixtures/golden_gate.dart` states what it can and cannot see.
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

/// The caveat every `digest` row is quoted with. The digest is no longer
/// clipped to a thread message's 300 characters — it rides in its own fence
/// at [threadDigestCap] — so this rung is a measurement of compression rather
/// than of a clipped head of one, and the extraction half is on its own knob.
const String _digestCaveat =
    'ctx digest: the digest as its own $threadDigestCap-character fence above '
    'the tail; extraction reads the rung GOLDEN_EXTRACT_CTX names';

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
      final set = await _loadOrFail();
      // Both rungs are read HERE rather than in `_loadOrFail`: the prose,
      // storyline and gate tests share that helper and not one of them runs
      // an extraction or a context rung.
      final ctx = parseGoldenCtx(GoldenDefines.ctxRaw);
      final extractCtx = parseExtractCtx(GoldenDefines.extractCtxRaw);
      final k = checkK(GoldenDefines.k);
      const target = BenchTarget.bulk;

      // What the digest rung actually carried, counted once over the set
      // rather than guessed from the rung's name: an item with no earlier
      // thread has no digest, and a digest over the fence's cap is read only
      // in part. Both numbers are printed, because a rung that moved nothing
      // on two thirds of the set is a different result from one that did.
      // Counted only when a digest reached a prompt: at `none`, `tail3` and
      // `compressed` (which clips at 300, not 900) the line would describe a
      // fence the run never wrote.
      final digestRung =
          ctx == GoldenCtx.digest || extractCtx == GoldenCtx.digest;
      final carried = !digestRung
          ? null
          : set.items.where((item) => item.digest != null).length;
      final trimmed = !digestRung
          ? null
          : set.items
              .where((item) => (item.digest?.length ?? 0) > threadDigestCap)
              .length;

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
                  threadDigest: item.digestFor(ctx),
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
                    threadDigest: item.digestFor(ctx),
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
                ExtractionInput(
                  item.message,
                  item.now,
                  thread: item.threadFor(extractCtx),
                  threadDigest: item.digestFor(extractCtx),
                ),
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
          '${_ctxLine(ctx, extractCtx, k, items, wall)}\n'
          '${carried == null ? '' : 'digests: $carried items carry one, '
              '$trimmed trimmed to $threadDigestCap\n'}'
          '\n${_costBlock(cost, target.url)}\n',
        );

        // The rows that attempted anything — the same rule the prose half
        // applies, so the two files mean the same thing by a missing row.
        final written = [
          for (final entry in entries)
            if (entry.attempted) entry,
        ];
        final paths = await _triageBench.writeRun(
          entries: written,
          label: target.label,
          collectors: [master],
          startedAt: startedAt,
          extra: (runPath) => {
            'run_file': runPath,
            'ctx': ctx.name,
            'extract_ctx': extractCtx.name,
            'digests_carried': ?carried,
            'digests_trimmed': ?trimmed,
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
        _triageBench.printPaths(
          runPath: paths.runPath,
          resultPath: paths.resultPath,
        );
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
      final set = await _loadOrFail();
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
                  maxTokens: DraftHandler.draftMaxTokens,
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

        final paths = await _proseBench.writeRun(
          entries: written,
          label: target.label,
          collectors: [master],
          startedAt: startedAt,
          extra: (runPath) => {
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
        _proseBench.printPaths(
          runPath: paths.runPath,
          resultPath: paths.resultPath,
        );
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

  /// The confirm task against the gold registry, item by item.
  ///
  /// **What it measures.** `ConfirmMembershipTask` alone — "does this thread
  /// belong to this storyline" — asked of every golden item against a BOUNDED
  /// candidate list: the item's gold storyline, every registry storyline gold
  /// marks forbidden on it, and three more drawn by a seeded shuffle. Each
  /// registry storyline arrives as the app's own [Storyline] with its charter
  /// as the criterion and its people drawn from the set; each candidate card is
  /// built the way `enrichedCardForConversationRow` builds one, from a bulk run
  /// file's topics and summary.
  ///
  /// **What it does NOT measure.** Everything around the call: the sweep that
  /// proposes storylines, the embeddings and thresholds that shortlist them,
  /// the recruit laps, the chaining, and the owner's kept and removed examples
  /// — a gold storyline has no owner history, so both fences ride in empty.
  /// Those are code, and the golden set says the stage they sit around has
  /// never once been right; this run asks whether the MODEL is the reason.
  /// Nor is it the app's economics: the app asks one confirmation per
  /// assignment and this asks four or five per message.
  test(
    'the golden set through storyline confirm',
    () async {
      final set = await _loadOrFail();
      final k = checkK(GoldenDefines.k);
      final charterCap = checkCharterCap(GoldenDefines.charterCap);
      const target = BenchTarget.bulk;

      if (GoldenDefines.registryPath.isEmpty) {
        fail('GOLDEN_REGISTRY is not defined — run via make golden-storyline '
            '(the Makefile passes it); a bare flutter test cannot find the '
            'registry');
      }
      final registry = await loadGoldenRegistry(GoldenDefines.registryPath);
      if (GoldenDefines.runPath.isEmpty) {
        fail('GOLDEN_RUN=<bulk run file from make golden> is not defined — a '
            'candidate card carries that run\'s extraction topics and triage '
            'summary, exactly as the app\'s card carries the newest inbound '
            'message\'s, so a replay without one would judge a thinner card '
            'than the app ever sends');
      }
      final cards = await loadGoldenCards(GoldenDefines.runPath);
      if (cards.size == 0) {
        // A STORYLINE run file is a JSON array of the same shape and carries
        // no topics and no summary, so pointing GOLDEN_RUN at one loads
        // cleanly and then judges a hundred items on a card the app never
        // sends. Ninety minutes and a whole ledger row, lost silently.
        fail('the run file at ${GoldenDefines.runPath} carries no cards — '
            'GOLDEN_RUN wants a BULK run file from make golden (a storyline '
            'run file has the same shape and no topics or summary)');
      }

      // Per slug once: the storyline object is the same on every prompt it
      // appears in. Its PEOPLE are not — they depend on which candidate is
      // being asked about — so they are computed per call below.
      final storylines = <String, Storyline>{};
      for (final slug in registry.slugs) {
        storylines[slug] = registry.bySlug[slug]!.toAppStoryline();
      }
      final candidates = {
        for (final item in set.items) item.id: candidatesFor(item, registry),
      };

      // A gold slug the registry does not carry is dropped by `candidatesFor`,
      // which shrinks the gold denominator and reads in the ledger as a model
      // that got worse. The set and the registry are packed together, so this
      // is zero or the two files do not belong to each other — and the second
      // is worth stopping for rather than quoting. Counted, never named.
      final missingGold = set.items
          .where((item) =>
              item.gold.storylineId != 'none' &&
              !registry.bySlug.containsKey(item.gold.storylineId))
          .length;
      if (missingGold > 0) {
        fail('$missingGold items are gold-filed under a storyline the '
            'registry at ${GoldenDefines.registryPath} does not carry — the '
            'set and the registry do not belong to each other');
      }

      final calls = candidates.values.fold(0, (sum, list) => sum + list.length);
      // What the old "no participants" count really measured: a registry
      // storyline no golden item is filed under, which has nobody whatever is
      // excluded.
      final filedSlugs = {
        for (final item in set.items) item.gold.storylineId,
      };
      final storylinesWithoutItems =
          registry.slugs.where((slug) => !filedSlugs.contains(slug)).length;
      // And the count the exclusion creates: a gold candidate whose storyline
      // has no OTHER golden thread, so it is judged with an empty People line.
      // Thinner than the app's prompt, which penalises rather than flatters —
      // but a reader has to know how much of the gold-accept rate was asked
      // that way. From the set alone; no call needed.
      final goldPeopleEmpty = set.items
          .where((item) =>
              registry.bySlug.containsKey(item.gold.storylineId) &&
              participantsFor(
                item.gold.storylineId,
                set,
                excludingConversation: item.conversationKey,
              ).isEmpty)
          .length;
      final overCap = registry.storylines
          .where((storyline) => storyline.charter.length > charterCap)
          .length;
      final carded =
          set.items.where((item) => cards.byId.containsKey(item.id)).length;

      // ignore: avoid_print
      print(
        'storyline: ${registry.storylines.length} storylines, '
        '${registry.antiSlugs.length} anti, $calls candidate calls over '
        '${set.items.length} items, $storylinesWithoutItems storylines with '
        'no item in the set, $goldPeopleEmpty gold candidates judged with an '
        'empty People line, $missingGold gold slugs missing from the '
        'registry, $overCap charters over the task\'s $charterCap-char clamp, '
        'cards from the run for $carded of ${set.items.length} items',
      );

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
      final tally = StorylineTally();

      final first = set.items.first;
      final firstCandidates = candidates[first.id]!;
      if (firstCandidates.isEmpty) {
        fail('the first item has no candidate storyline — the registry at '
            '${GoldenDefines.registryPath} and the set do not belong to each '
            'other');
      }
      final warmupClient = target.client();
      for (var i = 0; i < BenchTarget.warmup; i++) {
        try {
          // Retried like every other call, for the bulk half's reason: a
          // throttled first call is not a server that is down.
          await retryingUnavailable(
            () => runTask(
              warmupClient,
              ConfirmMembershipTask(charterCap: charterCap),
              ConfirmInput(
                storyline: storylines[firstCandidates.first]!,
                storylineParticipants: participantsFor(
                  firstCandidates.first,
                  set,
                  excludingConversation: first.conversationKey,
                ),
                candidateCard: candidateCardFor(first, cards.byId[first.id]),
              ),
              temperature: 0,
              think: BenchTarget.allowReasoning,
            ),
          );
        } on LlmException catch (e) {
          _warmupFailed('storyline_membership', e, target);
        }
      }

      final shared = http.Client();
      final master = target.collector();
      var retries = 0;
      final startedAt = DateTime.now();

      try {
        await forEachBounded(set.items.indexed, k, (pair) async {
          final (index, item) = pair;
          final entry = entries[index];
          // A LIST rather than a map by label: every confirmation on this item
          // carries the same label, `storyline_membership`, so a map keyed by
          // it would keep the last call and silently drop the three or four
          // the item also paid for.
          final itemRecords = <LlmCallRecord>[];
          final client = target.client(
            httpClient: shared,
            onCall: (r) {
              master.record(r);
              itemRecords.add(r);
            },
          )..onReasoningLeak = master.noteLeak;

          // Built once per item: the card is what varies between ITEMS and is
          // constant across an item's candidates, which is also the order the
          // task puts its fences in so a server's prefix cache stays warm.
          final card = candidateCardFor(item, cards.byId[item.id]);
          final outcomes = <ConfirmOutcome>[];

          // Sequentially, in candidate order. The concurrency of this run is
          // GOLDEN_K items, never candidates within an item: the four prompts
          // of one item share their storyline-fence prefix only if they arrive
          // one after another.
          for (final slug in candidates[item.id]!) {
            ConfirmResult? result;
            try {
              result = await retryingUnavailable(
                () => runTask(
                  client,
                  ConfirmMembershipTask(charterCap: charterCap),
                  ConfirmInput(
                    storyline: storylines[slug]!,
                    // Per candidate, not per slug: this thread is never among
                    // the members the storyline is described by, because in
                    // the app a candidate is by construction not yet one. A
                    // whole-set union would hand the model the candidate's own
                    // people back as the storyline's, on every gold question
                    // it is asked. 453 scans of a hundred items costs nothing
                    // against the call they precede.
                    storylineParticipants: participantsFor(
                      slug,
                      set,
                      excludingConversation: item.conversationKey,
                    ),
                    candidateCard: card,
                  ),
                  // The handler's own temperature: the same thread judged
                  // against the same storyline twice must give the same
                  // answer (storyline_service.dart).
                  temperature: 0,
                  think: BenchTarget.allowReasoning,
                ),
                onRetry: () => retries++,
              );
            } on LlmException catch (_) {
              // Recorded by the observer, with its outcome.
            }
            outcomes.add(ConfirmOutcome(
              slug: slug,
              kind: kindOf(item, slug),
              result: result,
            ));
          }

          final derived = deriveStorylineId(outcomes);
          entry.storylineId = derived.id;
          if (itemRecords.isNotEmpty) {
            entry.calls['storyline_membership'] = summariseCalls(itemRecords);
          }
          tally.add(item, outcomes, derived);

          final totalMs =
              itemRecords.fold<int>(0, (sum, r) => sum + r.durationMs);
          final forbidden = outcomes
              .where((o) => o.kind == CandidateKind.forbidden)
              .toList();
          final extra =
              outcomes.where((o) => o.kind == CandidateKind.extra).toList();
          // Ids, counts, milliseconds and enums. No slug, no title, no
          // evidence sentence and no card text: the registry's slugs are
          // derived from real project names, and scrollback is how they leak.
          lines[index] = '${item.id.padRight(40)} '
              'calls ${outcomes.length}  ${totalMs}ms  '
              'gold=${goldCell(outcomes)}  '
              'forbidden ${forbidden.where((o) => o.accepted).length}'
              '/${forbidden.where((o) => o.result != null).length}  '
              'extra ${extra.where((o) => o.accepted).length}'
              '/${extra.where((o) => o.result != null).length}  '
              'derived=${derivedBucket(item, derived)}'
              '${derived.tie ? ' tie' : ''}';
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

        // The calls MADE, which is what a rate has to be divided by. `calls`
        // is what the shortlist PLANNED: the two agree on a pass where nothing
        // failed and nothing was retried, and where they disagree the planned
        // number flatters a server that refused half of them. Both are
        // printed, so a reader can see which pass this was.
        final callsMade = _callsMade(master);

        // ignore: avoid_print
        print(
          '\n${master.banner}\n'
          '$caveat'
          '\n${master.table()}\n'
          '\n${lines.whereType<String>().join('\n')}\n'
          '\n${tally.table()}\n'
          '\n${_failureLine(master, retries)}\n'
          'k $k, charter cap $charterCap, $items items, '
          '$callsMade of $calls calls in '
          '${wall.inSeconds}s, '
          '${msgsPerMinute(items, wall).toStringAsFixed(1)} msgs/min, '
          '${msgsPerMinute(callsMade, wall).toStringAsFixed(1)} calls/min\n'
          '\n${_costBlock(cost, target.url)}\n',
        );

        final written = [
          for (final entry in entries)
            if (entry.attempted) entry,
        ];
        final paths = await _storylineBench.writeRun(
          entries: written,
          // The label carries the half, so `slug()` names the file
          // `…-storyline-<stamp>.json`. A bulk run and a storyline run
          // under one BENCH_LABEL would otherwise differ by a timestamp
          // alone, and feeding the wrong one back as GOLDEN_RUN is
          // exactly the mistake the zero-cards guard above catches.
          label: '${target.label} storyline',
          collectors: [master],
          startedAt: startedAt,
          extra: (runPath) => {
            'run_file': runPath,
            'cards_from': GoldenDefines.runPath,
            'k': k,
            'wire': target.wireName,
            'retries': retries,
            'items': items,
            'calls': calls,
            'calls_made': callsMade,
            'wall_ms': wall.inMilliseconds,
            msgsPerMinKey: msgsPerMinute(items, wall),
            // The calls MADE, failures included, from Round F on. Before it
            // this divided `calls`, the number the shortlist planned.
            'calls_per_min': msgsPerMinute(callsMade, wall),
            costKey: cost,
            'storyline': {
              ...tally.toJson(),
              'registry': {
                'path': GoldenDefines.registryPath,
                'storylines': registry.storylines.length,
                'anti': registry.antiSlugs.length,
                'storylines_without_items': storylinesWithoutItems,
                'gold_people_empty': goldPeopleEmpty,
                'charter_cap': charterCap,
                'charters_over_cap': overCap,
                'cards_from_run': carded,
              },
            },
            'golden': {
              'path': GoldenDefines.setPath,
              'generated': set.generated,
              'items': items,
              'block_mismatches': _blockMismatches(set),
              'directness_mismatches': _directnessMismatches(set),
            },
          },
        );
        _storylineBench.printPaths(
          runPath: paths.runPath,
          resultPath: paths.resultPath,
        );
      }

      // Shape, never quality — and there is unusually little shape left to
      // assert. `ConfirmMembershipTask.validate` already fixes all three
      // fields: `belongs` is an identity check against `true`, `confidence` is
      // one of three words or `low`, and `evidence` is a clamped non-nullable
      // String. So what remains is that every item got a row, that something
      // answered at all, and the reasoning tripwire.
      expect(entries, hasLength(set.items.length));
      expect(
        master.tasks.any((m) => m.n > 0),
        isTrue,
        reason: 'no call succeeded — is the server up?',
      );
      _assertNoLeaks(master);
    },
    // A hundred items times four or five confirmations, on a candidate that
    // may answer in twenty seconds a call.
    timeout: const Timeout(Duration(minutes: 90)),
  );

  /// The golden set through the app's own GATES, and nothing else.
  ///
  /// The odd one out in this file: no server, no model, no warmup, no clock.
  /// The gates are pure, so this replays them over the set and reports what
  /// they answered — see `fixtures/golden_gate.dart` for the three things the
  /// set cannot ask (Tier 2 mail headers, and the two Teams ingest gates) and
  /// why this number is not the same measurement as `make golden-baseline`'s.
  ///
  /// The golden set through the app's OWN filing path: the sweep that forms
  /// clusters, the naming pass, the per-member confirms and the assign
  /// shortlist.
  ///
  /// The confirm replay above hands the model a candidate list a PERSON wrote
  /// and asks how well it judges one. This asks the question that list skips:
  /// given a mailbox, does the app put the right threads in front of it at
  /// all. So nothing here is a stand-in — the test seeds the conversations,
  /// messages, triage summaries, extraction topics and live embeddings behind
  /// the golden items (`fixtures/storyline_seed.dart`), then runs the real
  /// `StorylineService` over them and reads the memberships back out.
  ///
  /// **The owner keeps everything.** After each sweep pass every `suggested`
  /// storyline is kept, and the pass runs again until it proposes nothing.
  /// That is the only way to get past `maxPendingSuggestions`, which is a
  /// `static const` of three, and it is also the honest emulation of an owner
  /// who accepts what the sweep offers. It has one consequence worth stating:
  /// a kept storyline is `active` before the assign pass runs, so any rule
  /// that treats a `suggested` storyline more strictly is exercised here by
  /// the sweep's own member confirms and never by the assign pass.
  ///
  /// **Three further limits ride on every row.** The pool is the 95
  /// conversations behind a hundred items, 71 of them with a kept inbound
  /// message, against a live mailbox of hundreds, so it UNDER-states chaining. The owner's kept and removed examples and
  /// the recruit laps never run, because a seeded mailbox has no owner
  /// history. And the gate verdict seeded is GOLD's, not the app's, so this
  /// measures the sweep over a correctly gated pool — `make golden-gate`
  /// measures the gates.
  ///
  /// **Scoring is membership, not title.** Each app storyline is mapped to a
  /// registry slug by the plurality of its members' gold ids, and an item's
  /// derived `storyline.id` is that slug — `unmapped` when its storyline
  /// answers to no effort, `none` when its thread was filed nowhere. That goes
  /// into a run file `make golden-score` reads with the toolkit's own rules.
  /// `make golden-baseline` resolves the app's stored TITLE to a slug instead;
  /// the two are the same stage read two ways.
  ///
  /// **Two readings ride alongside since Round D Phase 6.** The bench watches
  /// every cluster BEFORE the namer sees it, through the service's
  /// `clusterObserver` seam, and prints each one's gold purity by what the
  /// sweep then did with it — which is what tells a namer that declines pure
  /// groups from a clustering that builds mixed ones. It also prints the
  /// cosine of every pool pair, split by whether the two threads share a gold
  /// effort, which is the ceiling any threshold could reach. Both are counts
  /// only; the per-cluster shares stay in the result JSON.
  test(
    'the golden set through the sweep and the assign shortlist',
    () async {
      if (GoldenDefines.setPath.isEmpty) {
        fail('GOLDEN_SET is not defined — run via make golden-sweep (the '
            'Makefile passes it); a bare flutter test cannot find the set');
      }
      final set = await _decoded(
        GoldenDefines.setPath,
        () => loadGoldenSet(GoldenDefines.setPath),
      );
      if (set.items.isEmpty) {
        fail('the golden set at ${GoldenDefines.setPath} holds no items — '
            'nothing to replay');
      }
      if (GoldenDefines.registryPath.isEmpty) {
        fail('GOLDEN_REGISTRY is not defined — run via make golden-sweep '
            '(the Makefile passes it); a bare flutter test cannot find the '
            'registry');
      }
      final registry = await _decoded(
        GoldenDefines.registryPath,
        () => loadGoldenRegistry(GoldenDefines.registryPath),
      );
      // A gold slug the registry does not carry cannot be mapped to, so every
      // item filed under it would read as a miss the app never made. The set
      // and the registry are packed together, so this is zero or the two files
      // do not belong to each other. Counted, never named.
      final missingGold = set.items
          .where((item) =>
              item.gold.storylineId != noneId &&
              !registry.bySlug.containsKey(item.gold.storylineId))
          .length;
      if (missingGold > 0) {
        fail('$missingGold items are gold-filed under a storyline the '
            'registry at ${GoldenDefines.registryPath} does not carry — the '
            'set and the registry do not belong to each other');
      }
      if (GoldenDefines.runPath.isEmpty) {
        fail('GOLDEN_RUN=<bulk run file from make golden> is not defined — '
            "the seeded mailbox's triage summaries and extraction topics come "
            'from that run, exactly as the app\'s own card carries the newest '
            'inbound message\'s, so a replay without one would cluster '
            'thinner cards than the app ever embeds');
      }
      final cards = await _decoded(
        GoldenDefines.runPath,
        () => loadGoldenCards(GoldenDefines.runPath),
      );
      if (cards.size == 0) {
        // A STORYLINE or SWEEP run file is a JSON array of the same shape and
        // carries no topics and no summary, so pointing GOLDEN_RUN at one
        // loads cleanly and then embeds a hundred cards the app never builds.
        fail('the run file at ${GoldenDefines.runPath} carries no cards — '
            'GOLDEN_RUN wants a BULK run file from make golden (a storyline '
            'or sweep run file has the same shape and no topics or summary)');
      }
      final variant = parseSweepCard(GoldenDefines.sweepCardRaw);
      final stage = parseSweepStage(GoldenDefines.sweepStageRaw);
      final prefix = GoldenDefines.sweepEmbedPrefix;

      final db = vecTestDb();
      final store = MessageStore(db);
      final confirmCollector = BenchTarget.bulk.collector();
      final nameCollector = BenchTarget.prose.collector();
      final startedAt = DateTime.now();

      try {
        final report = await seedGoldenMailbox(
          store,
          set,
          cards,
          variant: variant,
          prefix: prefix,
          embeddings: EmbeddingsClient(),
          // Literals, exactly as the app hands the owner's identity to
          // needs-you: a bench has no keychain and must never grow a second
          // path to one.
          ownerName: GoldenDefines.ownerName ?? '',
          ownerAddress: GoldenDefines.ownerAddress ?? '',
        );
        // ignore: avoid_print
        print(
          'stage ${stage.name}, card ${variant.wireName}, '
          'prefix length ${report.prefixLength}, dims ${report.dims}, '
          'cards from the run for '
          '${set.items.where((i) => cards.byId.containsKey(i.id)).length} of '
          '${set.items.length} items\n'
          '${report.table()}',
        );
        if (report.embedded == 0) {
          fail('nothing embedded — is the embedding server up? '
              '(EMBED_URL ${EmbeddingsClient.defaultBaseUrl}, make embed)');
        }
        if (report.embedFailures > 0) {
          // The row would MIX card variants. A thread the seeding failed to
          // embed is embedded later by `_reembed`, which builds its card under
          // the app's own flag rather than under SWEEP_CARD — so one thread of
          // the pool would sit in the other variant's geometry and the A/B
          // would be comparing two mailboxes.
          fail('${report.embedFailures} threads did not embed — fix the '
              'embedding server and rerun rather than scoring a pool that '
              'mixes two SWEEP_CARD variants');
        }

        if (stage == SweepStage.vector) {
          await _readTheVectorAlone(
            store: store,
            set: set,
            report: report,
            variant: variant,
            startedAt: startedAt,
          );
          return;
        }

        // The app's own log, because the sweep's per-pass counts — the series
        // it seeded and excluded, the clusters it refused, the outliers it
        // dropped — are written there and nowhere else. The run records a row
        // after each pass and sums them afterwards, rather than the bench
        // keeping a second set of counters that could disagree with the
        // app's.
        final log = ActivityLog(store);
        addTearDown(log.dispose);
        // Every cluster the sweep judged, as it was formed and before the
        // namer narrowed or refused it. The store keeps no record of a
        // declined cluster, so this seam is the only place its gold purity can
        // be read from.
        final judged = <JudgedCluster>[];
        final service = StorylineService(
          store,
          BenchTarget.prose.client(onCall: nameCollector.record)
            ..onReasoningLeak = nameCollector.noteLeak,
          confirmClient: BenchTarget.bulk.client(onCall: confirmCollector.record)
            ..onReasoningLeak = confirmCollector.noteLeak,
          embeddings: EmbeddingsClient(),
          activityLog: log,
          // The overlap rule counts shared people who are not the owner, so
          // the bench has to name the owner the way the app does or every
          // mailbox-wide participant would buy the lower gate.
          owner: () async => GoldenDefines.ownerName == null &&
                  GoldenDefines.ownerAddress == null
              ? null
              : (
                  name: GoldenDefines.ownerName,
                  address: GoldenDefines.ownerAddress
                ),
          clusterObserver: (threads, outcome) => judged.add((
            threads: [
              for (final thread in threads)
                threadKeyOf(thread.source, thread.key),
            ],
            outcome: outcome,
          )),
        );

        // The room cap is a `static const` of three, so the loop KEEPS what it
        // is offered rather than widening it. A pass that leaves the storyline
        // count where it found it has nothing left to propose and ends the
        // loop; the cap of twenty is a guard, not a budget.
        const maxPasses = 20;
        final callsPerPass = <int>[];
        final wallPerPassMs = <int>[];
        var passes = 0;
        var keptSuggestions = 0;
        for (var pass = 1; pass <= maxPasses; pass++) {
          final before = await _storylineCount(store);
          final callsBefore =
              _callsMade(confirmCollector) + _callsMade(nameCollector);
          final passStartedAt = DateTime.now();
          // No retry wrapper: the SERVICE owns its calls, and a server that is
          // down is not a row. An LlmUnavailableException out of here fails
          // the run.
          await service.sweep();
          // The row the app writes on every other trigger. A pass whose every
          // count was zero is suppressed by the log's quiet-kind check, which
          // is exactly right: there is nothing to sum.
          await log.record('storyline_sweep', source: 'email', entityId: 'sweep');
          wallPerPassMs
              .add(DateTime.now().difference(passStartedAt).inMilliseconds);
          callsPerPass.add(
            _callsMade(confirmCollector) + _callsMade(nameCollector) -
                callsBefore,
          );
          passes = pass;

          final after = await _storylineCount(store);
          for (final storyline
              in await store.loadStorylines(statuses: const ['suggested'])) {
            await service.keepSuggestion(storyline.id);
            keptSuggestions++;
          }
          if (after == before) break;
        }

        // Arrival order, which is the order the app files threads in: the
        // assign pass runs per thread as its embedding lands.
        final filed = (await readSweepMembership(store)).storylineByThread;
        final shortlist = [
          for (final thread in report.threads)
            // `embedded` is the belt to the guard above's braces: a thread
            // with no vector would be embedded by `_reembed` inside the assign
            // pass, under the app's flag rather than under SWEEP_CARD.
            if (thread.keptInbound &&
                thread.embedded &&
                !filed.containsKey(
                  threadKeyOf(thread.source, thread.conversationKey),
                ))
              thread,
        ]..sort(
            (a, b) => (a.lastMessageAt ?? '').compareTo(b.lastMessageAt ?? ''),
          );
        final assignOutcomes = <String, int>{};
        for (final thread in shortlist) {
          final outcome = await service.assignConversation(
            thread.source,
            thread.conversationKey,
          );
          assignOutcomes[outcome.name] = (assignOutcomes[outcome.name] ?? 0) + 1;
        }

        // ── what the run filed ────────────────────────────────────────────
        final membership = await readSweepMembership(store);
        final goldByThread = goldSlugByThread(set);
        final mapping = mapStorylinesToSlugs(
          members: membership.threadsByStoryline,
          goldByThread: goldByThread,
        );
        final derived = deriveSweepIds(
          items: set.items,
          storylineByThread: membership.storylineByThread,
          slugByStoryline: mapping,
        );

        final entries = <GoldenRunEntry>[];
        var correctPositives = 0;
        var unmapped = 0;
        var filedNowhere = 0;
        final forbiddenHits = <String, int>{};
        for (final item in set.items) {
          final id = derived[item.id] ?? noneId;
          entries.add(
            GoldenRunEntry(
              id: item.id,
              stratum: item.stratum,
              difficulty: item.difficulty,
            )..storylineId = id,
          );
          if (id == unmappedId) {
            unmapped++;
          } else if (id == noneId) {
            filedNowhere++;
          } else if (id == item.gold.storylineId) {
            correctPositives++;
          }
          if (item.gold.storylineForbidden.contains(id)) {
            forbiddenHits[id] = (forbiddenHits[id] ?? 0) + 1;
          }
        }

        final tombstoned = (await store.loadStorylines(
          statuses: const ['dismissed'],
        ))
            .where((storyline) => storyline.createdBy == 'auto')
            .length;

        // Pairs INSIDE the groups the sweep formed, off the stored vectors —
        // the population a coherence floor would judge. Read from the store
        // rather than from the service, which keeps its clusters to itself.
        final vectors = <String, List<double>>{};
        final displays = <String, List<String>>{};
        final subjects = <String, String>{};
        // The threads the sweep would actually have clustered — `sweep()`
        // diverts a finished one, and the pool lines below have to be over the
        // same population as the vector stage's or the two readings of one
        // mailbox would mean different things. The maps above stay COMPLETE:
        // the in-cluster cosine line and the lint's participant list both walk
        // storyline members, and a finished thread can JOIN a storyline even
        // though it never seeds one. On the golden set nothing is `done`, so
        // both populations are 71 and no measured number moves; this is the
        // definition agreeing with itself, not a correction.
        final poolKeys = <String>{};
        for (final row in await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
          sources: const ['email', 'teams'],
        )) {
          final key = threadKeyOf(
            row['source'] as String? ?? 'email',
            row['conversation_key'] as String? ?? '',
          );
          displays[key] = _displaysOfJson(row['participants_json']);
          subjects[key] = row['subject'] as String? ?? '';
          final blob = row['embedding'];
          if (blob is Uint8List) vectors[key] = decodeEmbedding(blob);
          if ((row['state'] as String?) != 'done') poolKeys.add(key);
        }
        Map<String, T> poolOnly<T>(Map<String, T> all) => {
              for (final entry in all.entries)
                if (poolKeys.contains(entry.key)) entry.key: entry.value,
            };
        final withinCluster = <double>[];
        for (final threads in membership.threadsByStoryline.values) {
          for (var i = 0; i < threads.length; i++) {
            for (var j = i + 1; j < threads.length; j++) {
              final a = vectors[threads[i]];
              final b = vectors[threads[j]];
              if (a == null || b == null) continue;
              withinCluster.add(cosine(a, b));
            }
          }
        }

        // The two Phase 6 readings, both pure arithmetic over what is already
        // in hand. The keep-all loop re-runs the sweep until nothing is
        // proposed, so one cluster is reported once per pass and
        // `distinctClusters` folds the repeats back to one.
        final distinct = distinctClusters(judged);
        final clusterPurity = clusterPurityByOutcome(distinct, goldByThread);
        // Over the WHOLE pool and not just the clusters: the question is
        // whether any threshold could have separated the in-effort pairs from
        // the rest, and the pairs the clustering never joined are most of the
        // evidence for that.
        final pairs = pairCosinesOf(
          vectors: poolOnly(vectors),
          goldByThread: goldByThread,
        );
        // The two lexical readings and the separation, on the same pairs. They
        // cost one walk of a map already in hand, so the full run prints them
        // too rather than making a reader start a second bench to see whether
        // the subject line alone would have done the vector's job.
        final subjectOverlap = pairSubjectOverlapOf(
          subjectByThread: poolOnly(subjects),
          goldByThread: goldByThread,
        );
        final sharedPeople = pairSharedPeopleOf(
          participantsByThread: poolOnly(displays),
          goldByThread: goldByThread,
          ownerDisplays: _ownerDisplays(),
        );
        final separation = separationOf(
          sameEffort: pairs.sameEffort,
          crossEffort: pairs.crossEffort,
        );

        // What SURVIVED that the lint would still refuse. Since Phase 3 the
        // naming pass tombstones a lint hit before its confirms, so this reads
        // over the live storylines and should be zero; a non-zero entry is a
        // bug report, not a measurement.
        final lintCounts = charterLintCounts([
          for (final storyline in await store.loadStorylines(
            statuses: const ['suggested', 'active'],
          ))
            LintCandidate(
              title: storyline.title,
              charter: storyline.charter ?? '',
              participants: [
                for (final thread
                    in membership.threadsByStoryline[storyline.id] ?? const [])
                  ...displays[thread] ?? const <String>[],
              ],
            ),
        ]);

        // Summed per task name across both collectors, never a map literal
        // over the two lists: a label seen on BOTH slots would otherwise keep
        // whichever collector came last and silently drop the other's calls.
        // The confirm and the naming task carry different labels today, and
        // the sum is what keeps that from being load-bearing.
        final callsByKind = <String, int>{};
        for (final metrics in [
          ...confirmCollector.tasks,
          ...nameCollector.tasks,
        ]) {
          callsByKind[metrics.task] =
              (callsByKind[metrics.task] ?? 0) + metrics.n + metrics.failures;
        }

        // The five per-pass counts, summed off the sweep's own activity rows.
        // Read after the loop rather than per pass, so a pass the log
        // suppressed as quiet simply contributes nothing.
        var sweptIncoherent = 0;
        var sweptLint = 0;
        var sweptOutliers = 0;
        var sweptSeries = 0;
        var sweptSeriesExcluded = 0;
        var sweptFragments = 0;
        var sweptFolded = 0;
        // The four the model-read grouping writes, zero on a tree running
        // `GroupingMode.cosine` — which is the point of reading them in both
        // modes rather than only in the one that moves them.
        var sweptGroupCalls = 0;
        var sweptGrouped = 0;
        var sweptGroupFailed = 0;
        var sweptGroupUnfit = 0;
        for (final row in await store.recentActivity(limit: 1000)) {
          if (row['kind'] != 'storyline_sweep') continue;
          final detail = ActivityEvent.fromRow(row).detail;
          int at(String key) => (detail[key] as num?)?.toInt() ?? 0;
          // The bench store has no queue behind it, so the settle gate can
          // never bite here. If it ever did, every count below would be a
          // measurement of a pass that never ran, and the row would read as a
          // score rather than as the empty thing it was.
          if (detail['deferred'] is String) {
            fail('the sweep deferred on the bench store: '
                'extract ${at('extract')}, embed ${at('embed')}, '
                'triage ${at('triage')}');
          }
          sweptIncoherent += at('incoherent');
          sweptLint += at('lint');
          sweptOutliers += at('outliers');
          sweptSeries += at('series');
          sweptSeriesExcluded += at('series_excluded');
          sweptFragments += at('fragments');
          sweptFolded += at('folded');
          sweptGroupCalls += at('grouping_calls');
          sweptGrouped += at('grouped');
          sweptGroupFailed += at('grouping_failed');
          sweptGroupUnfit += at('grouping_unfit');
        }

        final tally = SweepTally(
          formed: membership.storylines,
          tombstoned: tombstoned,
          lintRejected: sweptLint,
          incoherent: sweptIncoherent,
          seriesSeeded: sweptSeries,
          seriesExcluded: sweptSeriesExcluded,
          outliersDropped: sweptOutliers,
          fragmentsJoined: sweptFragments,
          fragmentsFolded: sweptFolded,
          groupingCalls: sweptGroupCalls,
          grouped: sweptGrouped,
          groupingFailed: sweptGroupFailed,
          groupingUnfit: sweptGroupUnfit,
          purityByStoryline: {
            for (final entry in membership.threadsByStoryline.entries)
              entry.key: purityOf(entry.value, goldByThread),
          },
          coverageBySlug: coverageBySlugOf(
            set: set,
            membership: membership,
            slugByStoryline: mapping,
            goldByThread: goldByThread,
          ),
          largestShare: membership.largestShare,
          correctPositives: correctPositives,
          forbiddenByAnti: forbiddenHits,
          unmapped: unmapped,
          filedNowhere: filedNowhere,
          callsByKind: callsByKind,
          callsPerPass: callsPerPass,
          wallPerPassMs: wallPerPassMs,
          cosineBins: cosineBins(withinCluster),
          // The same pairs on the scale the shipped gates sit at. Counted
          // twice rather than rescaled, so a Round D row and a Round F row
          // still read against each other.
          cosineBinsQwen:
              cosineBins(withinCluster, edges: cosineBinEdgesQwen),
          lintCounts: lintCounts,
          clusterPurity: clusterPurity,
          sameEffortBins: cosineBins(pairs.sameEffort),
          crossEffortBins: cosineBins(pairs.crossEffort),
          withNoneBins: cosineBins(pairs.withNone),
          sameEffortBinsQwen:
              cosineBins(pairs.sameEffort, edges: cosineBinEdgesQwen),
          crossEffortBinsQwen:
              cosineBins(pairs.crossEffort, edges: cosineBinEdgesQwen),
          withNoneBinsQwen:
              cosineBins(pairs.withNone, edges: cosineBinEdgesQwen),
          sameSubjectBins: overlapBins(subjectOverlap.sameEffort),
          crossSubjectBins: overlapBins(subjectOverlap.crossEffort),
          withNoneSubjectBins: overlapBins(subjectOverlap.withNone),
          samePeopleBins: sharedPeopleBins(sharedPeople.sameEffort),
          crossPeopleBins: sharedPeopleBins(sharedPeople.crossEffort),
          withNonePeopleBins: sharedPeopleBins(sharedPeople.withNone),
          separation: separation,
        );

        final wall = DateTime.now().difference(startedAt);
        final runPath = BenchTarget.outDir.isEmpty
            ? null
            : await writeGoldenRun(
                entries,
                bench: 'golden-sweep',
                // Both slots in the label: a sweep row is a pair of models,
                // the confirms on one and the names on the other, and a row
                // naming one of them could not be read a week later.
                label: '${BenchTarget.bulk.label} + ${BenchTarget.prose.label} '
                    'sweep',
                outDir: BenchTarget.outDir,
              );
        final timingPath = await _sweepBench.writeResult(
          collectors: [confirmCollector, nameCollector],
          startedAt: startedAt,
          extra: {
            'run_file': runPath,
            'cards_from': GoldenDefines.runPath,
            'card': variant.wireName,
            'prefix_length': report.prefixLength,
            'sweep': tally.toJson(),
            'seed': report.toJson(),
            'assign_outcomes': assignOutcomes,
            'passes': passes,
            'kept_suggestions': keptSuggestions,
            'wall_ms': wall.inMilliseconds,
            // The calls MADE, divided by the wall they were made in — the
            // failures included, because a failed call spent the time too.
            'calls_per_min': msgsPerMinute(
              _callsMade(confirmCollector) + _callsMade(nameCollector),
              wall,
            ),
            'registry': {
              'path': GoldenDefines.registryPath,
              'storylines': registry.storylines.length,
              'anti': registry.antiSlugs.length,
            },
            'golden': {
              'path': GoldenDefines.setPath,
              'generated': set.generated,
              'items': set.items.length,
            },
          },
        );

        // ignore: avoid_print
        print(
          '\n${confirmCollector.banner}\n${confirmCollector.table()}\n'
          '\n${nameCollector.banner}\n${nameCollector.table()}\n'
          '\n${tally.table()}\n'
          '\n  passes $passes, suggestions kept $keptSuggestions, '
          'assign ${[
            for (final entry in assignOutcomes.entries)
              '${entry.key} ${entry.value}'
          ].join('  ')}\n'
          '  ${set.items.length} items in ${wall.inSeconds}s\n',
        );
        _sweepBench.printPaths(runPath: runPath, resultPath: timingPath);

        // Shape, never quality. Every judgement in this run belongs to the
        // scorer: what is asserted here is that the replay had a mailbox to
        // sweep and that something answered.
        expect(entries, hasLength(set.items.length));
        expect(
          report.keptThreads,
          greaterThan(0),
          reason: 'no thread survived the gates — nothing to sweep',
        );
        expect(
          confirmCollector.tasks.any((m) => m.n > 0) ||
              nameCollector.tasks.any((m) => m.n > 0),
          isTrue,
          reason: 'no call succeeded — are both servers up?',
        );
        _assertNoLeaks(confirmCollector);
        _assertNoLeaks(nameCollector);
      } finally {
        await db.close();
      }
    },
    // A sweep pass is a naming call on the prose slot plus a confirm per
    // member on the bulk slot, and the loop runs until nothing is proposed.
    timeout: const Timeout(Duration(minutes: 90)),
  );

  /// `GOLDEN_RUN=<bulk run file>` is optional and adds one column: triage's
  /// own `category` per item, so the standing question "would the model's
  /// `notification` verdict make a gate" can be re-read after a prompt change.
  /// It is printed and recorded, never applied.
  test(
    'the golden set through the gates',
    () async {
      final set = await _loadOrFail();

      // Optional on purpose: the verdicts below do not depend on it, so a run
      // without a bulk run file to hand is a run with one column fewer rather
      // than a failure.
      final categories = GoldenDefines.runPath.isEmpty
          ? const <String, String>{}
          : await loadGoldenTriageCategories(GoldenDefines.runPath);

      final entries = <GoldenRunEntry>[];
      final replayed = <(GoldenItem, GoldenGateOut)>[];
      final lines = <String>[];
      for (final item in set.items) {
        final out = gateReplay(
          item,
          ownerAddress: GoldenDefines.ownerAddress,
          modelCategory: categories[item.id],
        );
        entries.add(
          GoldenRunEntry(
            id: item.id,
            stratum: item.stratum,
            difficulty: item.difficulty,
          )..gate = out,
        );
        replayed.add((item, out));
        // A gold KEEP's reason is prose an annotator wrote, so only a drop's
        // — which is a slug from the taxonomy — is printed. Ids and enums,
        // like every other line in this file.
        final goldReason =
            item.gold.gateVerdict == 'drop' ? _goldGateReason(item) : null;
        lines.add(
          '${item.id}  '
          '${out.verdict}${out.reason == null ? '' : '/${out.reason}'}  '
          'gold ${item.gold.gateVerdict}'
          '${goldReason == null ? '' : '/$goldReason'}'
          '${out.modelCategory == null ? '' : '  model ${out.modelCategory}'}',
        );
      }

      // Every denominator comes off the set that was loaded. A literal here
      // would be a number about the set somebody had in September, quietly
      // surviving the next repack.
      final total = set.items.length;
      var agree = 0;
      var goldDrops = 0;
      var dropsCaught = 0;
      var goldKeeps = 0;
      var keepsKept = 0;
      var trapItems = 0;
      var trapMisses = 0;
      final perStratum = <String, int>{};
      final agreePerStratum = <String, int>{};
      final dropReasons = <String, int>{};
      for (final (item, out) in replayed) {
        final gold = item.gold.gateVerdict;
        final agreed = out.verdict == gold;
        if (agreed) agree++;
        if (gold == 'drop') {
          goldDrops++;
          if (out.verdict == 'drop') dropsCaught++;
        }
        if (gold == 'keep') {
          goldKeeps++;
          if (out.verdict == 'keep') keepsKept++;
        }
        if (item.stratum == _trapStratum) {
          trapItems++;
          if (out.verdict == 'drop') trapMisses++;
        }
        perStratum[item.stratum] = (perStratum[item.stratum] ?? 0) + 1;
        if (agreed) {
          agreePerStratum[item.stratum] =
              (agreePerStratum[item.stratum] ?? 0) + 1;
        }
        if (out.verdict == 'drop') {
          final reason = out.reason ?? 'unnamed';
          dropReasons[reason] = (dropReasons[reason] ?? 0) + 1;
        }
      }

      final strataTable = [
        for (final stratum in perStratum.keys.toList()..sort())
          '  $stratum  ${agreePerStratum[stratum] ?? 0}/${perStratum[stratum]}',
      ];
      final reasonLine = dropReasons.isEmpty
          ? 'drop reasons: none — the replay gated nothing'
          : 'drop reasons: ${[
              for (final reason in dropReasons.keys.toList()..sort())
                '$reason ${dropReasons[reason]}',
            ].join(' · ')}';

      final String proxyLine;
      if (categories.isEmpty) {
        proxyLine = 'model proxy: not read (pass GOLDEN_RUN=<bulk run file> '
            'for the notification column)';
      } else {
        var onDrops = 0;
        var onKeeps = 0;
        var onTrap = 0;
        var missing = 0;
        for (final (item, out) in replayed) {
          final category = out.modelCategory;
          if (category == null) {
            missing++;
            continue;
          }
          if (category != _notificationCategory) continue;
          if (item.gold.gateVerdict == 'drop') onDrops++;
          if (item.gold.gateVerdict == 'keep') onKeeps++;
          if (item.stratum == _trapStratum) onTrap++;
        }
        proxyLine = 'model proxy (notification, from GOLDEN_RUN): '
            'on drops $onDrops/$goldDrops · on keeps $onKeeps/$goldKeeps · '
            'on trap $onTrap/$trapItems · no category for $missing items';
      }

      // ignore: avoid_print
      print(
        '\n${lines.join('\n')}\n'
        '\ngates: verdict $agree/$total · drops caught $dropsCaught/$goldDrops'
        ' · keeps kept $keepsKept/$goldKeeps'
        ' · trap misses $trapMisses/$trapItems\n'
        'unmeasured: tier 2 (mail headers are not in the set), teams ingest '
        'gates (bot, self — decided from Graph fields the set does not carry)'
        '\n\n${strataTable.join('\n')}\n'
        '\n$reasonLine\n'
        '$proxyLine\n',
      );

      // A run file and no timing JSON: nothing here is timed, and a timing
      // row of zeros beside the real ones would be a row a reader compares.
      // No `extra` is what says so.
      final paths = await _gatesBench.writeRun(
        entries: [
          for (final entry in entries)
            if (entry.attempted) entry,
        ],
        label: 'app-gates',
        // Read only by a result file, and this bench writes none: a hundred
        // pure functions have no wall worth reporting.
        startedAt: DateTime.now(),
      );
      _gatesBench.printPaths(runPath: paths.runPath);

      // Shape, never accuracy — the same rule as every other bench in this
      // repo. Whether the gates agree with gold is the scorer's question and
      // the ledger's, not this file's.
      expect(entries, hasLength(set.items.length));
      for (final entry in entries) {
        final out = entry.gate!;
        expect(out.verdict, anyOf('keep', 'drop'));
        if (out.verdict == 'drop') {
          expect(out.reason, isNotNull);
          expect(out.reason, isNotEmpty);
        } else {
          expect(out.reason, isNull);
        }
      }
    },
    // A hundred pure function calls. The two minutes are for loading the set.
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// The stratum drawn to be gated wrongly — machine-shaped mail a person
/// actually wrote. A drop here is the expensive kind of mistake, so the run
/// counts it on its own line rather than letting it average out.
const String _trapStratum = 'gate-keep-trap';

/// Triage's category the proxy column asks about. Named once: the question is
/// "would this verdict have made a gate", and a typo would answer "no".
const String _notificationCategory = 'notification';

/// The gold drop reason for [item], or null when gold names none.
///
/// Read off the raw gold block rather than through a field on [GoldenGold]:
/// the reason is scored by Python on drops alone, and this is the one line in
/// this file that wants it.
String? _goldGateReason(GoldenItem item) {
  final gate = item.gold.raw['gate'];
  if (gate is! Map) return null;
  final reason = gate['reason'];
  return reason is String ? reason : null;
}

/// The set all four halves run on, or a failure that says what to run.
///
/// A missing `GOLDEN_SET` is the one failure worth catching before anything
/// else happens: `loadGoldenSet('')` would report that no file exists at the
/// empty path, which is true and tells nobody what to do about it.
///
/// `GOLDEN_CTX` is NOT read here, on `GOLDEN_EXTRACT_CTX`'s rule: the triage
/// half is the only one of the four that runs a context rung at all. The prose
/// half's context is fixed, the storyline half's cards come out of
/// `GOLDEN_RUN`, and the gate replay reads no message body — so a header line
/// saying `ctx tail3` above any of those three was describing a knob the run
/// never touched, and a typo in it failed a run that would not have used it.
Future<GoldenSet> _loadOrFail() async {
  if (GoldenDefines.setPath.isEmpty) {
    fail('GOLDEN_SET is not defined — run via make golden / make golden-prose '
        '/ make golden-storyline / make golden-gate (the Makefile passes it); '
        'a bare flutter test cannot find the set');
  }
  final set = await loadGoldenSet(GoldenDefines.setPath);
  if (set.items.isEmpty) {
    fail('the golden set at ${GoldenDefines.setPath} holds no items — '
        'nothing to replay');
  }
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
    'k $k',
  );
  return set;
}

/// One bench per test, named for the result and run files it writes.
///
/// The names are the ones every existing file in `BENCH_OUT` already carries,
/// and they are what `bench_compare` and the ledger read a row by, so none of
/// them moved when the four tests came onto [LiveBench] in Round F. The sweep
/// keeps two, because its two STAGES share one body and one seeding and write
/// under a name each.
const LiveBench _triageBench = LiveBench('golden-bulk');
const LiveBench _proseBench = LiveBench('golden-prose');
const LiveBench _storylineBench = LiveBench('golden-storyline');
const LiveBench _gatesBench = LiveBench('golden-gate');
const LiveBench _sweepBench = LiveBench('golden-sweep');
const LiveBench _vectorBench = LiveBench('golden-vector');

/// [load], with a decode failure rethrown as a sentence naming the FILE.
///
/// `jsonDecode`'s own `FormatException` says "Unexpected character at 41231"
/// and nothing about which of the three machine-local files it was reading,
/// which is the difference between a two-minute fix and an afternoon. Reading
/// a file does not depend on which bench is asking, so the sweep's instance
/// answers for all of them. The set and the registry name themselves from
/// inside their own loaders as well, which is what covers the four tests that
/// reach those two through `_loadOrFail`.
Future<T> _decoded<T>(String path, Future<T> Function() load) =>
    _sweepBench.decodeOrFail(path, load);

/// Every storyline row the sweep has written, live and tombstoned alike.
///
/// The loop's progress test, and it counts dismissals on purpose: a pass whose
/// clusters were all thrown out still did work, and the next pass may propose
/// what it could not reach for. What ends the loop is a pass that writes
/// nothing at all.
Future<int> _storylineCount(MessageStore store) async => (await store
        .loadStorylines(statuses: const ['suggested', 'active', 'dismissed']))
    .length;

/// Calls this collector saw, failures included — what a per-pass count and a
/// calls-per-minute figure are both divided by. A failed call spent the wall
/// too, and a rate over successes alone would flatter a server that refused
/// half of them.
int _callsMade(CallCollector collector) => collector.tasks
    .fold(0, (sum, metrics) => sum + metrics.n + metrics.failures);

/// The owner, as the shared-people rule has to know them: their own name is on
/// every thread in their own mailbox, so counting it would put every pair in
/// one bucket.
Set<String> _ownerDisplays() => {
      if (GoldenDefines.ownerName != null) GoldenDefines.ownerName!,
    };

/// The clustering vector, read on its own — `make golden-vector`.
///
/// Everything here is arithmetic over the vectors the seeding just wrote, so
/// no chat model is dialled, nothing is named or confirmed, no run file is
/// produced and there is nothing to score: this is a READ of a geometry, not a
/// measurement of the app. It answers the one question a sweep cannot answer
/// in under an hour — whether the pairs that belong together sit above the
/// pairs that do not — and the three lines beside it say what a cheaper rule
/// would have managed on the same pool.
///
/// The clusters it prints are the ones the clustering WOULD form: the app's
/// own `clusterBySimilarity` over the pool `sweep()` reads, in the store's
/// order, with the fragments folded first exactly as `sweep()` folds them.
///
/// The SERIES pre-pass is COUNTED and not APPLIED, and the difference is the
/// point of printing it. `StorylineService.seriesOf` is read over the same
/// pool rows the would-form clusters are built from, so `series` and
/// `series_excluded` say how many rows the sweep would have taken out of the
/// cosine pool before it clustered anything — which is exactly how far these
/// clusters can differ from the ones a sweep would form. Both read zero on the
/// golden pool, which has never held a series: Round D measured `series 0 /
/// excluded 0` on every sweep row it ever took, and a pool where that stopped
/// being true now says so here rather than only in an hour-long sweep.
/// `folded`, the other pre-pass, is applied as well as counted.
///
/// Counts, ratios and enums, like every other line this file prints.
Future<void> _readTheVectorAlone({
  required MessageStore store,
  required GoldenSet set,
  required SeedReport report,
  required ClusteringCardVariant variant,
  required DateTime startedAt,
}) async {
  // The pool exactly as `StorylineService.sweep` builds it: the tag every
  // clustering read filters on, both connectors, a key and a vector required,
  // finished threads diverted. Nothing is `taken` on a store this bench just
  // seeded, so that filter has no work to do here.
  final poolRows = <Map<String, Object?>>[];
  final poolKeys = <String>[];
  final poolVectors = <List<double>>[];
  for (final row in await store.conversationsWithEmbeddings(
    embedModel: EmbeddingsClient.modelTag,
    sources: const ['email', 'teams'],
  )) {
    final key = row['conversation_key'] as String? ?? '';
    if (key.isEmpty) continue;
    if ((row['state'] as String?) == 'done') continue;
    final blob = row['embedding'];
    if (blob is! Uint8List) continue;
    final vector = decodeEmbedding(blob);
    if (vector.isEmpty) continue;
    poolRows.add(row);
    poolKeys.add(threadKeyOf(row['source'] as String? ?? 'email', key));
    poolVectors.add(vector);
  }
  if (poolRows.isEmpty) {
    fail('the seeded pool holds no vector under ${EmbeddingsClient.modelTag} — '
        'nothing to read');
  }

  final goldByThread = goldSlugByThread(set);

  final vectors = <String, List<double>>{
    for (var i = 0; i < poolKeys.length; i++) poolKeys[i]: poolVectors[i],
  };
  final subjects = <String, String>{
    for (var i = 0; i < poolKeys.length; i++)
      poolKeys[i]: poolRows[i]['subject'] as String? ?? '',
  };
  final people = <String, List<String>>{
    for (var i = 0; i < poolKeys.length; i++)
      poolKeys[i]: _displaysOfJson(poolRows[i]['participants_json']),
  };

  final pairs = pairCosinesOf(vectors: vectors, goldByThread: goldByThread);
  final subjectOverlap = pairSubjectOverlapOf(
    subjectByThread: subjects,
    goldByThread: goldByThread,
  );
  final sharedPeople = pairSharedPeopleOf(
    participantsByThread: people,
    goldByThread: goldByThread,
    ownerDisplays: _ownerDisplays(),
  );
  final separation = separationOf(
    sameEffort: pairs.sameEffort,
    crossEffort: pairs.crossEffort,
  );

  // The would-form ladder: the same clustering at three link cosines, because
  // the cosine SCALE moves with the model and the prefix. Measured 2026-09-19
  // over twenty candidate passes, recall-70 ran from 0.31 to 0.72, so a rung
  // at the shipped 0.65 says how a candidate would behave under the app's
  // current numbers and NOT whether its geometry is better. The two derived
  // rungs are the scale-free reading: the same rule set where this model's own
  // recall and precision points fall.
  //
  // The fold is threshold-independent, so all three rungs report the same
  // representative count and the same folded count.
  final rungs = <({String label, double threshold})>[
    (label: 'shipped', threshold: StorylineTuning.clusterLinkThreshold),
    (label: 'recall-70', threshold: separation.recall70Cosine),
    (label: 'cross-5', threshold: separation.cross5Cosine),
  ];
  final ladder = <
      ({
        String label,
        double threshold,
        ClusterPurity purity,
        ({int same, int cross, int none}) inside,
        int representatives,
        int folded,
      })>[];
  for (final rung in rungs) {
    // Pure, and pinned offline by `golden_sweep_test`: the fragment fold first
    // and the representatives clustered, exactly as `sweep()` does it.
    final formed = wouldFormClustersOf(
      rows: poolRows,
      vectors: poolVectors,
      keys: poolKeys,
      threshold: rung.threshold,
    );
    ladder.add((
      label: rung.label,
      threshold: rung.threshold,
      purity: ClusterPurity.of(formed.clusters, goldByThread),
      inside: pairsInsideClusters(formed.clusters, goldByThread),
      representatives: formed.representatives,
      folded: formed.folded,
    ));
  }

  // Counted over the SAME rows the ladder clustered, which is what makes the
  // two numbers readable against each other: a sweep would have taken these
  // rows out of the cosine pool first, and this stage did not.
  final series = StorylineService.seriesOf(poolRows);
  final seriesSeeded = series.seeded.length;
  final seriesExcluded = series.excluded.length;

  // `local` or `remote` and never the URL: the host is the one part of a
  // bench's configuration that could carry somebody's machine name.
  final host = Uri.tryParse(EmbeddingsClient.defaultBaseUrl)?.host ?? '';
  final embedHost =
      host == 'localhost' || host == '127.0.0.1' ? 'local' : 'remote';

  // ignore: avoid_print
  print(
    'vector:\n'
    '  stage vector · card ${variant.wireName} · '
    'prefix length ${report.prefixLength} · dims ${report.dims} · '
    'embed $embedHost\n'
    '  pool ${poolRows.length} threads '
    '(${ladder.first.representatives} representatives, '
    'folded ${ladder.first.folded}, '
    'series $seriesSeeded  series_excluded $seriesExcluded), '
    '${poolRows.length * (poolRows.length - 1) ~/ 2} pairs\n'
    '${[
      for (final rung in ladder)
        wouldFormLine(
          label: rung.label,
          threshold: rung.threshold,
          purity: rung.purity,
          inside: rung.inside,
          sameTotal: pairs.sameEffort.length,
        ),
    ].join('\n')}\n'
    '  pool pairs by cosine (0.50..0.65)  same effort  '
    '${binsLine(cosineBinLabels, cosineBins(pairs.sameEffort))}'
    '   cross effort  '
    '${binsLine(cosineBinLabels, cosineBins(pairs.crossEffort))}'
    '   with none  '
    '${binsLine(cosineBinLabels, cosineBins(pairs.withNone))}\n'
    '  pool pairs by cosine (0.35..0.50)  same effort  '
    '${binsLine(cosineBinLabelsQwen, cosineBins(
      pairs.sameEffort,
      edges: cosineBinEdgesQwen,
    ))}'
    '   cross effort  '
    '${binsLine(cosineBinLabelsQwen, cosineBins(
      pairs.crossEffort,
      edges: cosineBinEdgesQwen,
    ))}'
    '   with none  '
    '${binsLine(cosineBinLabelsQwen, cosineBins(
      pairs.withNone,
      edges: cosineBinEdgesQwen,
    ))}\n'
    '${subjectOverlapLine(
      sameEffort: overlapBins(subjectOverlap.sameEffort),
      crossEffort: overlapBins(subjectOverlap.crossEffort),
      withNone: overlapBins(subjectOverlap.withNone),
    )}\n'
    '${sharedPeopleLine(
      sameEffort: sharedPeopleBins(sharedPeople.sameEffort),
      crossEffort: sharedPeopleBins(sharedPeople.crossEffort),
      withNone: sharedPeopleBins(sharedPeople.withNone),
    )}\n'
    '  ${separationLine(separation)}\n',
  );

  final resultPath = await _vectorBench.writeResult(
    label: 'embed $embedHost · ${variant.wireName} · '
        'prefix ${report.prefixLength}',
    startedAt: startedAt,
    extra: {
      // Basenames, not paths: the result JSON already redacts the embed host,
      // and a home directory in it would undo that.
      'cards_from': GoldenDefines.runPath.split('/').last,
      'vector': {
        'card': variant.wireName,
        'prefix_length': report.prefixLength,
        'embed_host': embedHost,
        'dims': report.dims,
        'pool_threads': poolRows.length,
        'representatives': ladder.first.representatives,
        'folded': ladder.first.folded,
        // Counted, never applied: see this stage's doc. The sweep's own tally
        // writes the same two keys, so a vector row and a sweep row on one
        // pool are read side by side.
        'series': seriesSeeded,
        'series_excluded': seriesExcluded,
        'would_form': {
          for (final rung in ladder)
            // `recall-70` → `recall_70`: a JSON key a reader greps for.
            rung.label.replaceAll('-', '_'): wouldFormJson(
              threshold: rung.threshold,
              purity: rung.purity,
              inside: rung.inside,
            ),
        },
        'pairs': {
          'same_bins': labelledBins(cosineBinLabels, cosineBins(pairs.sameEffort)),
          'cross_bins':
              labelledBins(cosineBinLabels, cosineBins(pairs.crossEffort)),
          'none_bins': labelledBins(cosineBinLabels, cosineBins(pairs.withNone)),
          // The same three on the shipped gates' scale, under their own keys:
          // a row written before Round F carries only the first three, and one
          // key cannot mean two scales.
          'same_bins_qwen': labelledBins(
            cosineBinLabelsQwen,
            cosineBins(pairs.sameEffort, edges: cosineBinEdgesQwen),
          ),
          'cross_bins_qwen': labelledBins(
            cosineBinLabelsQwen,
            cosineBins(pairs.crossEffort, edges: cosineBinEdgesQwen),
          ),
          'none_bins_qwen': labelledBins(
            cosineBinLabelsQwen,
            cosineBins(pairs.withNone, edges: cosineBinEdgesQwen),
          ),
        },
        'subject_overlap': {
          'same_bins':
              labelledBins(overlapBinLabels, overlapBins(subjectOverlap.sameEffort)),
          'cross_bins': labelledBins(
              overlapBinLabels, overlapBins(subjectOverlap.crossEffort)),
          'none_bins':
              labelledBins(overlapBinLabels, overlapBins(subjectOverlap.withNone)),
        },
        'shared_people': {
          'same_bins': labelledBins(
              sharedPeopleBinLabels, sharedPeopleBins(sharedPeople.sameEffort)),
          'cross_bins': labelledBins(
              sharedPeopleBinLabels, sharedPeopleBins(sharedPeople.crossEffort)),
          'none_bins': labelledBins(
              sharedPeopleBinLabels, sharedPeopleBins(sharedPeople.withNone)),
        },
        'separation': separationJson(separation),
        'seed': report.toJson(),
      },
      'golden': {
        'path': GoldenDefines.setPath.split('/').last,
        'generated': set.generated,
        'items': set.items.length,
      },
    },
  );
  _vectorBench.printPaths(resultPath: resultPath);
}

/// The display names on a stored `participants_json`, the way every card
/// builder reads one: a blank display is not a person.
List<String> _displaysOfJson(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  return [
    for (final entry in decoded)
      if (entry is Map && entry['name'] is String && (entry['name'] as String).isNotEmpty)
        entry['name'] as String,
  ];
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

String _ctxLine(
  GoldenCtx ctx,
  GoldenCtx extractCtx,
  int k,
  int items,
  Duration wall,
) {
  final head = 'ctx ${ctx.name}, extract ctx ${extractCtx.name}, k $k, '
      '$items items in ${wall.inSeconds}s, '
      '${msgsPerMinute(items, wall).toStringAsFixed(1)} msgs/min';
  return switch (ctx) {
    GoldenCtx.compressed => '$head\n$_compressedCaveat',
    GoldenCtx.digest => '$head\n$_digestCaveat',
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
