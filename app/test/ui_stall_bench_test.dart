/// How long this isolate is blocked while it drives the store, on both
/// executors, with the attention pass as the branch runs it beside the one
/// `main` ran.
///
/// The test's own isolate stands in for the UI isolate: a [UiStallMonitor]
/// heartbeat runs on it while each scenario drives the real [MessageStore]
/// over a seeded, fictional mailbox on a temp file. The `ui` arm opens the
/// database on this isolate (what `main` does), the `bg` arm on a background
/// isolate (what the branch does), through the same [appExecutor] the app
/// uses. A reload runs the branch's pass ([AttentionService.recompute] on the
/// rows the list just read) and, beside it, `main`'s (`recomputeAll` with a
/// transaction per score, then a second read of the list). An arrival is one
/// ingest transaction. The index backfill is the branch's diff beside the two
/// full scans `main` made. The decode is pure CPU and runs on this isolate
/// only.
///
/// It PRINTS a table and asserts only shape: every row ticked, the seed has
/// its threads, the pass wrote scores, the arrival grew the messages, the
/// index filled. It never asserts a time, because a timing that holds on one
/// machine fails for no defect on another.
///
/// It runs under `flutter test`: JIT, asserts on, so the Dart-side costs are
/// several times a release build's; SQLite's are not. Run it with `make
/// bench-ui` (sizes from `BENCH_UI_THREADS`, `BENCH_UI_RELOADS`,
/// `BENCH_UI_ARRIVAL`, a `BENCH_UI_LABEL`, and `BENCH_UI_OUT` for a JSON
/// copy), or by hand:
/// `flutter test --run-skipped test/ui_stall_bench_test.dart
/// --dart-define=BENCH_UI_THREADS=300`.
@Skip('a bench, run by `make bench-ui`: it measures, it never asserts a time')
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bond_inbox/data/conversation_vec_index.dart';
import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/extraction_models.dart';
import 'package:bond_inbox/models/message_models.dart'
    show Conversation, ConversationState;
import 'package:bond_inbox/providers/conversations_provider.dart'
    show sameConversationRows;
import 'package:bond_inbox/services/attention.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/perf/perf_log.dart';
// drift exports an `isNull` and an `isNotNull` of its own, which would shadow
// the matchers.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/triage_seed.dart';

const int _threads = int.fromEnvironment('BENCH_UI_THREADS', defaultValue: 2000);
const int _reloads = int.fromEnvironment('BENCH_UI_RELOADS', defaultValue: 10);
const int _arrival = int.fromEnvironment('BENCH_UI_ARRIVAL', defaultValue: 200);
const String _label =
    String.fromEnvironment('BENCH_UI_LABEL', defaultValue: 'local');
const String _outDir = String.fromEnvironment('BENCH_UI_OUT');

/// How many existing threads an arrival spreads its messages over.
const int _arrivalThreads = 50;

/// One measured (scenario, arm): the wall and what the heartbeat saw.
class _Row {
  _Row(this.scenario, this.arm, this.wallMs, this.s);

  final String scenario;
  final String arm;
  final int wallMs;
  final UiStallSummary s;

  Map<String, Object?> toJson() => {
        'scenario': scenario,
        'arm': arm,
        'wall_ms': wallMs,
        'janks': s.janks,
        'stalls': s.stalls,
        'worst_ms': s.maxMs,
        'blocked_ms': s.blockedMs,
        'ticks': s.ticks,
      };
}

void main() {
  late bool vec;
  late Directory tmp;
  final opened = <BondDatabase>[];

  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    vec = ensureSqliteVecLoaded();
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bond-ui-bench-');
  });

  Future<void> closeAll() async {
    while (opened.isNotEmpty) {
      await opened.removeLast().close();
    }
  }

  tearDown(() async {
    await closeAll();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('ui stall bench: reload, arrival and index', () async {
    final started = Stopwatch()..start();
    final template = p.join(tmp.path, 'template.db');

    // ── seeding ──────────────────────────────────────────────────────────
    final seedWatch = Stopwatch()..start();
    final seeded = BondDatabase.open(template);
    try {
      await _seed(MessageStore(seeded), seeded, vec: vec);
      final count = await seeded
          .customSelect('SELECT COUNT(*) AS n FROM conversations')
          .getSingle();
      expect(count.data['n'], _threads);
    } finally {
      await seeded.close();
    }
    seedWatch.stop();

    _say('');
    _say('ui stall bench · label $_label');
    _say('threads $_threads · reloads $_reloads · arrival $_arrival · '
        'vec ${vec ? 'available' : 'unavailable'}');
    _say('JIT under flutter test: Dart-side costs are several times a '
        'release build\'s');
    _say('seeded in ${seedWatch.elapsedMilliseconds} ms');

    final rows = <_Row>[];
    var sink = 0.0;

    Future<_Row> measure(
      String scenario,
      String arm,
      Future<void> Function() body,
    ) async {
      final monitor = UiStallMonitor(
        log: (_) {},
        summaryEvery: const Duration(hours: 1),
      );
      monitor.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      monitor.take();
      final watch = Stopwatch()..start();
      await body();
      watch.stop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final s = monitor.take();
      monitor.stop();
      return _Row(scenario, arm, watch.elapsedMilliseconds, s);
    }

    // A pause after each reload of a reload scenario. In the app two reloads
    // are never back to back (the next waits at least 400 ms for the reports
    // to go quiet), so without one the same-isolate arm would read the whole
    // run as ONE block and say nothing about a single reload. With it the
    // heartbeat sees each reload on its own: `worst` is one reload's freeze
    // and `janks` how many of them froze. The pause is in `wall`.
    Future<void> breathe() =>
        Future<void>.delayed(const Duration(milliseconds: 25));

    // Every scenario runs twice and keeps the second: the first warms the
    // caches, the house rule for every bench row.
    Future<void> twice(
      String scenario,
      String arm,
      Future<void> Function(int rep) body,
    ) async {
      await measure(scenario, arm, () => body(0));
      rows.add(await measure(scenario, arm, () => body(1)));
    }

    Future<int> messageCount(BondDatabase db) async => (await db
            .customSelect('SELECT COUNT(*) AS n FROM messages')
            .getSingle())
        .data['n'] as int;

    for (final arm in const ['ui', 'bg']) {
      final path = p.join(tmp.path, '$arm.db');
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File('$template$suffix');
        if (f.existsSync()) f.copySync('$path$suffix');
      }
      final db = BondDatabase(
        appExecutor(path, onUiIsolate: arm == 'ui', perfLog: false),
      );
      opened.add(db);
      try {
        final store = MessageStore(db);
        final attention = AttentionService(store);

        await db.customSelect('SELECT 1').get();
        await store.conversationRows(sources: ['email']);

        // 1. The branch's reload: one read, the pass on those rows.
        List<Map<String, Object?>>? shown;
        await twice('reload x$_reloads (branch)', arm, (_) async {
          for (var i = 0; i < _reloads; i++) {
            final raw = await store.conversationRows(sources: ['email']);
            final models = [for (final r in raw) Conversation.fromRow(r)];
            final pass = await attention.recompute(
              sources: ['email'],
              conversations: models,
            );
            // The rest of what the app's load does on this isolate: the rows
            // the pass moved are made into models again, and the read is
            // compared with the last one to decide whether the screen changes.
            final patched = pass.applyTo(raw);
            for (var j = 0; j < patched.length; j++) {
              if (!identical(patched[j], raw[j])) {
                models[j] = Conversation.fromRow(patched[j]);
              }
            }
            final last = shown;
            if (last != null) sameConversationRows(last, patched);
            shown = patched;
            await breathe();
          }
        });
        final scored = await db
            .customSelect('SELECT COUNT(*) AS n FROM conversation_ai '
                'WHERE attention_score IS NOT NULL')
            .getSingle();
        expect(scored.data['n'] as int, greaterThan(0));

        // 2. The reload as `main` ran it: its pass, then a second read.
        await twice('reload x$_reloads (as on main)', arm, (_) async {
          for (var i = 0; i < _reloads; i++) {
            await _legacyRecomputeAll(store, db);
            await store.loadConversations(sources: ['email']);
            await breathe();
          }
        });

        // 3. An arrival: one ingest transaction over existing threads.
        final before = await messageCount(db);
        await measure('arrival x$_arrival', arm,
            () => _arrive(store, db, rep: 0));
        final mid = await messageCount(db);
        rows.add(await measure('arrival x$_arrival', arm,
            () => _arrive(store, db, rep: 1)));
        final after = await messageCount(db);
        expect(mid - before, _arrival);
        expect(after - mid, _arrival);

        if (vec) {
          // 4. The branch's backfill over an unchanged corpus.
          final built = await store.prepareConversationIndex(
            embedModel: EmbeddingsClient.modelTag,
          );
          expect(built, isNotNull);
          expect(built!, greaterThan(0));
          await twice('index backfill x5, corpus unchanged (branch)', arm,
              (_) async {
            for (var i = 0; i < 5; i++) {
              await store.prepareConversationIndex(
                embedModel: EmbeddingsClient.modelTag,
              );
            }
          });

          // 5. The two full scans `main`'s backfill made every call.
          await twice('index backfill x5, corpus unchanged (as on main)', arm,
              (_) async {
            for (var i = 0; i < 5; i++) {
              await _legacyBackfillScans(db);
            }
          });

          // 6. The decode, pure CPU, so on this isolate only.
          if (arm == 'ui') {
            final blobs = [
              for (final r in await db
                  .customSelect('SELECT embedding FROM conversation_ai '
                      'WHERE embedding IS NOT NULL AND embed_model = ?1',
                      variables: [
                        Variable<String>(EmbeddingsClient.modelTag),
                      ])
                  .get())
                r.data['embedding'] as Uint8List,
            ];
            expect(blobs, hasLength(_threads));
            await twice('decode x$_threads vectors (branch)', 'n/a',
                (_) async {
              for (final b in blobs) {
                sink += decodeEmbedding(b)[0];
              }
            });
            await twice('decode x$_threads vectors (as on main)', 'n/a',
                (_) async {
              for (final b in blobs) {
                sink += _legacyDecode(b)[0];
              }
            });
          }
        }
      } finally {
        opened.remove(db);
        await db.close();
      }
    }

    for (final row in rows) {
      expect(row.s.ticks, greaterThan(0), reason: row.scenario);
      expect(row.wallMs, greaterThanOrEqualTo(0));
    }

    _say('');
    _say(_table(rows));
    _say('');
    _say('reading it: ui = SQLite on this isolate (what main does); '
        'bg = SQLite on a background isolate (what the branch does);');
    _say('a reload row: "worst" is ONE reload, and "wall" includes a 25 ms '
        'pause after each.');
    _say('n/a = pure CPU on this isolate; "blocked" sums every block of 33 ms '
        'or more, so 0 is no jank, not no work; a reading is up to 10 ms '
        'short.');
    _say('decode sink ${sink.toStringAsFixed(6)} · whole run '
        '${started.elapsedMilliseconds} ms');

    if (_outDir.isNotEmpty) {
      await Directory(_outDir).create(recursive: true);
      final safe = _label.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
      final file = File(p.join(_outDir, 'ui-stall-$safe.json'));
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'bench': 'ui-stall',
        'label': _label,
        'threads': _threads,
        'reloads': _reloads,
        'arrival': _arrival,
        'vec': vec,
        'seed_ms': seedWatch.elapsedMilliseconds,
        'rows': [for (final r in rows) r.toJson()],
      }));
      _say('wrote ${file.path}');
    }
  });
}

/// The one print: a bench's whole product is what it prints.
void _say(String line) {
  // ignore: avoid_print
  print(line);
}

String _table(List<_Row> rows) {
  const headers = [
    'scenario',
    'arm',
    'wall ms',
    'janks (>=33ms)',
    'stalls (>=100ms)',
    'worst ms',
    'blocked ms',
    'ticks',
  ];
  final cells = [
    for (final r in rows)
      [
        r.scenario,
        r.arm,
        '${r.wallMs}',
        '${r.s.janks}',
        '${r.s.stalls}',
        '${r.s.maxMs}',
        '${r.s.blockedMs}',
        '${r.s.ticks}',
      ],
  ];
  final widths = [
    for (var c = 0; c < headers.length; c++)
      [headers[c].length, for (final row in cells) row[c].length]
          .reduce(math.max),
  ];
  String line(List<String> values) => [
        for (var c = 0; c < values.length; c++)
          c < 2 ? values[c].padRight(widths[c]) : values[c].padLeft(widths[c]),
      ].join(' | ');
  return [
    line(headers),
    [for (final w in widths) '-' * w].join('-+-'),
    for (final row in cells) line(row),
  ].join('\n');
}

String _key(int i) => 't${i.toString().padLeft(4, '0')}';

/// The fictional mailbox: [_threads] email threads of three inbound messages
/// each, the newest triaged and extracted, about fifty senders with five
/// rules among them, and (with vec) a vector per thread. Chunks of 200
/// threads to a transaction, so the seed takes seconds.
Future<void> _seed(
  MessageStore store,
  BondDatabase db, {
  required bool vec,
}) async {
  final rng = math.Random(7);
  final now = DateTime.now();
  const intents = ['question', 'request', 'fyi'];
  for (var start = 1; start <= _threads; start += 200) {
    final end = math.min(start + 199, _threads);
    await db.transaction(() async {
      for (var i = start; i <= end; i++) {
        final key = _key(i);
        final roll = rng.nextDouble();
        final state = roll < 0.6
            ? 'needs_reply'
            : roll < 0.9
                ? 'waiting'
                : 'done';
        final newest = now.subtract(
          Duration(minutes: rng.nextInt(30 * 24 * 60)),
        );
        final from = 'person${i % 50}@example.com';
        final newestIso = MessageStore.isoStamp(newest);
        await store.upsertConversation({
          'source': 'email',
          'conversation_key': key,
          'subject': 'Thread $i',
          'state': state,
          'message_count': 3,
          'inbound_count': 3,
          'last_inbound_at': newestIso,
          'last_message_at': newestIso,
          'last_message_preview': 'Preview $i',
        });
        for (var m = 1; m <= 3; m++) {
          final at = newest.subtract(Duration(hours: (3 - m) * 5));
          await store.upsertMessage({
            'source': 'email',
            'source_message_id': '$key-m$m',
            'conversation_key': key,
            'direction': 'inbound',
            'subject': 'Thread $i',
            'from_address': from,
            'received_at': MessageStore.isoStamp(at),
            'body_preview': 'Preview $i',
          });
        }
        await writeTriaged(
          store,
          'email',
          '$key-m3',
          status: 'done',
          replyExpected: i.isEven,
        );
        await store.writeExtraction(
          'email',
          '$key-m3',
          jsonEncode({
            'intent': intents[i % 3],
            'importance': i % 3 == 0
                ? 'low'
                : i % 3 == 1
                    ? 'normal'
                    : 'high',
          }),
        );
        if (vec) {
          final v = List<double>.generate(
            ConversationVectorIndex.dims,
            (_) => rng.nextDouble() * 2 - 1,
          );
          final norm = math.sqrt(v.fold<double>(0, (a, x) => a + x * x));
          await store.upsertConversationAi(
            'email',
            key,
            embedding: encodeEmbedding([for (final x in v) x / norm]),
            embeddedHash: 'h$i',
            embedModel: EmbeddingsClient.modelTag,
          );
        }
      }
    });
  }
  for (var s = 0; s < 3; s++) {
    await store.setSenderPref('person$s@example.com', 'later');
  }
  for (var s = 3; s < 5; s++) {
    await store.setSenderPref('person$s@example.com', 'keep');
  }
}

/// One ingest page: [_arrival] new inbound messages over the first
/// [_arrivalThreads] threads, each checked, stored, and every fourth folded
/// into its thread — in ONE transaction, as the mail sync writes a page.
Future<void> _arrive(
  MessageStore store,
  BondDatabase db, {
  required int rep,
}) async {
  final base = DateTime.now();
  await db.transaction(() async {
    for (var j = 0; j < _arrival; j++) {
      final key = _key(j % _arrivalThreads + 1);
      final id = '$key-a$rep-$j';
      final at = MessageStore.isoStamp(base.add(Duration(milliseconds: j)));
      await store.hasMessage('email', id);
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Thread $j',
        'from_address': 'person${j % 50}@example.com',
        'received_at': at,
        'body_preview': 'Preview $j',
      });
      if (j % 4 == 0) {
        final row = await store.getConversationRow('email', key);
        if (row != null) {
          await store.upsertConversation({
            ...row,
            // Stamped now by the upsert, as the sync's fold is.
            'updated_at': null,
            'last_inbound_at': at,
            'last_message_at': at,
          });
        }
      }
    }
  });
}

/// The two scans `main`'s `ConversationVectorIndex.backfill` made on every
/// call (74fa93a): every vector of the tag, materialised, then every index
/// row; and its transaction, empty when the index is level. It leaves out
/// the maps `main` built from those rows on this isolate, so this row reads
/// a little cheaper than `main` was, which is the fair direction to err.
Future<void> _legacyBackfillScans(BondDatabase db) async {
  var bytes = 0;
  for (final row in await db
      .customSelect(
        'SELECT source, conversation_key, embedded_hash, embedding '
        'FROM conversation_ai '
        'WHERE embedding IS NOT NULL AND embed_model = ?1',
        variables: [Variable<String>(EmbeddingsClient.modelTag)],
      )
      .get()) {
    final blob = row.data['embedding'];
    if (blob is Uint8List) bytes += blob.lengthInBytes;
  }
  expect(bytes, greaterThan(0));
  await db
      .customSelect('SELECT rowid, source, conversation_key, embedded_hash '
          'FROM vec_conversations')
      .get();
  await db.transaction(() async {});
}

/// `main`'s `decodeEmbedding` (74fa93a): a growable list of boxed doubles.
List<double> _legacyDecode(Uint8List b) {
  final view = ByteData.sublistView(b);
  final count = b.lengthInBytes ~/ 4;
  return [
    for (var i = 0; i < count; i++) view.getFloat32(i * 4, Endian.little),
  ];
}

// ── `main`'s attention pass ─────────────────────────────────────────────
//
// `main`'s algorithm (74fa93a's `AttentionService.recomputeAll`), kept ONLY as
// this bench's baseline: its own list read, the same seven reads in the same
// order, the same per-thread loop and bucket decisions, and the two writes as
// `main` made them — one transaction per scored thread (its
// `writeAttentionScore`) and one per bucket decision
// (`setConversationBucket`, unchanged on the branch). Never used by the app.

Future<int> _legacyRecomputeAll(
  MessageStore store,
  BondDatabase db, {
  List<String> sources = const ['email'],
}) async {
  final at = DateTime.now();
  final conversations = await store.loadConversations(sources: sources);
  if (conversations.isEmpty) return 0;

  final meta = await store.latestInboundMeta(sources: sources);
  final prefs = await store.allSenderPrefs();
  final reasons = await store.bucketReasons(sources: sources);
  final threshold = await store.needsYouThreshold();
  final openAsks =
      await store.openAskThreads(sources: sources, threshold: threshold);
  final replyRates = {
    ...await store.senderReplyRates(),
    ...await store.senderReplyRates(source: 'teams'),
  };

  var scored = 0;
  for (final conversation in conversations) {
    final latest = meta[conversation.id];
    final address = (latest?['from_address'] as String? ?? '').toLowerCase();
    final senderPref = address.isEmpty ? null : prefs[address];
    final extraction = _extraction(latest?['extraction_json']);

    if (conversation.state != ConversationState.done) {
      await _legacyWriteAttentionScore(
        db,
        conversation.source,
        conversation.id,
        attentionScore(
          conversation: conversation,
          latestIntent: extraction?.intent,
          senderReplyRate: replyRates[address] ?? 0,
          senderPref: senderPref,
          latestReplyExpected: _tristate(latest?['reply_expected']),
          latestNeedsAction: _tristate(latest?['needs_action']),
          latestDeadline: latest?['deadline'] as String?,
          addressedMe: ((latest?['addressed_me'] as num?) ?? 0) != 0,
          needsYou: needsYouAt(
            (latest?['needs_you_p'] as num?)?.toDouble(),
            threshold,
          ),
          now: at,
        ),
      );
      scored++;
    }

    await _legacySweepBucket(
      store,
      conversation,
      senderPref: senderPref,
      extraction: extraction,
      reason: reasons[conversation.id],
      hasOpenAsk: openAsks.contains(
        MessageStore.openAskKey(conversation.source, conversation.id),
      ),
    );
  }
  return scored;
}

/// 74fa93a's `MessageStore.writeAttentionScore`: insert-then-update, one
/// transaction per thread.
Future<void> _legacyWriteAttentionScore(
  BondDatabase db,
  String source,
  String conversationKey,
  double score,
) async {
  final now = MessageStore.isoStamp(DateTime.now());
  await db.transaction(() async {
    await db.customUpdate(
      'INSERT INTO conversation_ai (source, conversation_key, updated_at) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(source, conversation_key) DO NOTHING',
      variables: [
        Variable<String>(source),
        Variable<String>(conversationKey),
        Variable<String>(now),
      ],
    );
    await db.customUpdate(
      'UPDATE conversation_ai SET attention_score = ?, updated_at = ? '
      'WHERE source = ? AND conversation_key = ?',
      variables: [
        Variable<double>(score),
        Variable<String>(now),
        Variable<String>(source),
        Variable<String>(conversationKey),
      ],
    );
  });
}

/// 74fa93a's `AttentionService._sweepBucket`, each decision written at once.
Future<void> _legacySweepBucket(
  MessageStore store,
  Conversation conversation, {
  required String? senderPref,
  required ExtractionResult? extraction,
  required String? reason,
  required bool hasOpenAsk,
}) async {
  Future<void> file(String? bucket, String? by) => store.setConversationBucket(
        conversation.source,
        conversation.id,
        bucket: bucket,
        reason: by,
      );

  if (reason == 'user') return;

  if (quietsSender(senderPref)) {
    await file('later', 'sender_pref');
    return;
  }
  if (senderPref == 'keep') {
    if (conversation.bucket != null) await file(null, null);
    return;
  }

  final bucket = extraction == null
      ? null
      : bucketFor(
          intent: extraction.intent,
          importance: extraction.importance,
          needsReply: conversation.state == ConversationState.needsReply,
          needsYou: hasOpenAsk,
        );

  if (bucket != null) {
    await file(bucket, 'low_value');
  } else if (reason == 'low_value') {
    await file(null, null);
  }
}

/// 74fa93a's `AttentionService._tristate`.
bool? _tristate(Object? raw) => raw is num ? raw != 0 : null;

/// 74fa93a's `AttentionService._extraction`.
ExtractionResult? _extraction(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    return ExtractionResult.fromJson(decoded);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}
