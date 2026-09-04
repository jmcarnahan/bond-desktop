// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The home feed while the pipeline is running: what a stage write does to the
/// table under it.
///
/// Every test here is a `testWidgets` even though nothing is rendered, for one
/// reason: the notifier's whole liveness is timers, and only a widget test has
/// a clock to run them on. The framework's leaked-timer check is the second
/// half of the suite — a test that ends with a window still armed fails, which
/// is exactly the guarantee this screen needs.
///
/// Every pump is a named constant. The durations are shared between the
/// notifier and the row widget precisely so that they cannot drift apart, and
/// a test that pumped 3000ms would not notice if they did.

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProgressBus bus;
  late PipelineProgress progress;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bus = ProgressBus();
    progress = PipelineProgress(store, bus: bus);
  });

  tearDown(() async {
    bus.dispose();
    await db.close();
  });

  /// Stores a message and hands back the answer the ingest tick needs — null
  /// when the pipeline had already heard of it.
  Future<String?> seed(
    String id, {
    required String receivedAt,
    String source = 'email',
    String? gateReason,
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': 'c-$id',
        'direction': 'inbound',
        'subject': 'Subject $id',
        'from_name': 'Sender $id',
        'received_at': receivedAt,
        // A gate skip with a reason is what lands a row dropped at ingest.
        if (gateReason != null) 'triage_status': 'skipped',
        'gate_reason': ?gateReason,
      });

  /// Stores a message and announces it, the pair the sync services make.
  Future<void> arrive(
    String id, {
    required String receivedAt,
    String source = 'email',
    String? gateReason,
  }) async {
    final ingested = await seed(
      id,
      receivedAt: receivedAt,
      source: source,
      gateReason: gateReason,
    );
    progress.noteIngest(source, id, receivedAt: ingested!);
  }

  HomeFeedNotifier build() {
    final notifier = HomeFeedNotifier(store, bus: bus);
    addTearDown(notifier.dispose);
    return notifier;
  }

  List<String> idsOf(HomeFeedNotifier notifier) =>
      [for (final row in notifier.state.rows) row.sourceMessageId];

  String keyOf(String id, {String source = 'email'}) => '$source\n$id';

  /// One tick window, plus the frames the batch read behind it takes to come
  /// back and be applied.
  Future<void> settleTicks(WidgetTester tester) async {
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump();
    await tester.pump();
  }

  /// Runs out what a batch leaves armed behind it, so a test ends clean.
  Future<void> quiet(WidgetTester tester) async {
    await tester.pump(HomeFeedNotifier.entryClear);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  /// Three visible rows, newest last-named.
  Future<void> seedThree() async {
    await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
    await seed('m2', receivedAt: '2026-09-03T10:00:00Z');
    await seed('m3', receivedAt: '2026-09-03T11:00:00Z');
  }

  group('a tick about a row already on the table', () {
    testWidgets('patches it where it stands, without reordering anything',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      expect(idsOf(notifier), ['m3', 'm2', 'm1']);

      await progress.noteTriage('email', 'm2', state: 'done');
      await settleTicks(tester);

      expect(
        idsOf(notifier),
        ['m3', 'm2', 'm1'],
        reason: 'a bar that filled is not a message that arrived',
      );
      expect(notifier.state.rows[1].triageState, 'done');
      expect(notifier.state.entering, isEmpty);
      await quiet(tester);
    });

    testWidgets('the draft segment fills off the same patch as the other four',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      expect(notifier.state.rows[1].draftState, 'pending');

      // The reply pipeline is the slow one — two model calls stand between
      // these two ticks, and the bar has to say so for the whole of it.
      await progress.noteDraft('email', 'm2', state: 'running');
      await settleTicks(tester);
      expect(notifier.state.rows[1].draftState, 'running');
      expect(idsOf(notifier), ['m3', 'm2', 'm1']);

      await progress.noteDraft('email', 'm2', state: 'done');
      await settleTicks(tester);
      expect(notifier.state.rows[1].draftState, 'done');
      await quiet(tester);
    });
  });

  group('an arrival', () {
    testWidgets('goes to the top while the reader is there, and animates once',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();

      await arrive('m9', receivedAt: '2026-09-03T12:00:00Z');
      await settleTicks(tester);

      expect(idsOf(notifier), ['m9', 'm3', 'm2', 'm1']);
      expect(notifier.state.entering, {keyOf('m9')});

      await tester.pump(HomeFeedNotifier.entryClear);
      expect(
        notifier.state.entering,
        isEmpty,
        reason: 'a key left in the set replays its entrance on every scroll',
      );
      await quiet(tester);
    });

    testWidgets('waits behind a count while the reader is scrolled away',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      notifier.setAnchored(false);

      await arrive('m9', receivedAt: '2026-09-03T12:00:00Z');
      await settleTicks(tester);

      expect(idsOf(notifier), ['m3', 'm2', 'm1'], reason: 'nothing moved');
      expect(notifier.state.pendingNewCount, 1);

      await arrive('m10', receivedAt: '2026-09-03T13:00:00Z');
      await settleTicks(tester);
      expect(notifier.state.pendingNewCount, 2);

      await notifier.releasePending();

      expect(idsOf(notifier), ['m10', 'm9', 'm3', 'm2', 'm1']);
      expect(notifier.state.pendingNewCount, 0);
      expect(notifier.state.entering, {keyOf('m9'), keyOf('m10')});
      await quiet(tester);
    });

    testWidgets('past the cap the count keeps counting, and releasing reloads',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      notifier.setAnchored(false);

      // One arrival more than the buffer will hold. One timestamp for all of
      // them: the tie-break is the id, and what is under test is the count,
      // not the order.
      final over = HomeFeedNotifier.bufferCap + 1;
      for (var i = 0; i < over; i++) {
        await arrive(
          'w${i.toString().padLeft(3, '0')}',
          receivedAt: '2026-09-03T12:00:00Z',
        );
      }
      await settleTicks(tester);

      expect(
        notifier.state.pendingNewCount,
        over,
        reason: 'the rows are gone but the promise is not',
      );

      await notifier.releasePending();

      expect(
        notifier.state.rows,
        hasLength(HomeFeedNotifier.pageSize),
        reason: 'more waited than were kept, so releasing is a fresh page one',
      );
      expect(idsOf(notifier).first, 'w200');
      expect(notifier.state.pendingNewCount, 0);
      await quiet(tester);
    });

    testWidgets('releases under anything that landed after the reader was back',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      notifier.setAnchored(false);

      await arrive('m9', receivedAt: '2026-09-03T12:00:00Z');
      await settleTicks(tester);
      expect(notifier.state.pendingNewCount, 1);

      // Back at the top with the pill still up: the next arrival goes straight
      // onto the table, newer than everything the pill is holding.
      notifier.setAnchored(true);
      await arrive('m10', receivedAt: '2026-09-03T13:00:00Z');
      await settleTicks(tester);
      expect(idsOf(notifier), ['m10', 'm3', 'm2', 'm1']);

      await notifier.releasePending();

      expect(
        idsOf(notifier),
        ['m10', 'm9', 'm3', 'm2', 'm1'],
        reason: 'a held row is older than the arrival that beat it out',
      );
      expect(notifier.state.pendingNewCount, 0);
      await quiet(tester);
    });

    testWidgets('older than the head lands in its place, without animating',
        (tester) async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
      await seed('m3', receivedAt: '2026-09-03T11:00:00Z');
      final notifier = build();
      await notifier.load();
      expect(idsOf(notifier), ['m3', 'm1']);

      await arrive('m2', receivedAt: '2026-09-03T10:00:00Z');
      await settleTicks(tester);

      expect(idsOf(notifier), ['m3', 'm2', 'm1']);
      expect(
        notifier.state.entering,
        isEmpty,
        reason: 'a row in the middle of a table did not arrive there',
      );
      await quiet(tester);
    });

    testWidgets('older than the tail is kept only once the walk has ended',
        (tester) async {
      // A full page, so there is history the reader has not walked to yet.
      for (var i = 0; i < HomeFeedNotifier.pageSize; i++) {
        await seed(
          'p${i.toString().padLeft(2, '0')}',
          receivedAt: '2026-09-03T10:${i.toString().padLeft(2, '0')}:00Z',
        );
      }
      final notifier = build();
      await notifier.load();
      expect(notifier.state.atEnd, isFalse);

      await arrive('old1', receivedAt: '2026-09-02T09:00:00Z');
      await settleTicks(tester);

      expect(
        idsOf(notifier), isNot(contains('old1')),
        reason: 'the page walk is what brings it, in order',
      );

      await notifier.loadMore();
      expect(notifier.state.atEnd, isTrue);

      await arrive('old2', receivedAt: '2026-09-01T09:00:00Z');
      await settleTicks(tester);

      expect(idsOf(notifier).last, 'old2');
      await quiet(tester);
    });
  });

  group('the drop show', () {
    testWidgets('grays, lingers, collapses, and only then is gone',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();

      await progress.noteSettled(
        'email',
        'm2',
        needsYou: false,
        reason: 'newsletter',
        dropped: true,
      );
      await settleTicks(tester);

      expect(notifier.state.fading, {keyOf('m2')});
      expect(idsOf(notifier), ['m3', 'm2', 'm1'], reason: 'still there, gray');

      await tester.pump(homeDropLinger);
      expect(notifier.state.collapsing, {keyOf('m2')});
      expect(notifier.state.fading, isEmpty);
      expect(idsOf(notifier), ['m3', 'm2', 'm1']);

      await tester.pump(homeDropCollapse);
      expect(idsOf(notifier), ['m3', 'm1']);
      expect(notifier.state.collapsing, isEmpty);
      await quiet(tester);
    });

    testWidgets('a gate-dropped arrival appears just long enough to be read',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();

      await arrive(
        'n1',
        receivedAt: '2026-09-03T12:00:00Z',
        gateReason: 'newsletter',
      );
      await settleTicks(tester);

      expect(idsOf(notifier), ['n1', 'm3', 'm2', 'm1']);
      expect(notifier.state.fading, {keyOf('n1')});
      expect(notifier.state.entering, {keyOf('n1')});

      await tester.pump(HomeFeedNotifier.entryClear);
      await tester.pump(homeDropLinger);
      await tester.pump(homeDropCollapse);

      expect(idsOf(notifier), ['m3', 'm2', 'm1']);
      expect(notifier.state.fading, isEmpty);
      expect(notifier.state.collapsing, isEmpty);
      await quiet(tester);
    });

    testWidgets('is not performed for a reader who is looking elsewhere',
        (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();
      notifier.setAnchored(false);

      await arrive(
        'n1',
        receivedAt: '2026-09-03T12:00:00Z',
        gateReason: 'newsletter',
      );
      await settleTicks(tester);

      expect(idsOf(notifier), ['m3', 'm2', 'm1']);
      expect(
        notifier.state.pendingNewCount,
        0,
        reason: 'a count that promised a dropped row would promise nothing',
      );
      expect(notifier.state.fading, isEmpty);
      await quiet(tester);
    });

    testWidgets('a reload takes the show with it', (tester) async {
      await seedThree();
      final notifier = build();
      await notifier.load();

      await progress.noteSettled(
        'email',
        'm2',
        needsYou: false,
        reason: 'newsletter',
        dropped: true,
      );
      await settleTicks(tester);
      expect(notifier.state.fading, {keyOf('m2')});

      await notifier.load();

      expect(notifier.state.fading, isEmpty);
      expect(notifier.state.collapsing, isEmpty);
      expect(
        idsOf(notifier),
        ['m3', 'm1'],
        reason: 'the fresh page is read against the visible index',
      );
      // Nothing left armed: the framework fails this test if the linger timer
      // survived the reload.
      await tester.pump(homeDropLinger);
      await tester.pump(homeDropCollapse);
      await quiet(tester);
    });
  });

  testWidgets('the tiles are pulsed once per burst, however big it is',
      (tester) async {
    await seedThree();
    final notifier = build();
    await notifier.load();
    final before = notifier.state.metricsEpoch;

    for (final id in ['m1', 'm2', 'm3', 'm1', 'm2']) {
      bus.publish(ProgressTick(
        source: 'email',
        sourceMessageId: id,
        stage: 'triage',
        state: 'done',
        receivedAt: '2026-09-03T10:00:00Z',
      ));
    }
    await settleTicks(tester);
    expect(
      notifier.state.metricsEpoch,
      before,
      reason: 'the tiles wait out the burst',
    );

    await tester.pump(HomeFeedNotifier.metricsDebounce);
    expect(notifier.state.metricsEpoch, before + 1);
    await quiet(tester);
  });

  testWidgets('disposing mid-linger leaves nothing running', (tester) async {
    await seedThree();
    // Not the shared builder: this one is disposed inside the test, and a
    // second dispose from a tearDown would be the error rather than the leak.
    final notifier = HomeFeedNotifier(store, bus: bus);
    await notifier.load();

    await progress.noteSettled(
      'email',
      'm2',
      needsYou: false,
      reason: 'newsletter',
      dropped: true,
    );
    await settleTicks(tester);
    expect(notifier.state.fading, {keyOf('m2')});

    notifier.dispose();

    await tester.pump(homeDropLinger);
    await tester.pump(homeDropCollapse);
    await quiet(tester);
  });
}
