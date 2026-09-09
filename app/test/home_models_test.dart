import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/home_sort.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a feed row can say about itself without a database.
///
/// [HomeFeedRow.isStalled] is the reason this file exists. It is the one piece
/// of the stalled rule that lives in Dart rather than in the store's SQL, and
/// the two have to agree exactly — the tile counts what the rows flag — so it
/// is worth pinning at the minute rather than only end to end. `now` is a
/// parameter everywhere below, which is what makes that possible.
void main() {
  /// A row at [minutes] since its last progress write, with everything else
  /// set to the state a stalled row would be in.
  HomeFeedRow rowAged(
    int minutes, {
    String outcome = 'pending',
    bool workOpen = false,
    String? stamp,
  }) =>
      HomeFeedRow(
        source: 'email',
        sourceMessageId: 'm1',
        conversationKey: 'c1',
        receivedAt: '2026-09-01T10:00:00Z',
        triageState: 'done',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
        settleState: 'pending',
        outcome: outcome,
        dropped: false,
        updatedAt: stamp ??
            DateTime.utc(2026, 9, 1, 12)
                .subtract(Duration(minutes: minutes))
                .toIso8601String(),
        workOpen: workOpen,
      );

  final now = DateTime.utc(2026, 9, 1, 12);

  group('homeMetricsWindowLabel', () {
    test('days from two days up, hours below', () {
      expect(homeMetricsWindowLabel(const Duration(days: 7)), 'Last 7 days');
      expect(homeMetricsWindowLabel(const Duration(days: 2)), 'Last 2 days');
      expect(
        homeMetricsWindowLabel(const Duration(hours: 24)),
        'Last 24 hours',
      );
      expect(homeMetricsWindowLabel(const Duration(hours: 47)), 'Last 47 hours');
    });

    test('the window in force is a week', () {
      expect(homeMetricsWindow, const Duration(days: 7));
    });
  });

  group('isStalled', () {
    test('a pending row nobody is working on goes stalled at the threshold',
        () {
      expect(rowAged(14).isStalled(now), false);
      // The boundary is inclusive: a row exactly at the threshold has been
      // silent for the whole of it.
      expect(rowAged(15).isStalled(now), true);
      expect(rowAged(16).isStalled(now), true);
    });

    test('open work means slow, never stalled', () {
      expect(rowAged(16, workOpen: true).isStalled(now), false);
      expect(rowAged(600, workOpen: true).isStalled(now), false);
    });

    test('a finished row is never stalled, however old', () {
      expect(rowAged(600, outcome: 'done').isStalled(now), false);
      expect(rowAged(600, outcome: 'dropped').isStalled(now), false);
    });

    test('a clock it cannot read is not evidence of anything', () {
      // Better to say nothing than to accuse the pipeline of a fault that is
      // really a column an older build never wrote.
      expect(rowAged(600, stamp: '').isStalled(now), false);
      expect(rowAged(600, stamp: 'whenever').isStalled(now), false);
    });

    test('it reads the clock it is handed, never the wall', () {
      final row = rowAged(16);

      expect(row.isStalled(now), true);
      // The same row, asked about a moment before its own last write.
      expect(row.isStalled(DateTime.utc(2026, 9, 1, 11)), false);
    });
  });

  group('fromRow', () {
    Map<String, Object?> base(Map<String, Object?> extra) => {
          'source': 'email',
          'source_message_id': 'm1',
          'conversation_key': 'c1',
          'received_at': '2026-09-01T10:00:00Z',
          'outcome': 'pending',
          ...extra,
        };

    test('the needs-you verdict keeps its third state', () {
      expect(HomeFeedRow.fromRow(base({})).needsYouVerdict, isNull);
      expect(
        HomeFeedRow.fromRow(base({'needs_you_verdict': 1})).needsYouVerdict,
        true,
      );
      expect(
        HomeFeedRow.fromRow(base({'needs_you_verdict': 0})).needsYouVerdict,
        false,
      );
    });

    test('work_open reads as a flag', () {
      expect(HomeFeedRow.fromRow(base({'work_open': 1})).workOpen, true);
      expect(HomeFeedRow.fromRow(base({'work_open': 0})).workOpen, false);
      expect(HomeFeedRow.fromRow(base({})).workOpen, false);
    });

    test('the words come through as written, from their own two tables', () {
      final row = HomeFeedRow.fromRow(base({
        'summary': 'Confirms the launch is on the 14th',
        'cta_text': 'Send the signed order form',
      }));

      expect(row.summary, 'Confirms the launch is on the 14th');
      expect(row.ctaText, 'Send the signed order form');
      // A read that selected neither column says nothing rather than empty
      // string — "nobody has written one" is its own answer.
      expect(HomeFeedRow.fromRow(base({})).summary, isNull);
      expect(HomeFeedRow.fromRow(base({})).ctaText, isNull);
    });

    test('the thread state is read live, beside the frozen verdict', () {
      final row = HomeFeedRow.fromRow(base({
        'thread_state': 'needs_reply',
        'needs_you': 0,
      }));

      // The two disagree on purpose: the snapshot is what the message was
      // told at settle time, and the state is what the thread says now — the
      // fact the rail's Needs You rule stands on.
      expect(row.threadState, 'needs_reply');
      expect(row.needsYou, false);
      // A read that never selected the column says nothing rather than 'done',
      // which would be a verdict nobody wrote.
      expect(HomeFeedRow.fromRow(base({})).threadState, isNull);
    });

    test('the reasons come through as written', () {
      final row = HomeFeedRow.fromRow(base({
        'updated_at': '2026-09-01T11:00:00Z',
        'needs_you_reason': 'asks for the DPA by Friday',
        'gate_reason': 'addressed_me',
        'bucket': 'later',
        'bucket_reason': 'low_value',
        'attention_score': 0.42,
        'storyline_evidence': 'Same renewal thread',
        'storyline_added_by': 'auto',
      }));

      expect(row.updatedAt, '2026-09-01T11:00:00Z');
      expect(row.needsYouReason, 'asks for the DPA by Friday');
      expect(row.gateReason, 'addressed_me');
      expect(row.bucket, 'later');
      expect(row.bucketReason, 'low_value');
      expect(row.attentionScore, closeTo(0.42, 0.0001));
      expect(row.storylineEvidence, 'Same renewal thread');
      expect(row.storylineAddedBy, 'auto');
    });
  });

  group('the pulse', () {
    test('waiting, working and busy are the two maps added up', () {
      const pulse = PipelinePulse(
        queued: {'extract': 2, 'files': 1},
        running: {'triage': 3},
      );

      expect(pulse.waiting, 3);
      expect(pulse.working, 3);
      expect(pulse.busy, isTrue);
      expect(pulse.countFor('extract'), 2);
      expect(pulse.countFor('triage'), 3);
      // A stage neither map mentions answers zero, so a caller can walk
      // [PipelinePulse.stages] without asking whether each one is there.
      expect(pulse.countFor('draft'), 0);
    });

    test('an empty pulse is idle rather than unknown', () {
      const pulse = PipelinePulse();

      expect(pulse.busy, isFalse);
      expect(pulse.waiting, 0);
      expect(pulse.working, 0);
      expect(pulse.inFlight, 0);
    });

    test('a stage that is both waiting and working counts both', () {
      const pulse = PipelinePulse(
        queued: {'storyline': 4},
        running: {'storyline': 1},
      );

      expect(pulse.countFor('storyline'), 5);
    });

    test('every storyline pass is one stage, and chores are not stages', () {
      final storyline = [
        for (final entry in PipelinePulse.kindStages.entries)
          if (entry.key.startsWith('storyline')) entry.value,
      ];

      expect(storyline, hasLength(6));
      expect(storyline, everyElement('storyline'));
      // `mark_read` is a chore run on the user's behalf, not a stage of the
      // pipeline — a pulse that narrated it would be reporting housekeeping.
      expect(PipelinePulse.kindStages.containsKey('mark_read'), isFalse);
      // Every stage a kind maps to is one the narration knows how to walk.
      expect(
        PipelinePulse.kindStages.values.toSet()
            .difference(PipelinePulse.stages.toSet()),
        isEmpty,
      );
    });

    test('the window in force is ten minutes', () {
      expect(homePulseWindow, const Duration(minutes: 10));
    });
  });

  group('the filters', () {
    test('the seven are windowed, the pile and the feed are not', () {
      expect(
        {
          for (final filter in HomeFilter.values) filter: filter.windowed,
        },
        {
          // The feed itself, and the pile to burn down — all time, both.
          HomeFilter.fromOthers: false,
          HomeFilter.needsYou: false,
          // A readout of what the app has been doing, over the tiles' week.
          HomeFilter.urgent: true,
          HomeFilter.inFlight: true,
          HomeFilter.errors: true,
          HomeFilter.dropped: true,
          HomeFilter.processed: true,
        },
        reason: 'work owed since before last Tuesday is exactly what a window '
            'would hide',
      );
    });

    test('only the outcome filters can show the dropped pile', () {
      expect(
        {
          for (final filter in HomeFilter.values)
            filter: filter.showsDropped,
        },
        {
          HomeFilter.fromOthers: false,
          HomeFilter.needsYou: false,
          HomeFilter.urgent: false,
          HomeFilter.inFlight: true,
          HomeFilter.errors: true,
          HomeFilter.dropped: true,
          HomeFilter.processed: true,
        },
      );
    });

    test('every filter and every order says its own name', () {
      expect(
        [for (final filter in HomeFilter.values) filter.label],
        [
          'Everyone',
          'Needs you',
          'Urgent',
          'In flight',
          'Errors',
          'Dropped',
          'Processed',
        ],
      );
      expect(
        [for (final sort in HomeSort.values) sort.label],
        ['Newest first', 'Oldest first'],
      );
    });
  });

  group('restored', () {
    test('the optimistic row is working, not stalled', () {
      final restored = rowAged(600, outcome: 'dropped').restored();

      // Restore queues the work in the same breath as the reset, so the row
      // must not spend a frame accusing the pipeline of having stopped.
      expect(restored.workOpen, true);
      expect(restored.isStalled(now), false);
      expect(restored.outcome, 'pending');
      expect(restored.dropped, false);
    });

    test('it keeps the words — Restore does not unsay them', () {
      final row = HomeFeedRow.fromRow({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'received_at': '2026-09-01T10:00:00Z',
        'outcome': 'dropped',
        'dropped': 1,
        'summary': 'A weekly roundup nobody asked for',
        'cta_text': 'Send the signed order form',
        'thread_state': 'needs_reply',
      });

      final restored = row.restored();

      expect(restored.summary, 'A weekly roundup nobody asked for');
      expect(restored.ctaText, 'Send the signed order form');
      // The thread's state is a fact about the thread, and Restore reopens one
      // message. Blanking it would make the restored row invisible to the live
      // Needs You rule for the frame before the re-read lands.
      expect(restored.threadState, 'needs_reply');
    });

    test('it keeps the reasons — they are why the row was dropped', () {
      final row = HomeFeedRow.fromRow({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'received_at': '2026-09-01T10:00:00Z',
        'outcome': 'dropped',
        'dropped': 1,
        'updated_at': '2026-09-01T11:00:00Z',
        'needs_you_verdict': 0,
        'needs_you_reason': 'nobody is waiting on you',
        'gate_reason': 'newsletter',
        'bucket': 'later',
        'bucket_reason': 'low_value',
        'attention_score': 0.1,
        'storyline_evidence': 'Same renewal thread',
        'storyline_added_by': 'auto',
      });

      final restored = row.restored();

      expect(restored.updatedAt, '2026-09-01T11:00:00Z');
      expect(restored.needsYouVerdict, false);
      expect(restored.needsYouReason, 'nobody is waiting on you');
      expect(restored.gateReason, 'newsletter');
      expect(restored.bucket, 'later');
      expect(restored.bucketReason, 'low_value');
      expect(restored.attentionScore, closeTo(0.1, 0.0001));
      expect(restored.storylineEvidence, 'Same renewal thread');
      expect(restored.storylineAddedBy, 'auto');
    });
  });
}
