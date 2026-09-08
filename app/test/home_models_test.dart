import 'package:bond_inbox/models/home_models.dart';
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
