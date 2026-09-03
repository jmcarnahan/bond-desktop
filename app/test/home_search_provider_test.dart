import 'dart:async';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Search as the home feed's notifier runs it: what a submitted sentence does
/// to the state, and — just as much — what it deliberately does not.
///
/// The layering is the thing under test. Search sits BESIDE the live table
/// rather than replacing it: the rows keep being patched underneath a set of
/// results, an index that cannot answer never swaps the body, and every answer
/// that comes back late is checked against the question that is still standing.

/// A recording stand-in for [MessageSearch], one query at a time.
///
/// Answers are queued rather than returned: a search that is still out is the
/// state most of these tests are about, so the completer has to be reachable
/// from outside.
class _FakeRunner {
  final List<({String query, bool includeDropped})> calls = [];
  final List<Completer<MessageSearchResult>> pending = [];

  Future<MessageSearchResult> call(
    String query, {
    bool includeDropped = false,
  }) {
    calls.add((query: query, includeDropped: includeDropped));
    final completer = Completer<MessageSearchResult>();
    pending.add(completer);
    return completer.future;
  }

  /// The answer to the [index]th question asked, oldest first.
  void answer(int index, MessageSearchResult result) =>
      pending[index].complete(result);
}

HomeFeedRow _row(String id, {String subject = 'Subject'}) => HomeFeedRow(
      source: 'email',
      sourceMessageId: id,
      conversationKey: 'c-$id',
      receivedAt: '2026-09-03T09:00:00Z',
      triageState: 'done',
      extractState: 'done',
      storylineState: 'done',
      settleState: 'done',
      outcome: 'done',
      dropped: false,
      subject: subject,
    );

MessageSearchHits _hits(String query, List<String> ids) => MessageSearchHits(
      query,
      [for (final id in ids) SemanticHit(_row(id), 0.1)],
    );

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProgressBus bus;
  late PipelineProgress progress;
  late _FakeRunner runner;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bus = ProgressBus();
    progress = PipelineProgress(store, bus: bus);
    runner = _FakeRunner();
  });

  tearDown(() async {
    bus.dispose();
    await db.close();
  });

  HomeFeedNotifier build({bool live = false}) {
    final notifier = HomeFeedNotifier(
      store,
      searchRunner: runner.call,
      persistIncludeDropped: (_) async {},
      bus: live ? bus : null,
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  Future<void> seed(String id, {required String receivedAt}) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': 'c-$id',
        'direction': 'inbound',
        'subject': 'Subject $id',
        'from_name': 'Sender $id',
        'received_at': receivedAt,
      });

  test('a submitted query runs trimmed, against the current filter', () async {
    final notifier = build();
    final search = notifier.submitSearch('  invoice  ');
    expect(runner.calls, [(query: 'invoice', includeDropped: false)]);
    runner.answer(0, _hits('invoice', const []));
    await search;
    // Left first, so the filter change is a filter change and not the re-ask
    // that has its own test below.
    notifier.exitSearch();

    await notifier.setIncludeDropped(true);
    final second = notifier.submitSearch('invoice');
    expect(runner.calls.last, (query: 'invoice', includeDropped: true));
    runner.answer(runner.pending.length - 1, _hits('invoice', const []));
    await second;
  });

  test('searching is words in the state, and the body it describes is '
      'unchanged', () async {
    await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
    final notifier = build();
    await notifier.load();
    final rows = notifier.state.rows;

    final search = notifier.submitSearch('invoice');

    expect(notifier.state.searching, isTrue);
    expect(notifier.state.search, isNull, reason: 'the answer is not back yet');
    expect(notifier.state.rows, same(rows));

    runner.answer(0, _hits('invoice', const []));
    await search;
  });

  test('hits land as the shown search', () async {
    final notifier = build();
    final search = notifier.submitSearch('invoice');
    runner.answer(0, _hits('invoice', ['a', 'b']));
    await search;

    expect(notifier.state.search, isNotNull);
    expect(notifier.state.search!.query, 'invoice');
    expect(notifier.state.search!.hits, hasLength(2));
    expect(notifier.state.searching, isFalse);
  });

  test('a blank query is not a search', () async {
    final notifier = build();
    final before = notifier.state;

    await notifier.submitSearch('   ');

    expect(runner.calls, isEmpty, reason: 'nothing to spend a call on');
    expect(notifier.state, same(before));
  });

  group('unavailable is a notice, never a mode', () {
    test('a reader in the live feed stays in it', () async {
      final notifier = build();
      final search = notifier.submitSearch('invoice');
      runner.answer(
        0,
        const MessageSearchUnavailable(
          'the embedding server is not reachable — run: make embed',
        ),
      );
      await search;

      expect(notifier.state.searchNotice, contains('make embed'));
      expect(
        notifier.state.search,
        isNull,
        reason: 'an index that is off is not an empty mailbox',
      );
      expect(notifier.state.searching, isFalse);
    });

    test('a reader holding results keeps them', () async {
      final notifier = build();
      final first = notifier.submitSearch('invoice');
      runner.answer(0, _hits('invoice', ['a', 'b']));
      await first;
      final shown = notifier.state.search;

      final second = notifier.submitSearch('parking');
      runner.answer(
        1,
        const MessageSearchUnavailable('the semantic index is unavailable'),
      );
      await second;

      expect(notifier.state.search, same(shown));
      expect(notifier.state.searchNotice, contains('index'));
    });
  });

  test('a newer search outranks a slower older one', () async {
    final notifier = build();
    final first = notifier.submitSearch('a');
    final second = notifier.submitSearch('b');

    runner.answer(1, _hits('b', ['b1']));
    await second;
    runner.answer(0, _hits('a', ['a1']));
    await first;

    expect(notifier.state.search!.query, 'b');
    expect(notifier.state.search!.hits.first.row.sourceMessageId, 'b1');
  });

  test('leaving search drops a result still in flight', () async {
    final notifier = build();
    final search = notifier.submitSearch('invoice');

    notifier.exitSearch();
    runner.answer(0, _hits('invoice', ['a']));
    await search;

    expect(notifier.state.search, isNull);
    expect(notifier.state.searching, isFalse);
  });

  test('a new submit clears the standing notice', () async {
    final notifier = build();
    final first = notifier.submitSearch('invoice');
    runner.answer(0, const MessageSearchUnavailable('the index is off'));
    await first;
    expect(notifier.state.searchNotice, isNotNull);

    final second = notifier.submitSearch('parking');

    expect(notifier.state.searching, isTrue);
    expect(
      notifier.state.searchNotice,
      isNull,
      reason: 'a reason for the last answer is not a reason for this one',
    );

    runner.answer(1, _hits('parking', const []));
    await second;
  });

  test('the dropped toggle re-asks the question', () async {
    final notifier = build();
    final first = notifier.submitSearch('invoice');
    runner.answer(0, _hits('invoice', ['a']));
    await first;

    final toggled = notifier.setIncludeDropped(true);
    // The reload runs first, so the re-ask is queued behind it: the answer is
    // completed once the call has actually been made.
    await pumpEventQueue();
    runner.answer(runner.pending.length - 1, _hits('invoice', ['a', 'b']));
    await toggled;

    expect(runner.calls.last, (query: 'invoice', includeDropped: true));
    expect(notifier.state.search!.hits, hasLength(2));
  });

  test('the toggle re-asks even a question still in flight', () async {
    final notifier = build();
    // Never answered: the toggle flips while the index is still thinking.
    final first = notifier.submitSearch('invoice');

    final toggled = notifier.setIncludeDropped(true);
    await pumpEventQueue();
    expect(
      runner.calls.last,
      (query: 'invoice', includeDropped: true),
      reason: 'the answer on its way back was asked under the other filter',
    );

    // The first answer arrives late, against the old filter — and loses to
    // the re-ask on the stamp, exactly as a slower older search does.
    runner.answer(0, _hits('invoice', ['stale']));
    runner.answer(1, _hits('invoice', ['a', 'b']));
    await first;
    await toggled;

    expect(notifier.state.search!.hits, hasLength(2));
  });

  testWidgets('live rows keep moving under the results', (tester) async {
    await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
    await seed('m2', receivedAt: '2026-09-03T10:00:00Z');
    final notifier = build(live: true);
    await notifier.load();

    final search = notifier.submitSearch('invoice');
    runner.answer(0, _hits('invoice', ['a']));
    await search;
    final shown = notifier.state.search;

    await progress.noteTriage('email', 'm1', state: 'done');
    // One tick window, plus the frames the batch read behind it takes.
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump();
    await tester.pump();

    expect(
      notifier.state.rows.last.triageState,
      'done',
      reason: 'the table was covered, not unloaded',
    );
    expect(notifier.state.search, same(shown));

    // Runs out what the batch left armed, so the test ends clean.
    await tester.pump(HomeFeedNotifier.entryClear);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  });
}
