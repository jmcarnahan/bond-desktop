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

    testWidgets('a draft names the owner\'s own files it read', (tester) async {
      // The log is where a person goes back and asks what the app DID, after
      // the draft it belongs to has been sent, edited or thrown away. Basenames
      // rather than rel paths: a log line spends its width on the file, not on
      // the folders above it.
      await pump(
        tester,
        now: DateTime(2026, 3, 12, 9),
        events: [
          _event(
            kind: 'draft',
            detail: const {
              'chars': 120,
              'directory_files': ['docs/pricing.md', 'reports/analysis.html'],
            },
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
        ],
      );

      expect(
        find.text('Draft written — 120 chars · read pricing.md, analysis.html'),
        findsOneWidget,
      );
    });

    testWidgets('and counts them past the third', (tester) async {
      await pump(
        tester,
        now: DateTime(2026, 3, 12, 9),
        events: [
          _event(
            kind: 'draft',
            detail: const {
              'chars': 120,
              'directory_files': ['a.md', 'b.md', 'c.md', 'd.md'],
            },
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
        ],
      );

      expect(
        find.text('Draft written — 120 chars · read a.md, b.md, c.md, +1 more'),
        findsOneWidget,
      );
    });

    testWidgets('a draft that read none says only how long it is',
        (tester) async {
      await pump(
        tester,
        now: DateTime(2026, 3, 12, 9),
        events: [
          _event(
            kind: 'draft',
            detail: const {'chars': 120, 'directory_files': <String>[]},
            createdAt: DateTime(2026, 3, 12, 8, 30).toIso8601String(),
          ),
        ],
      );

      expect(find.text('Draft written — 120 chars'), findsOneWidget);
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

    testWidgets('the speed cell names the model', (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'triage',
            detail: const {
              'completion_tokens': 60,
              'llm_ms': 4000,
              'llm_model': 'qwen3-4b',
            },
          ),
        ],
      );

      // The one question a rate raises once the model is switchable: fast at
      // WHAT. The column has no room for the name, so it rides the tooltip.
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.text('15 t/s'),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, 'qwen3-4b');
    });

    testWidgets('a row with no model has no tooltip at all', (tester) async {
      await pump(
        tester,
        events: [
          _event(
            kind: 'triage',
            detail: const {'completion_tokens': 60, 'llm_ms': 4000},
          ),
        ],
      );

      // Not an empty tooltip — none. This Flutter pops a bubble for an empty
      // message, and every row written before the model was recorded has to
      // look exactly as it did. (The header's speed tile reads the same
      // figure; neither it nor the row may carry a tooltip here.)
      expect(
        find.ancestor(
          of: find.text('15 t/s'),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
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

    testWidgets('a streamed draft spells out its time to first token',
        (tester) async {
      // The expanded body renders every detail key generically, so a key the
      // recorder learns to write needs no panel change. This pins that.
      await pump(
        tester,
        events: [
          _event(
            kind: 'draft',
            detail: const {
              'llm_calls': 1,
              'llm_ms': 8400,
              'completion_tokens': 220,
              'first_token_ms': 273,
            },
          ),
        ],
      );

      await tester.tap(find.text('Draft written'));
      await tester.pumpAndSettle();

      expect(find.text('first_token_ms: 273'), findsOneWidget);
      expect(find.text('llm_calls: 1'), findsOneWidget);
    });
  });

  group('describe', () {
    test('a scheduling ask: the owner\'s word on it, by its origin, under '
        'its own label', () {
      String said(String origin) => ActivityLogPanel.describe(_event(
            kind: 'scheduling_ask',
            detail: {'origin': origin},
          ));
      expect(said('invite'), 'Closed an ask after an invite');
      expect(said('dismiss'), 'Dismissed an ask');
      expect(said('undo'), 'Brought an ask back');
      expect(said('owner'), 'Marked a thread as asking for a time');
      expect(ActivityLogPanel.kindLabel('scheduling_ask'), 'Scheduling ask');
      expect(said('later'), 'Scheduling ask');
    });

    test('times offered in a draft: how many slots and from where; a skip '
        'by its enum word', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'find_time',
          detail: const {
            'action': 'draft',
            'source': 'graph',
            'slots': 3,
            'people': 1,
            'window': 'this_week',
            'graph_calls': 1,
            'read': 'rules',
          },
        )),
        'Times offered in a draft · 3 slots (graph)',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'find_time',
          detail: const {'action': 'draft', 'source': 'local', 'slots': 1},
        )),
        'Times offered in a draft · 1 slot (local)',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'find_time',
          status: 'skipped',
          detail: const {'action': 'draft', 'reason': 'transient'},
        )),
        'Find a time skipped — transient',
      );
    });

    test('the stale-times redraft: how many replies, never which', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'draft',
          status: 'requeued',
          count: 2,
          detail: const {'reason': 'slots_stale'},
        )),
        'Redrafting 2 replies — their times are gone',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'draft',
          status: 'requeued',
          count: 1,
          detail: const {'reason': 'slots_stale'},
        )),
        'Redrafting 1 reply — their times are gone',
      );
    });

    test('a meeting brief: written from how many threads, skipped with its '
        'reason in words, or failed', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          detail: const {'threads': 3, 'asks': 1},
        )),
        'Meeting brief — written from 3 threads',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          detail: const {'threads': 1},
        )),
        'Meeting brief — written from 1 thread',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'skipped',
          detail: const {'reason': 'no_mail'},
        )),
        'Meeting brief — skipped (no recent mail with these people)',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'skipped',
          detail: const {'reason': 'unchanged'},
        )),
        'Meeting brief — skipped (nothing new since the last one)',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'error',
          detail: const {'error': 'not JSON'},
        )),
        'Meeting brief — failed',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'skipped',
          detail: const {'reason': 'too_many'},
        )),
        'Meeting brief — skipped (too many people)',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'skipped',
          detail: const {'reason': 'materials_pending'},
        )),
        'Meeting brief — skipped (reading the files sent ahead)',
      );
      // Over a ready brief the old one stands, and the sentence says so.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'skipped',
          detail: const {'reason': 'past', 'kept': 'ready'},
        )),
        'Meeting brief — skipped (already started); the last brief stands',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'error',
          detail: const {'error': 'not JSON', 'kept': 'ready'},
        )),
        'Meeting brief — failed; the last brief stands',
      );
      // A park is the pipeline's news, in the general sentence.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'meeting_brief',
          status: 'parked',
          detail: const {'reason': 'model_unavailable'},
        )),
        'Meeting brief parked — model server off',
      );
    });

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

    test('a re-judge says how much the rules edit queued', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'needs_you_rejudge', count: 12)),
        'Needs You re-judge — 12 messages',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'needs_you_rejudge', count: 1)),
        'Needs You re-judge — 1 message',
      );
    });

    test('the two hands on one message read as what a person did', () {
      // A pair, because they are opposites and the panel is where somebody
      // goes to work out which of them they pressed last week.
      expect(
        ActivityLogPanel.describe(_event(kind: 'ignore', entityId: 'm1')),
        'Ignored a message',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'restore', entityId: 'm1')),
        'Restored a filtered message',
      );
      // And the kind is named as well as sentenced: status is read before
      // kind, so a row that failed falls back to the label map, and an
      // unmapped kind would print `ignore` in a column of English.
      expect(
        ActivityLogPanel.describe(
          _event(kind: 'ignore', status: 'error', detail: const {}),
        ),
        startsWith('Ignore failed'),
      );
    });

    test('a gate repair says what it took back', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'gate_repair',
          entityId: 'm1',
          count: 2,
          detail: const {
            'reason': 'extracted_then_gated',
            'extracted': 1,
            'storylines': 2,
            'embedding_cleared': true,
          },
        )),
        allOf(
          contains('2 storyline memberships'),
          contains('1 message extracted before its gate'),
          contains('embedding cleared'),
        ),
      );
      // Nothing moved, and the counter is the whole row: what the app used to
      // do before the gates could speak first.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'gate_repair',
          count: 0,
          detail: const {
            'reason': 'ignored',
            'extracted': 1,
            'storylines': 0,
            'embedding_cleared': false,
          },
        )),
        'Gate repair — 1 message extracted before its gate',
      );
      // The one-shot says so, because "the database was like this" is a
      // different sentence from "a gate just landed".
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'gate_repair',
          count: 3,
          detail: const {
            'reason': 'one_shot',
            'conversations': 4,
            'extracted': 5,
            'storylines': 3,
            'embeddings_cleared': 4,
          },
        )),
        allOf(
          contains('one-shot:'),
          contains('4 threads walked'),
          contains('3 storyline memberships'),
          contains('5 messages in the database extracted before their gate'),
          contains('4 embeddings cleared'),
        ),
      );
      // A sweep that walked threads and finished none of them is not a clean
      // database, and must not read as one.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'gate_repair',
          count: 0,
          detail: const {
            'reason': 'one_shot',
            'conversations': 4,
            'extracted': 0,
            'storylines': 0,
            'embeddings_cleared': 0,
            'failed': 4,
          },
        )),
        allOf(contains('4 threads walked'), contains('4 failed')),
      );
    });

    test('a triage retry names the reason when it has one', () {
      // The headerless defer: nothing failed about the message, something it
      // needed did not arrive.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'retry',
          detail: const {'reason': 'headerless', 'attempts': 1},
        )),
        'Triage retry (attempt 1) — headers did not arrive — retried',
      );
      // And an ordinary model retry, which carries an error rather than a
      // reason, reads exactly as it always did.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'retry',
          detail: const {'error': 'bad json', 'attempts': 1},
        )),
        'Triage retry (attempt 1)',
      );
    });

    test('a reconcile names what the delta feed skipped', () {
      // The row exists only because it found something, so the sentence has no
      // "nothing new" form to write — it says what was missing instead.
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_reconcile', count: 1)),
        'Mail reconcile — 1 message the delta feed skipped',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'sync_reconcile', count: 3)),
        'Mail reconcile — 3 messages the delta feed skipped',
      );
    });

    test('a calendar command says what was asked, who read it and what came '
        'back, in enum words', () {
      String command(String action, String path, String outcome) =>
          ActivityLogPanel.describe(_event(
            kind: 'calendar_command',
            detail: {'action': action, 'path': path, 'outcome': outcome},
          ));
      expect(command('move', 'lexicon', 'proposal'),
          'Calendar command — Move · lexicon · proposal');
      expect(command('ask_agenda', 'lexicon', 'answer'),
          'Calendar command — Agenda · lexicon · answer');
      expect(command('create', 'generative', 'slots'),
          'Calendar command — Create · generative · slots');
      expect(command('unknown', 'generative', 'cannot'),
          'Calendar command — Not understood · generative · cannot');
      expect(ActivityLogPanel.kindLabel('calendar_command'),
          'Calendar command');
    });

    test('find a time says how many slots and whose calendars, then what '
        'was done with them, in counts and enum words', () {
      String row(Map<String, Object?> detail) =>
          ActivityLogPanel.describe(_event(kind: 'find_time', detail: detail));
      expect(
          row({'source': 'graph', 'slots': 3, 'people': 2,
              'window': 'this_week'}),
          'Find a time — 3 slots (graph)');
      expect(row({'source': 'local', 'slots': 1, 'people': 0,
              'window': 'next_week'}),
          'Find a time — 1 slot (local)');
      expect(row({'action': 'put_in_reply'}), 'Find a time — put in reply');
      expect(row({'action': 'send_invite'}), 'Find a time — invite sent');
      expect(row({'action': 'add_to_calendar'}),
          'Find a time — added to calendar');
      expect(ActivityLogPanel.kindLabel('find_time'), 'Find a time');
    });

    test('an ask reading says how many days it read, or that nobody asked, '
        'in counts and enum words', () {
      String row(Map<String, Object?> detail, {String status = 'ok'}) =>
          ActivityLogPanel.describe(
              _event(kind: 'ask_read', status: status, detail: detail));
      expect(row({'status': 'ready', 'when': 2, 'meal': 'none'}),
          'Read an ask · 2 days');
      expect(row({'status': 'ready', 'when': 1, 'meal': 'dinner'}),
          'Read an ask · 1 day');
      expect(row({'status': 'ready', 'when': 0, 'meal': 'coffee'}),
          'Read an ask · no day named');
      expect(row({'status': 'none', 'when': 0, 'meal': 'none'}),
          'Read an ask · no time asked');
      // The Day column's verdict: booleans only.
      expect(row({'applied': false, 'agree': true, 'cached': true}),
          'The model read the ask the way the rules did');
      expect(row({'applied': true, 'agree': false, 'cached': false}),
          "The model's reading replaced the rules'");
      expect(row({'applied': false, 'agree': false, 'cached': false}),
          "The rules' reading stood");
      // An error takes the general sentence, with its type only.
      expect(row({'error': 'LlmFormatException'}, status: 'error'),
          'Ask reading failed — LlmFormatException');
      expect(ActivityLogPanel.kindLabel('ask_read'), 'Ask reading');
    });

    test('a reminder says what happened to it in To Do, in enum words only',
        () {
      String row(Map<String, Object?> detail, {String status = 'ok'}) =>
          ActivityLogPanel.describe(
              _event(kind: 'reminder', status: status, detail: detail));
      expect(
          row({'action': 'create', 'kind': 'reply_by', 'created_from': 'bar',
              'flagged': false, 'linked': true}),
          'Reminder set in To Do (reply by)');
      expect(
          row({'action': 'create', 'kind': 'follow_up', 'created_from': 'send',
              'flagged': true, 'linked': false}),
          'Reminder set in To Do (follow up)');
      expect(
          row({'action': 'create', 'kind': 'deadline', 'created_from': 'auto',
              'flagged': false, 'linked': false}),
          'Reminder set in To Do (deadline)');
      expect(row({'action': 'complete', 'kind': 'follow_up', 'reason': 'reply'}),
          'Reminder done — answered');
      expect(row({'action': 'complete', 'kind': 'reply_by', 'reason': 'done'}),
          'Reminder done — thread done');
      expect(row({'action': 'complete', 'kind': 'custom', 'reason': 'owner'}),
          'Reminder done — by you');
      expect(
          row({'action': 'complete', 'kind': 'follow_up', 'reason': 'expired'}),
          'Reminder — no longer tracked (30 days past)');
      expect(row({'action': 'cancel', 'kind': 'reply_by'}),
          'Reminder cancelled');
      // The follow-up's flag never fails the reminder, so its one error row
      // reads as what did not happen.
      expect(row({'action': 'flag', 'kind': 'follow_up'}, status: 'error'),
          'Could not flag the mail');
      expect(ActivityLogPanel.kindLabel('reminder'), 'Reminder');
    });

    test('a calendar write says what it did and how many it emailed', () {
      String write(String action,
              {String status = 'ok',
              String outcome = 'ok',
              int notified = 0,
              bool undo = false}) =>
          ActivityLogPanel.describe(_event(
            kind: 'calendar_write',
            status: status,
            detail: {
              'action': action,
              'outcome': outcome,
              'notified': notified,
              if (undo) 'undo': true,
            },
          ));
      expect(write('accept', notified: 1),
          'Calendar — Accepted a meeting · emailed 1');
      expect(write('tentative', notified: 1),
          'Calendar — Said maybe to a meeting · emailed 1');
      expect(write('decline', notified: 1),
          'Calendar — Declined a meeting · emailed 1');
      expect(write('propose', notified: 1),
          'Calendar — Proposed a new time · emailed 1');
      expect(write('move'), 'Calendar — Moved an event');
      expect(write('cancel', notified: 4),
          'Calendar — Cancelled a meeting · emailed 4');
      expect(write('delete'), 'Calendar — Deleted an event');
      expect(write('create'), 'Calendar — Created an event');
      expect(write('move', undo: true), 'Calendar — Undid a change');
      expect(write('move', status: 'failed', outcome: 'changed'),
          "Calendar — couldn't move an event (changed)");
      // Every answer fails as an answer, whichever it was going to be.
      expect(write('accept', status: 'failed', outcome: 'transient'),
          "Calendar — couldn't answer a meeting (transient)");
      expect(write('tentative', status: 'failed', outcome: 'refused'),
          "Calendar — couldn't answer a meeting (refused)");
      expect(write('decline', status: 'failed', outcome: 'transient'),
          "Calendar — couldn't answer a meeting (transient)");
      expect(write('create', status: 'failed', outcome: 'scope_missing'),
          "Calendar — couldn't create an event (scope_missing)");
    });

    test('one changed file reads as one file', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_reconcile',
          detail: const {'changed': 1, 'removed': 1},
        )),
        'Read directory — 1 file changed · 1 removed',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_reconcile',
          detail: const {'changed': 3},
        )),
        'Read directory — 3 files changed',
      );
    });

    test('a file digest names what the model decided the file is', () {
      // The kind hint is the judgement a person would want to see before
      // they trust the rest of the record.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_digest',
          detail: const {'kind_hint': 'analysis', 'findings': 3},
        )),
        'Directory file digest — analysis',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'context_digest')),
        'Directory file digest',
      );
    });

    test('a deleted file and a de-registered directory read differently', () {
      // Two reasons and not one: a digest is queued per FILE, so the file
      // the walk deleted between the queue and the pass is the ordinary
      // skip, while the whole shelf going is the other thing entirely.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_digest',
          status: 'skipped',
          detail: const {'reason': 'file_gone'},
        )),
        'Directory file digest skipped — the file is no longer in the '
            'directory',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_digest',
          status: 'skipped',
          detail: const {'reason': 'gone'},
        )),
        'Directory file digest skipped — the directory is no longer '
            'registered',
      );
    });

    test('a brief counts the files it mapped', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_brief',
          detail: const {'files_mapped': 12, 'pointers': 4},
        )),
        'Directory brief — 12 files mapped',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'context_brief')),
        'Directory brief',
      );
    });

    test('a brief that offered a charter says so on the same line', () {
      // No work row stands behind a charter offer, so a reader hunting for
      // what this pass did would find a storyline write with nothing above it.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_brief',
          detail: const {'files_mapped': 12, 'charters_offered': 2},
        )),
        'Directory brief — 12 files mapped · 2 charters offered',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'context_brief',
          detail: const {'files_mapped': 12, 'charters_offered': 1},
        )),
        'Directory brief — 12 files mapped · 1 charter offered',
      );
    });

    test('a retry names the stages it put back', () {
      // Which work was requeued is the whole question a person has after
      // pressing Retry; a count of stages does not answer it.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'retry',
          count: 2,
          detail: const {
            'stages': ['triage', 'extract'],
          },
        )),
        'Retried triage, extract',
      );
    });

    test('a retry with no stages recorded still reads as one', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'retry')),
        'Retried owed stages',
      );
      expect(
        ActivityLogPanel.describe(
          _event(kind: 'retry', detail: const {'stages': []}),
        ),
        'Retried owed stages',
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

    test('the other two park words read as themselves, not as a raw reason',
        () {
      // Unmapped, both of these fell through to the underscores-opened
      // fallback and a column of parked rows could not be scanned: which slot
      // died, and whether waiting or a new key is what fixes it, is the whole
      // content of the row.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'unauthorized'},
        )),
        'Triage parked — the access key was refused',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'embed_message',
          status: 'parked',
          detail: const {'reason': 'embed_unavailable'},
        )),
        'Embed message parked — embedding server unreachable',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'decision_unavailable'},
        )),
        'Triage parked — decision model unreachable',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'not_installed'},
        )),
        'Triage parked — model not downloaded',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'decision_not_installed'},
        )),
        'Triage parked — decision model not installed',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'decision_older_model'},
        )),
        'Triage parked — decision model is an older version',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'triage',
          status: 'parked',
          detail: const {'reason': 'decision_unauthorized'},
        )),
        'Triage parked — the decision server refused the access key',
      );
    });

    test('a document read says how many passages it became', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'attachment_text',
          detail: const {'chars': 4200, 'chunks': 8, 'embedded': 8},
        )),
        'Read attachment — 8 passages',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'attachment_text',
          detail: const {'chunks': 1},
        )),
        'Read attachment — 1 passage',
      );
    });

    test('a document read that counted nothing is still named', () {
      expect(
        ActivityLogPanel.describe(_event(kind: 'attachment_text')),
        'Read attachment',
      );
    });

    test('a digest says what the model decided the document was', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'attachment_digest',
          detail: const {'kind': 'invoice', 'facts': 4, 'asks': 1},
        )),
        'Attachment digest — invoice',
      );
      expect(
        ActivityLogPanel.describe(_event(kind: 'attachment_digest')),
        'Attachment digest',
      );
    });

    test('a skipped attachment reads as a skip, not a failure', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'attachment_text',
          status: 'skipped',
          detail: const {'reason': 'no_extractor'},
        )),
        'Read attachment skipped — no extractor',
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

    test('a sweep says what its probe joined, when it had a probe', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 2,
            'rejected': 0,
            'joined': 1,
          },
        )),
        'Storyline sweep — 1 proposed, 2 threads confirmed, 0 rejected, '
        '1 joined',
      );
      // The finished threads are their own count, never folded into the
      // cluster's: this pass confirmed two members and pulled in none.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 2,
            'rejected': 0,
            'joined': 0,
          },
        )),
        'Storyline sweep — 1 proposed, 2 threads confirmed, 0 rejected, '
        '0 joined',
      );
    });

    test('a deferred sweep says what it is waiting for', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'deferred': 'unsettled',
            'extract': 42,
            'embed': 7,
            'triage': 0,
          },
        )),
        'Storyline sweep — deferred, mailbox unsettled: extract 42, embed 7, '
        'triage 0',
      );
      // A key that is not a number is left out rather than printed as null.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'deferred': 'unsettled', 'embed': 30},
        )),
        'Storyline sweep — deferred, mailbox unsettled: embed 30',
      );
      // The expiry runs before the deferral, so the two arrive together.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'deferred': 'unsettled',
            'extract': 11,
            'embed': 0,
            'triage': 0,
            'expired': 2,
          },
        )),
        'Storyline sweep — deferred, mailbox unsettled: extract 11, embed 0, '
        'triage 0, 2 expired',
      );
    });

    test('a sweep says what it expired and what rode in as a fragment', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 3,
            'rejected': 0,
            'joined': 0,
            'fragments': 2,
            'expired': 1,
          },
        )),
        'Storyline sweep — 1 proposed, 3 threads confirmed, 0 rejected, '
        '0 joined, 2 fragments, 1 expired',
      );
      // One fragment is a fragment, and `expired` has no plural to get wrong.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 2,
            'rejected': 0,
            'joined': 0,
            'fragments': 1,
          },
        )),
        'Storyline sweep — 1 proposed, 2 threads confirmed, 0 rejected, '
        '0 joined, 1 fragment',
      );
      // Zero fragments is the ordinary pass and says nothing.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 2,
            'rejected': 0,
            'joined': 0,
            'fragments': 0,
          },
        )),
        'Storyline sweep — 1 proposed, 2 threads confirmed, 0 rejected, '
        '0 joined',
      );
    });

    test('a sweep that only skipped clusters a possible storyline holds says why',
        () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 0,
            'confirmed': 0,
            'rejected': 0,
            'joined': 0,
            'overlaps_possible': 1,
          },
        )),
        'Storyline sweep — 0 proposed, 0 threads confirmed, 0 rejected, '
        '0 joined, 1 left for a possible storyline',
      );
    });

    test('a sweep that folded rows but shipped none of them says so', () {
      // `fragments` counts the siblings that JOINED and `folded` counts every
      // row the rule folded, so a pass whose cluster was turned down still
      // reports the folding it did.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 0,
            'confirmed': 0,
            'rejected': 0,
            'joined': 0,
            'fragments': 0,
            'folded': 2,
          },
        )),
        'Storyline sweep — 0 proposed, 0 threads confirmed, 0 rejected, '
        '0 joined, 2 folded',
      );
      // All three of the sometimes-counts on one row, in the order the pass
      // produced them.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {
            'proposed': 1,
            'confirmed': 3,
            'rejected': 0,
            'joined': 0,
            'fragments': 2,
            'folded': 3,
            'expired': 1,
          },
        )),
        'Storyline sweep — 1 proposed, 3 threads confirmed, 0 rejected, '
        '0 joined, 2 fragments, 3 folded, 1 expired',
      );
    });

    test('a pass that only expired still has a sentence', () {
      // Every early return in the sweep is behind the expiry, so a row whose
      // detail is nothing but this key is a shape that actually happens.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'expired': 3},
        )),
        'Storyline sweep — 3 expired',
      );
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_sweep',
          detail: const {'expired': 0},
        )),
        'Storyline sweep',
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

    test('a re-check says what it looked at and what it took out', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_audit',
          detail: const {
            'checked': 4,
            'removed': [
              {'source': 'email', 'conversation_key': 'c9'},
            ],
          },
        )),
        'Re-checked 4 threads, removed 1',
      );
      // One thread reads as one thread, and a pass that took nothing out still
      // says what it checked.
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_audit',
          detail: const {'checked': 1, 'removed': []},
        )),
        'Re-checked 1 thread, removed 0',
      );
      // A row with no tallies on it falls back to its label rather than
      // claiming a number it does not have.
      expect(
        ActivityLogPanel.describe(_event(kind: 'storyline_audit')),
        'Storyline re-check',
      );
    });

    test('allowing a thread back says only that', () {
      expect(
        ActivityLogPanel.describe(_event(
          kind: 'storyline_unblock',
          detail: const {'storyline_id': 'sl-1'},
        )),
        'Allowed a thread back into consideration',
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
