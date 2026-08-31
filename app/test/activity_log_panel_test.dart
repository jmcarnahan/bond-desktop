import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/theme/tokens.dart';
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
/// tiles and that the rows land under the right day.

ActivityEvent _event({
  String kind = 'triage',
  String status = 'ok',
  String? source,
  int? count,
  int? durationMs,
  Map<String, Object?> detail = const {},
  String? createdAt,
}) {
  return ActivityEvent(
    id: 1,
    kind: kind,
    status: status,
    source: source,
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
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ActivityLogPanel(
          stats: stats,
          events: events,
          now: now ?? DateTime.now(),
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
      expect(find.text('—'), findsNWidgets(2));
    });
  });

  group('the event list', () {
    testWidgets('nothing recorded says so', (tester) async {
      await pump(tester);
      expect(find.text('Nothing recorded yet.'), findsOneWidget);
    });

    testWidgets('rows land under the day they happened', (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        events: [
          _event(
            kind: 'sync_mail',
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
      final headers = tester
          .widgetList<Text>(find.byType(Text))
          .where((text) => text.style == BondType.label)
          .map((text) => text.data)
          .whereType<String>()
          .toList();
      expect(headers.length, 2, reason: 'one header per day');
      expect(headers.first, isNot(headers.last));
      expect(headers.first, formatDayLabel('2026-03-12')!.toUpperCase());
      expect(headers.last, formatDayLabel('2026-03-11')!.toUpperCase());

      expect(find.text('Mail sync'), findsOneWidget);
      expect(find.text('4 new'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('written — 312 chars'), findsOneWidget);
    });

    testWidgets('a row carries how long ago it was and how long it took',
        (tester) async {
      final now = DateTime(2026, 3, 12, 9);
      await pump(
        tester,
        now: now,
        events: [
          _event(
            kind: 'extract',
            durationMs: 94000,
            detail: const {'intent': 'request'},
            createdAt: now.subtract(const Duration(hours: 3)).toIso8601String(),
          ),
        ],
      );

      expect(find.text('3h ago'), findsOneWidget);
      expect(find.text('1m34s'), findsOneWidget);
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
            kind: 'triage',
            createdAt: DateTime(2026, 3, 12, 8).toIso8601String(),
          ),
        ],
      );

      final draft = tester.getTopLeft(find.text('Draft')).dy;
      final triage = tester.getTopLeft(find.text('Triage')).dy;
      expect(draft, lessThan(triage));
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
            'category': 'borrower',
            'needs_action': true,
            'action_items': 2,
          },
        )),
        'Triage — high · borrower',
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
            'topics': ['rate lock', 'appraisal'],
          },
        )),
        'Extract — request · rate lock, appraisal',
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

    test('model tallies stay out of the sentence', () {
      // They are on nearly every AI row; spending the one line on them would
      // bury the fact the row exists to report. The trailing duration is where
      // the time goes.
      final sentence = ActivityLogPanel.describe(_event(
        kind: 'triage',
        durationMs: 9400,
        detail: const {
          'urgency': 'high',
          'category': 'borrower',
          'llm_calls': 3,
          'llm_ms': 9100,
          'prompt_tokens': 2200,
          'completion_tokens': 180,
          'llm_label': 'triage',
        },
      ));
      expect(sentence, 'Triage — high · borrower');
    });

    test('an unknown kind renders as itself rather than as nothing', () {
      expect(ActivityLogPanel.describe(_event(kind: 'brand_new')), 'brand_new');
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
