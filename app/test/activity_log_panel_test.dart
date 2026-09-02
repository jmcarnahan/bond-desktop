import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/widgets/activity_log_panel.dart';
import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panel that answers "is it quiet or is it broken?".
///
/// Most of what is pinned here is [ActivityLogPanel.describe], because that is
/// where the judgements live: which statuses read as failures, which read as
/// states, and which detail keys are worth the one line a row gets. The widget
/// tests cover only what the sentences cannot — that the numbers reach the
/// tiles, that the rows land under the right day and in the right columns, and
/// that a row's detail is reachable by tapping it.

ActivityEvent _event({
  int id = 1,
  String kind = 'triage',
  String status = 'ok',
  String? source,
  String? entityId,
  int? count,
  int? durationMs,
  Map<String, Object?> detail = const {},
  String? createdAt,
}) {
  return ActivityEvent(
    id: id,
    kind: kind,
    status: status,
    source: source,
    entityId: entityId,
    count: count,
    durationMs: durationMs,
    detail: detail,
    createdAt: createdAt ?? DateTime.now().toIso8601String(),
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    ActivityStats stats = const ActivityStats(),
    List<ActivityEvent> events = const [],
    DateTime? now,
    String? lastMailSyncIso,
    String? lastTeamsSyncIso,
    String? lastSweepIso,
    String? Function(ActivityEvent event)? entityLabel,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ActivityLogPanel(
          stats: stats,
          events: events,
          now: now ?? DateTime.now(),
          lastMailSyncIso: lastMailSyncIso,
          lastTeamsSyncIso: lastTeamsSyncIso,
          lastSweepIso: lastSweepIso,
          entityLabel: entityLabel,
        ),
      ),
    ));
  }

  group('the header numbers', () {
    testWidgets('every tile shows its own figure', (tester) async {
      await pump(
        tester,
        stats: const ActivityStats(
          ingestedBySource: {'email': 42, 'teams': 7},
          byKind: {
            'triage': {'ok': 30, 'error': 2},
          },
          avgMsByKind: {'triage': 940, 'extract': 12500},
          medianMsByKind: {'triage': 880},
          errorCount: 2,
          aiItemCount: 32,
        ),
      );

      expect(find.text('42'), findsOneWidget);
      expect(find.text('Mail messages'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('Teams messages'), findsOneWidget);
      expect(find.text('32'), findsOneWidget);
      expect(find.text('AI items'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('940ms'), findsOneWidget);
      expect(find.text('12.5s'), findsOneWidget);
    });

    testWidgets('a source that ingested nothing reads as zero, not blank',
        (tester) async {
      await pump(tester, stats: const ActivityStats());
      expect(find.text('0'), findsNWidgets(4));
    });

    testWidgets('a kind with no timings shows a dash', (tester) async {
      await pump(tester, stats: const ActivityStats());
      // Avg triage, Avg extract, Gen speed, Last sync, Last sweep. The Teams
      // tile is absent rather than dashed, which is what the test below pins.
      expect(find.text('—'), findsNWidgets(5));
    });

    testWidgets('generation speed is the whole window, not a row average',
        (tester) async {
      await pump(
        tester,
        events: [
          // 300 tokens over 20s together — 15/s — and not the 15/s a mean of
          // the two rows' own rates would coincidentally also give: those are
          // 10/s and 20/s, and the tile is neither of them.
          _event(detail: const {'completion_tokens': 100, 'llm_ms': 10000}),
          _event(detail: const {'completion_tokens': 200, 'llm_ms': 10000}),
        ],
      );

      expect(find.text('Gen speed'), findsOneWidget);
      expect(find.text('15 t/s'), findsOneWidget);
    });

    testWidgets('the last-run tiles read from the timestamps, not the rows',
        (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        lastMailSyncIso:
            now.subtract(const Duration(minutes: 4)).toIso8601String(),
        lastSweepIso: now.subtract(const Duration(hours: 2)).toIso8601String(),
      );

      // Wall-clock stamps, not relative ages: a relative "just now" freezes
      // at "just now" when syncs stop, which is the failure the tiles exist
      // to expose. An absolute time an hour later convicts itself.
      expect(find.text('Last sync'), findsOneWidget);
      expect(find.text('Mar 12, 8:56 AM'), findsOneWidget);
      expect(find.text('Last sweep'), findsOneWidget);
      expect(find.text('Mar 12, 7:00 AM'), findsOneWidget);
      // A connector that has never synced has no tile at all: a permanent dash
      // beside a live mail tile reads as broken rather than as absent.
      expect(find.text('Last teams sync'), findsNothing);
    });

    testWidgets('a Teams sync that has run gets its own tile', (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        lastTeamsSyncIso:
            now.subtract(const Duration(days: 1)).toIso8601String(),
      );

      expect(find.text('Last teams sync'), findsOneWidget);
      expect(find.text('Mar 11, 9:00 AM'), findsOneWidget);
    });
  });

  group('the table', () {
    testWidgets('nothing recorded says so, and names no columns',
        (tester) async {
      await pump(tester);
      expect(find.text('Nothing recorded yet.'), findsOneWidget);
      // A header over an empty table is a promise of rows that are not coming.
      expect(find.text('Activity'), findsNothing);
    });

    testWidgets('the columns are named once, above every day', (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'sync_mail',
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
          _event(
            kind: 'draft',
            createdAt: DateTime(2026, 3, 11, 17).toIso8601String(),
          ),
        ],
      );

      for (final column in ['Type', 'Activity', 't/s', 'When', 'Took']) {
        expect(find.text(column), findsOneWidget, reason: column);
      }
    });

    testWidgets('rows land under the day they happened', (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        events: [
          _event(
            kind: 'sync_mail',
            source: 'email',
            count: 4,
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
          _event(
            kind: 'draft',
            detail: const {'chars': 312},
            createdAt: DateTime(2026, 3, 11, 17).toIso8601String(),
          ),
        ],
      );

      // The labels come from formatDayLabel, which is relative to the real
      // clock — so the assertion is on the pair, not on the words "Today" and
      // "Yesterday", which only hold on the day this test is run.
      final earlier = formatDayLabel('2026-03-11')!.toUpperCase();
      final later = formatDayLabel('2026-03-12')!.toUpperCase();
      expect(earlier, isNot(later));
      expect(find.text(later), findsOneWidget);
      expect(find.text(earlier), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(later)).dy,
        lessThan(tester.getTopLeft(find.text(earlier)).dy),
      );

      // The sentence is the whole cell now: the kind is no longer split off
      // into a column of its own, because Type holds the connector instead.
      expect(find.text('Mail sync — 4 new'), findsOneWidget);
      expect(find.text('Draft written — 312 chars'), findsOneWidget);
    });

    testWidgets('a row names its connector, when, and how long it took',
        (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        events: [
          _event(
            kind: 'extract',
            source: 'email',
            durationMs: 94000,
            detail: const {'intent': 'request'},
            createdAt: now.subtract(const Duration(hours: 3)).toIso8601String(),
          ),
        ],
      );

      expect(find.text('Mail'), findsOneWidget);
      expect(find.text('Extract — request'), findsOneWidget);
      expect(find.text('3h ago'), findsOneWidget);
      expect(find.text('1m34s'), findsOneWidget);
    });

    testWidgets('a pass belonging to no connector is the app itself',
        (tester) async {
      await pump(tester, events: [_event(kind: 'storyline_sweep')]);
      expect(find.text('App'), findsOneWidget);
    });

    testWidgets('an AI row carries the rate the model generated at',
        (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'triage',
            detail: const {'completion_tokens': 60, 'llm_ms': 4000},
          ),
          _event(
            id: 2,
            kind: 'extract',
            detail: const {'completion_tokens': 200, 'llm_ms': 4000},
          ),
          // No tally, so nothing to report — the cell is empty rather than
          // zero, which would read as a model that produced nothing.
          _event(id: 3, kind: 'sync_mail', source: 'email', count: 3),
        ],
      );

      expect(find.text('15 t/s'), findsOneWidget);
      expect(find.text('50 t/s'), findsOneWidget);
      // Each row is its own rate; the tile is the window's, which is neither.
      expect(find.text('33 t/s'), findsOneWidget);
    });

    testWidgets('rows keep the order they were handed over', (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        events: [
          _event(
            kind: 'draft',
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
          _event(
            id: 2,
            kind: 'triage',
            createdAt: DateTime(2026, 3, 12, 8).toIso8601String(),
          ),
        ],
      );

      final draft = tester.getTopLeft(find.text('Draft written')).dy;
      final triage = tester.getTopLeft(find.text('Triage')).dy;
      expect(draft, lessThan(triage));
    });
  });

  group('the detail a row expands into', () {
    testWidgets('a tap opens the raw detail, and a second tap closes it',
        (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'extract',
            source: 'email',
            detail: const {
              'intent': 'request',
              'topics': ['launch date', 'homepage copy'],
            },
          ),
        ],
      );

      // Nothing in the row itself shows a key: the row is one elided sentence,
      // and the keys are what the tap is for.
      expect(find.text('intent: request'), findsNothing);

      await tester.tap(find.text('Extract — request · launch date, homepage copy'));
      await tester.pumpAndSettle();

      expect(find.text('intent: request'), findsOneWidget);
      // A list reads as its members, not as its Dart literal.
      expect(find.text('topics: launch date, homepage copy'), findsOneWidget);

      // The row's own copy of the sentence is the first one; the expansion
      // below it repeats it unelided.
      await tester
          .tap(find.text('Extract — request · launch date, homepage copy').first);
      await tester.pumpAndSettle();

      expect(find.text('intent: request'), findsNothing);
    });

    testWidgets('the expansion names what the row was about', (tester) async {
      await pump(
        tester,
        events: [_event(kind: 'triage', source: 'email', entityId: 'conv-1')],
        entityLabel: (event) =>
            event.entityId == 'conv-1' ? 'Launch date for Brightsea' : null,
      );

      await tester.tap(find.text('Triage'));
      await tester.pumpAndSettle();

      expect(find.text('Launch date for Brightsea'), findsOneWidget);
      // The raw id too, because it is what a person digging into a stuck item
      // has to be able to copy out.
      expect(find.text('conv-1'), findsOneWidget);
    });

    testWidgets('an entity nothing can name still expands', (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'triage',
            source: 'email',
            entityId: 'm1',
            detail: const {'urgency': 'high'},
          ),
        ],
        // A triage entity id is a message id, so a miss is the ordinary case.
        entityLabel: (event) => null,
      );

      await tester.tap(find.text('Triage — high'));
      await tester.pumpAndSettle();

      expect(find.text('urgency: high'), findsOneWidget);
      expect(find.text('m1'), findsOneWidget);
    });

    testWidgets('the model tally the row hid is spelled out in full',
        (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'triage',
            detail: const {
              'llm_calls': 1,
              'llm_ms': 4000,
              'completion_tokens': 60,
            },
          ),
        ],
      );

      await tester.tap(find.text('Triage'));
      await tester.pumpAndSettle();

      expect(find.text('llm_calls: 1'), findsOneWidget);
      expect(find.text('speed: 15 t/s'), findsOneWidget);
    });
  });

  group('describe', () {
    test('a mail sync reports what it brought in', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_mail', count: 4)),
        'Mail sync — 4 new',
      );
    });

    test('a sync that found nothing says so rather than showing a zero', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_mail', count: 0)),
        'Mail sync — nothing new',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_teams')),
        'Teams sync — nothing new',
      );
    });

    test('a Teams sync counts its own messages', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_teams', count: 2)),
        'Teams sync — 2 new',
      );
    });

    test('a failed sync carries the reason it failed', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'sync_mail',
          status: 'error',
          detail: const {'error': '401 Unauthorized', 'attempts': 3},
        )),
        'Mail sync failed — 401 Unauthorized',
      );
    });

    test('a failure with nothing to say still reads as a failure', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'triage', status: 'error')),
        'Triage failed',
      );
    });

    test('a missing Teams scope is not connected, not broken', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'sync_teams',
          status: 'skipped',
          detail: const {'reason': 'no_scope'},
        )),
        'Teams sync skipped — not connected',
      );
    });

    test('triage reports the two judgements it made', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          detail: const {
            'urgency': 'high',
            'category': 'work',
            'needs_action': true,
            'action_items': 2,
          },
        )),
        'Triage — high · work',
      );
    });

    test('triage with nothing recorded is still a triage', () {
      expect(ActivityLogPanel.describe(_event(kind: 'triage')), 'Triage');
    });

    test('extraction reports the intent and what it was about', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'extract',
          detail: const {
            'intent': 'request',
            'importance': 'high',
            'topics': ['launch date', 'homepage copy'],
          },
        )),
        'Extract — request · launch date, homepage copy',
      );
    });

    test('a deleted message reads as deleted, not as a skip nobody explained',
        () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'extract',
          status: 'skipped',
          detail: const {'reason': 'deleted'},
        )),
        'Extract skipped — message deleted',
      );
    });

    test('a gated message says why it was not worth a model call', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'extract',
          status: 'skipped',
          detail: const {'reason': 'gated'},
        )),
        'Extract skipped — nothing worth extracting',
      );
    });

    test('a draft reports its length', () {
      expect(
        ActivityLogPanel.describe(
          _event(kind: 'draft', detail: const {'chars': 312}),
        ),
        'Draft written — 312 chars',
      );
    });

    test('the two reasons a draft is skipped both read as English', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'draft',
          status: 'skipped',
          detail: const {'reason': 'already_drafted'},
        )),
        'Draft skipped — already drafted',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'draft',
          status: 'skipped',
          detail: const {'reason': 'no_reply_target'},
        )),
        'Draft skipped — nothing to reply to',
      );
    });

    test('a park names the state, and never the word failed', () {
      final parked = ActivityLogPanel.describe(_event(
        kind: 'triage',
        status: 'parked',
        detail: const {'reason': 'model_unavailable'},
      ));
      expect(parked, 'Triage parked — model server off');
      expect(parked, isNot(contains('fail')));

      expect(
        ActivityLogPanel.describe(_event(
          kind: 'draft',
          status: 'parked',
          detail: const {'reason': 'session'},
        )),
        'Draft parked — signed out',
      );
    });

    test('a park with no reason is still a park', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'extract', status: 'parked')),
        'Extract parked',
      );
    });

    test('a retry counts the attempt', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'extract',
          status: 'retry',
          detail: const {'attempts': 1, 'status_code': 503},
        )),
        'Extract retry (attempt 1)',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'extract', status: 'retry')),
        'Extract retry',
      );
    });

    test('an unmapped reason is opened up rather than dropped', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'skipped',
          detail: const {'reason': 'some_new_reason'},
        )),
        'Triage skipped — some new reason',
      );
    });

    test('a skip with no reason at all still says it skipped', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'triage', status: 'skipped')),
        'Triage skipped',
      );
    });

    test('an embedding failure reads as the optional server it is', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'embed_fail',
          status: 'error',
          detail: const {'reason': 'connection refused'},
        )),
        'Embeddings — connection refused',
      );
    });

    test('the storyline passes each have their own sentence', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'storyline')),
        'Storylines updated',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'storyline_sweep')),
        'Storyline sweep',
      );
    });

    test('a sweep says how many threads it confirmed and turned away', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'proposed': 1, 'confirmed': 2, 'rejected': 3},
        )),
        'Storyline sweep — 1 proposed, 2 threads confirmed, 3 rejected',
      );
      // A sweep that proposed nothing is the row worth reading, not one to
      // hide: the model was asked five times and said no five times.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'proposed': 0, 'confirmed': 0, 'rejected': 5},
        )),
        'Storyline sweep — 0 proposed, 0 threads confirmed, 5 rejected',
      );
      // A tombstoned cluster can leave exactly one confirmed thread behind.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'proposed': 0, 'confirmed': 1, 'rejected': 2},
        )),
        'Storyline sweep — 0 proposed, 1 thread confirmed, 2 rejected',
      );
    });

    test('a sweep row written before the confirm stage still reads', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'proposed': 2},
        )),
        'Storyline sweep — 2 proposed',
      );
    });

    test('a recruit says how many of its candidates it took', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_recruit',
          detail: const {'recruited': 1, 'considered': 5},
        )),
        'Recruited 1 of 5 candidate threads',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'storyline_recruit')),
        'Storyline recruit',
      );
    });

    test('model tallies stay out of the sentence', () {
      // They are on nearly every AI row; spending the one line on them would
      // bury the fact the row exists to report. The trailing duration is where
      // the time goes.
      final sentence = ActivityLogPanel.describe(_event(
        kind: 'triage',
        durationMs: 9400,
        detail: const {
          'urgency': 'high',
          'category': 'work',
          'llm_calls': 3,
          'llm_ms': 9100,
          'prompt_tokens': 2200,
          'completion_tokens': 180,
          'llm_label': 'triage',
        },
      ));
      expect(sentence, 'Triage — high · work');
    });

    test('an unknown kind renders as itself rather than as nothing', () {
      expect(ActivityLogPanel.describe(_event(kind: 'brand_new')), 'brand_new');
    });
  });

  group('speedOf', () {
    test('completion tokens over model time, in seconds', () {
      expect(
        ActivityLogPanel.speedOf(
          const {'completion_tokens': 60, 'llm_ms': 4000},
        ),
        15.0,
      );
    });

    test('a row with no model call has no rate to report', () {
      expect(ActivityLogPanel.speedOf(const {}), isNull);
      expect(ActivityLogPanel.speedOf(const {'llm_ms': 4000}), isNull);
      expect(ActivityLogPanel.speedOf(const {'completion_tokens': 60}), isNull);
    });

    test('a zero on either side is unanswerable, not infinitely fast', () {
      expect(
        ActivityLogPanel.speedOf(const {'completion_tokens': 60, 'llm_ms': 0}),
        isNull,
      );
      expect(
        ActivityLogPanel.speedOf(
          const {'completion_tokens': 0, 'llm_ms': 4000},
        ),
        isNull,
      );
    });

    test('a value that is not a number is not a number', () {
      expect(
        ActivityLogPanel.speedOf(
          const {'completion_tokens': '60', 'llm_ms': 4000},
        ),
        isNull,
      );
    });
  });

  group('formatSpeed', () {
    test('a decimal below ten, where it changes the reading; none above', () {
      expect(ActivityLogPanel.formatSpeed(5.5), '5.5 t/s');
      expect(ActivityLogPanel.formatSpeed(0.4), '0.4 t/s');
      expect(ActivityLogPanel.formatSpeed(9.94), '9.9 t/s');
      expect(ActivityLogPanel.formatSpeed(10), '10 t/s');
      expect(ActivityLogPanel.formatSpeed(12.4), '12 t/s');
      expect(ActivityLogPanel.formatSpeed(12.6), '13 t/s');
    });
  });

  group('formatDuration', () {
    test('milliseconds under a second, seconds under a minute, then minutes',
        () {
      expect(ActivityLogPanel.formatDuration(0), '0ms');
      expect(ActivityLogPanel.formatDuration(940), '940ms');
      expect(ActivityLogPanel.formatDuration(1000), '1.0s');
      expect(ActivityLogPanel.formatDuration(12500), '12.5s');
      expect(ActivityLogPanel.formatDuration(59900), '59.9s');
      expect(ActivityLogPanel.formatDuration(60000), '1m00s');
      expect(ActivityLogPanel.formatDuration(94000), '1m34s');
    });
  });
}
