import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/message_history.dart';
import 'package:bond_inbox/screens/message_history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncValue;
import 'package:flutter_test/flutter_test.dart';

/// The "What happened" screen: what it says, and which levers it offers.
///
/// Pure — the story is a [MessageHistory] built from plain maps, exactly as
/// the assembler builds it from a store's rows, so nothing here needs a
/// database or a container. What is worth pinning is the pairing of a
/// CONDITION with an offer: a dropped row gets Restore and not Ignore, a
/// re-check's block gets Add back and not Allow again, and a message the store
/// has nothing under gets no offers at all.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

HomeFeedRow _row({
  String outcome = 'done',
  bool dropped = false,
  String? dropReason,
  String triage = 'done',
  String extract = 'done',
  String storyline = 'done',
  String draft = 'done',
  String settle = 'done',
  String? storylineId,
  String? storylineTitle,
  String? storylineEvidence,
  String updatedAt = '2026-09-03T11:59:00Z',
  bool workOpen = false,
}) =>
    HomeFeedRow(
      source: 'email',
      sourceMessageId: 'm1',
      conversationKey: 'c1',
      receivedAt: '2026-09-03T09:00:00Z',
      triageState: triage,
      extractState: extract,
      storylineState: storyline,
      draftState: draft,
      settleState: settle,
      outcome: outcome,
      dropped: dropped,
      dropReason: dropReason,
      storylineId: storylineId,
      storylineTitle: storylineTitle,
      storylineEvidence: storylineEvidence,
      subject: 'Renewal paperwork',
      fromName: 'Dana Whitfield',
      updatedAt: updatedAt,
      workOpen: workOpen,
    );

MessageHistory _history({
  HomeFeedRow? row,
  Map<String, Object?>? message,
  Map<String, Object?>? conversationAi,
  List<Map<String, Object?>> work = const [],
  List<Map<String, Object?>> memberships = const [],
  List<Map<String, Object?>> blocks = const [],
  List<Map<String, Object?>> activity = const [],
  Map<String, Object?>? progress,
  double threshold = 0.5,
}) =>
    MessageHistory.assemble(
      source: 'email',
      sourceMessageId: 'm1',
      message: message ??
          {
            'conversation_key': 'c1',
            'subject': 'Renewal paperwork',
            'from_name': 'Dana Whitfield',
            'received_at': '2026-09-03T09:00:00Z',
            'triage_status': 'triaged',
            'needs_you_verdict': 1,
            'needs_you_reason': 'Dana asked for the DPA',
            'urgency': 'soon',
            'category': 'request',
            'summary': 'A signed DPA before Friday',
          },
      conversation: const {'state': 'needs_reply'},
      conversationAi: conversationAi,
      progress: progress ??
          const {
            'triage_state': 'done',
            'triage_at': '2026-09-03T09:01:00Z',
            'extract_state': 'done',
            'storyline_state': 'done',
            'draft_state': 'done',
            'settle_state': 'done',
          },
      row: row ?? _row(),
      work: work,
      memberships: memberships,
      blocks: blocks,
      activity: activity,
      threshold: threshold,
    );

Future<void> _pump(
  WidgetTester tester,
  AsyncValue<MessageHistory> history, {
  void Function(String, String)? onOpenThread,
  void Function(String)? onOpenStoryline,
  VoidCallback? onRestore,
  VoidCallback? onRetry,
  VoidCallback? onRejudge,
  VoidCallback? onIgnore,
  VoidCallback? onAddToStoryline,
  void Function(String)? onRemoveFromStoryline,
  void Function(String)? onAllowAgain,
  void Function(String)? onAddBack,
  VoidCallback? onKeepInInbox,
  VoidCallback? onSendToLater,
  VoidCallback? onEditRules,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MessageHistoryScreen(
        history: history,
        now: _now,
        onBack: () {},
        onHome: () {},
        onOpenThread: onOpenThread ?? (_, _) {},
        onOpenStoryline: onOpenStoryline ?? (_) {},
        onRestore: onRestore,
        onRetry: onRetry,
        onRejudge: onRejudge,
        onIgnore: onIgnore,
        onAddToStoryline: onAddToStoryline,
        onRemoveFromStoryline: onRemoveFromStoryline,
        onAllowAgain: onAllowAgain,
        onAddBack: onAddBack,
        onKeepInInbox: onKeepInInbox,
        onSendToLater: onSendToLater,
        onEditRules: onEditRules,
      ),
    ),
  ));
}

void main() {
  testWidgets('a filed message shows every section, and its storyline is a '
      'link', (tester) async {
    final storylines = <String>[];
    await _pump(
      tester,
      AsyncValue.data(_history(
        row: _row(
          storylineId: 's1',
          storylineTitle: 'Website redesign',
          storylineEvidence: 'both threads are about the launch',
        ),
        memberships: const [
          {
            'storyline_id': 's1',
            'title': 'Website redesign',
            'status': 'active',
            'added_by': 'user',
            'evidence': 'you filed it',
          },
        ],
        work: const [
          {
            'task_kind': 'needs_you',
            'entity_id': 'm1',
            'status': 'pending',
            'attempts': 1,
          },
        ],
        activity: const [
          {
            'id': 4,
            'kind': 'triage',
            'status': 'ok',
            'created_at': '2026-09-03T09:01:00Z',
          },
        ],
      )),
      onOpenStoryline: storylines.add,
    );

    expect(find.text('What happened'), findsOneWidget);
    expect(find.text('Renewal paperwork'), findsOneWidget);
    expect(find.text('From Dana Whitfield'), findsOneWidget);
    for (final heading in const [
      'OUTCOME',
      'STAGES',
      'JUDGEMENTS',
      'STORYLINES',
      'WORK',
      'ACTIVITY',
    ]) {
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
    // The five stages, always five, whatever the progress row holds.
    expect(find.textContaining('triage: done'), findsOneWidget);
    expect(find.textContaining('settle: done'), findsOneWidget);
    // Judgements carry the reason the app wrote down at the time.
    expect(
      find.text('Needs you: yes — Dana asked for the DPA'),
      findsOneWidget,
    );
    expect(find.textContaining('vs threshold 0.50'), findsOneWidget);
    // The work list speaks the log's names for the stages, not the queue's
    // column values.
    expect(find.textContaining('Needs You · pending · attempt 1'),
        findsOneWidget);
    expect(find.textContaining('you filed it'), findsOneWidget);
    expect(find.textContaining('filed by you'), findsWidgets);

    await tester.tap(find.text('Website redesign'));
    expect(storylines, ['s1']);
  });

  testWidgets('a dropped message offers Restore and nothing that would run '
      'the pipeline again', (tester) async {
    await _pump(
      tester,
      AsyncValue.data(_history(
        row: _row(
          outcome: 'dropped',
          dropped: true,
          dropReason: 'newsletter',
          extract: 'skipped',
          storyline: 'skipped',
          draft: 'skipped',
        ),
        progress: const {
          'triage_state': 'done',
          'extract_state': 'skipped',
          'storyline_state': 'skipped',
          'draft_state': 'skipped',
          'settle_state': 'done',
        },
      )),
      onRestore: () {},
      onRetry: () {},
      onRejudge: () {},
      onIgnore: () {},
      onAddToStoryline: () {},
    );

    expect(find.byKey(MessageHistoryScreen.restoreKey), findsOneWidget);
    expect(find.byKey(MessageHistoryScreen.retryKey), findsNothing);
    expect(find.byKey(MessageHistoryScreen.rejudgeKey), findsNothing);
    expect(find.byKey(MessageHistoryScreen.ignoreKey), findsNothing);
    expect(find.byKey(MessageHistoryScreen.addToStorylineKey), findsNothing);
    // The skipped stages say WHY, which the bar's own tooltip cannot.
    expect(find.text('gated: Newsletter'), findsWidgets);
  });

  testWidgets('a stalled row offers Retry', (tester) async {
    await _pump(
      tester,
      AsyncValue.data(_history(
        row: _row(
          outcome: 'pending',
          settle: 'pending',
          // Sixteen minutes with nothing queued: stalled by the feed's own
          // definition, which is the only one this screen uses.
          updatedAt: '2026-09-03T11:44:00Z',
        ),
        progress: const {
          'triage_state': 'done',
          'extract_state': 'done',
          'storyline_state': 'done',
          'draft_state': 'done',
          'settle_state': 'pending',
        },
      )),
      onRestore: () {},
      onRetry: () {},
    );

    expect(find.byKey(MessageHistoryScreen.retryKey), findsOneWidget);
    expect(find.byKey(MessageHistoryScreen.restoreKey), findsNothing);
    // The label, and the reason clause under it: the Inbox splits these
    // across two cells, and this screen is where both fit.
    expect(find.text('Stalled'), findsOneWidget);
    expect(
      find.text('No progress for 15 minutes and nothing is queued — '
          'waiting on settle.'),
      findsOneWidget,
    );
  });

  testWidgets('Ignore is two taps, and the first one fires nothing',
      (tester) async {
    var ignored = 0;
    await _pump(
      tester,
      AsyncValue.data(_history()),
      onIgnore: () => ignored++,
    );

    await tester.tap(find.byKey(MessageHistoryScreen.ignoreKey));
    await tester.pump();
    expect(ignored, 0);
    expect(find.text('Really ignore?'), findsOneWidget);

    await tester.tap(find.byKey(MessageHistoryScreen.ignoreKey));
    await tester.pump();
    expect(ignored, 1);
    expect(find.text('Ignore this message'), findsOneWidget);
  });

  testWidgets('arming one question disarms the other', (tester) async {
    // Two open questions on one screen is how a person answers the wrong one.
    await _pump(
      tester,
      AsyncValue.data(_history(
        memberships: const [
          {
            'storyline_id': 's1',
            'title': 'Website redesign',
            'status': 'active',
            'added_by': 'auto',
            'evidence': 'shared thread',
          },
        ],
      )),
      onIgnore: () {},
      onRemoveFromStoryline: (_) {},
    );

    await tester.tap(find.byKey(MessageHistoryScreen.ignoreKey));
    await tester.pump();
    expect(find.text('Really ignore?'), findsOneWidget);

    await tester.tap(find.byKey(MessageHistoryScreen.removeKey('s1')));
    await tester.pump();

    expect(find.text('Really remove?'), findsOneWidget);
    expect(find.text('Ignore this message'), findsOneWidget);
    expect(find.text('Really ignore?'), findsNothing);
  });

  testWidgets('Remove is two taps as well', (tester) async {
    final removed = <String>[];
    await _pump(
      tester,
      AsyncValue.data(_history(
        memberships: const [
          {
            'storyline_id': 's1',
            'title': 'Website redesign',
            'status': 'active',
            'added_by': 'auto',
            'evidence': 'shared thread',
          },
        ],
      )),
      onRemoveFromStoryline: removed.add,
    );

    await tester.tap(find.byKey(MessageHistoryScreen.removeKey('s1')));
    await tester.pump();
    expect(removed, isEmpty);
    expect(find.text('Really remove?'), findsOneWidget);

    await tester.tap(find.byKey(MessageHistoryScreen.removeKey('s1')));
    await tester.pump();
    expect(removed, ['s1']);
  });

  testWidgets('both buttons are offered on every live block, whichever pass '
      'wrote it', (tester) async {
    final allowed = <String>[];
    final added = <String>[];
    await _pump(
      tester,
      AsyncValue.data(_history(
        blocks: const [
          {
            'storyline_id': 's1',
            'title': 'Website redesign',
            'status': 'active',
            'blocked_by': 'user',
            'evidence': 'you removed it',
          },
          {
            'storyline_id': 's2',
            'title': 'Q3 renewals',
            'status': 'active',
            'blocked_by': 'audit',
            'evidence': 'the re-check disagreed',
          },
        ],
      )),
      onAllowAgain: allowed.add,
      onAddBack: added.add,
    );

    expect(find.textContaining('Removed by you from Website redesign'),
        findsOneWidget);
    expect(find.textContaining('Removed by re-check from Q3 renewals'),
        findsOneWidget);
    expect(
      find.byKey(MessageHistoryScreen.allowAgainKey('s1')),
      findsOneWidget,
    );
    // The storyline's own About section offers both on both lists, and two
    // doors onto one decision have to agree about what is on offer.
    expect(
      find.byKey(MessageHistoryScreen.allowAgainKey('s2')),
      findsOneWidget,
    );
    expect(find.byKey(MessageHistoryScreen.addBackKey('s1')), findsOneWidget);
    expect(find.byKey(MessageHistoryScreen.addBackKey('s2')), findsOneWidget);

    await tester.tap(find.byKey(MessageHistoryScreen.allowAgainKey('s1')));
    await tester.tap(find.byKey(MessageHistoryScreen.addBackKey('s2')));
    expect(allowed, ['s1']);
    expect(added, ['s2']);
  });

  testWidgets('a block on a storyline that is no longer live offers nothing',
      (tester) async {
    await _pump(
      tester,
      AsyncValue.data(_history(
        blocks: const [
          {
            'storyline_id': 's1',
            'title': 'Website redesign',
            'status': 'dismissed',
            'blocked_by': 'user',
            'evidence': 'you removed it',
          },
        ],
      )),
      onAllowAgain: (_) {},
      onAddBack: (_) {},
    );

    // The sentence still stands: it is the record of what happened. What is
    // gone are the two levers, because a dismissed storyline answers neither.
    expect(find.textContaining('Removed by you from Website redesign'),
        findsOneWidget);
    expect(find.byKey(MessageHistoryScreen.allowAgainKey('s1')), findsNothing);
    expect(find.byKey(MessageHistoryScreen.addBackKey('s1')), findsNothing);
  });

  testWidgets('the bucket decides which of Keep and Later is offered',
      (tester) async {
    await _pump(
      tester,
      AsyncValue.data(_history(
        conversationAi: const {'bucket': 'later', 'bucket_reason': 'low_value'},
      )),
      onKeepInInbox: () {},
      onSendToLater: () {},
    );
    expect(find.byKey(MessageHistoryScreen.keepKey), findsOneWidget);
    expect(find.byKey(MessageHistoryScreen.laterKey), findsNothing);

    await _pump(
      tester,
      AsyncValue.data(_history()),
      onKeepInInbox: () {},
      onSendToLater: () {},
    );
    expect(find.byKey(MessageHistoryScreen.keepKey), findsNothing);
    expect(find.byKey(MessageHistoryScreen.laterKey), findsOneWidget);
  });

  testWidgets('a message the store has nothing under says so and offers '
      'nothing', (tester) async {
    await _pump(
      tester,
      AsyncValue.data(MessageHistory.missing('email', 'm9', threshold: 0.5)),
      onRestore: () {},
      onRetry: () {},
      onRejudge: () {},
      onIgnore: () {},
      onEditRules: () {},
    );

    expect(
      find.text('This message is no longer in the store.'),
      findsOneWidget,
    );
    expect(find.text('STAGES'), findsNothing);
    expect(find.text('ACTIONS'), findsNothing);
    for (final key in [
      MessageHistoryScreen.openThreadKey,
      MessageHistoryScreen.restoreKey,
      MessageHistoryScreen.retryKey,
      MessageHistoryScreen.rejudgeKey,
      MessageHistoryScreen.ignoreKey,
      MessageHistoryScreen.editRulesKey,
    ]) {
      expect(find.byKey(key), findsNothing, reason: '$key');
    }
  });

  testWidgets('Open thread names the source and the thread key',
      (tester) async {
    final opened = <(String, String)>[];
    await _pump(
      tester,
      AsyncValue.data(_history()),
      onOpenThread: (source, key) => opened.add((source, key)),
    );

    await tester.tap(find.byKey(MessageHistoryScreen.openThreadKey));
    expect(opened, [('email', 'c1')]);
  });

  testWidgets('loading says so in words, and a failed read says so too',
      (tester) async {
    await _pump(tester, const AsyncValue<MessageHistory>.loading());
    expect(find.text('Reading…'), findsOneWidget);

    await _pump(
      tester,
      AsyncValue<MessageHistory>.error('nope', StackTrace.empty),
    );
    expect(
      find.text("Couldn't read this message's history."),
      findsOneWidget,
    );
  });
}
