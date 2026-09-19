// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_repair_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/composer.dart' show Composer;
import 'package:bond_inbox/widgets/home_pane.dart' show HomePane;
import 'package:bond_inbox/widgets/person_room_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The processing switch, as the assembled screen carries it.
///
/// `processing_toggle_test.dart` is about the two drains; this file is about
/// the four facts only the screen can answer: the switch is OFF on a fresh
/// launch, turning it on pumps triage before the lanes, the composer's draft
/// button goes inert while it is off, and every throw of it is recorded.

class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// An [LlmClient] that never opens a socket. Nothing in this file is meant to
/// reach a model at all.
class _NeverLlm extends LlmClient {
  _NeverLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');
}

/// A repair service that always says it queued a stage.
///
/// What the Retry toast turns on is the ANSWER, not the repair: a row that
/// owes nothing is told so, and a row that owes something is told where the
/// work went. Seeding a genuinely stalled message would test the repair's
/// own rules over again, which `pipeline_repair_service_test.dart` owns.
class _StubRepair extends PipelineRepairService {
  _StubRepair(super.store, {this.owed = const ['triage']});

  final List<String> owed;

  @override
  Future<List<String>> retryOwed(String source, String sourceMessageId) async =>
      owed;
}

/// Records that it was pumped or stopped, and drains nothing.
class _RecordingTriage extends TriageQueue {
  final List<String> order;

  _RecordingTriage(MessageStore store, this.order) : super(store, _NeverLlm());

  @override
  Future<void> pump() async => order.add('triage');

  @override
  void stop() => order.add('stop triage');
}

/// The same, one per lane.
class _RecordingWorker extends AiWorker {
  final List<String> order;
  final String name;

  _RecordingWorker(super.store, this.name, this.order)
      : super(handlers: const []);

  @override
  Future<void> pump() async => order.add(name);

  @override
  void stop() => order.add('stop $name');
}

const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// One mail thread with a message nobody has answered — enough for the
  /// transcript to dock a reply box under it.
  Future<void> seedThread() async {
    await store.upsertMessage({
      'source_message_id': 'c1-m1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The homepage copy is in.',
    });
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': '2026-08-28T09:00:00Z',
      'last_inbound_at': '2026-08-28T09:00:00Z',
    });
    await store.recomputeConversationCounts('email', 'c1');
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<Override> extra = const [],
    RailSection section = RailSection.people,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _readGrant;
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The app's default backend is MCP, whose session would answer the scope
    // question by asking a server that is not there.
    await store.setPref(backendModeKey, backendModeSdk);
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        // People by default, because the thread this file opens is reached
        // through its sender's room — the route `thread_suggestions_test`
        // uses. Home for the tests about the feed's own controls.
        initialSectionProvider.overrideWithValue(section),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        ...extra,
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Pumps rather than a settle: this screen owns a sixty-second periodic
    // timer, and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openThread(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text('Eric Vance'),
    ));
    await tester.pump();
    await tester.pump();
    // The tap, the transcript read, then the capability the box waits on.
    await tester.tap(find.byType(RootMessageCard).first);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Finder toggle() => find.byKey(const ValueKey('processing-toggle'));

  /// The four drains, replaced by recorders that write into [order] and drain
  /// nothing. One list for all four, so what the switch did to the set is read
  /// as one sequence rather than four counters.
  List<Override> recorders(List<String> order) => [
        triageQueueProvider
            .overrideWith((ref) => _RecordingTriage(store, order)),
        aiWorkerProvider
            .overrideWith((ref) => _RecordingWorker(store, 'fast', order)),
        storylineWorkerProvider
            .overrideWith((ref) => _RecordingWorker(store, 'storyline', order)),
        draftWorkerProvider
            .overrideWith((ref) => _RecordingWorker(store, 'draft', order)),
      ];

  /// Taps the switch and lets what it started land.
  ///
  /// Bounded pumps and never `pumpEventQueue`: inside a `testWidgets` body the
  /// event queue is the fake-async zone's, and a clock nothing advances hangs
  /// the whole file silently — which is exactly what it did here. Small
  /// durations rather than bare pumps, because `_setProcessing` awaits an
  /// activity write before it pumps anything.
  Future<void> throwSwitch(WidgetTester tester) async {
    await tester.tap(toggle());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// The generate button, by the words on it rather than by a key: the label
  /// is what a reader looks for, and the button is a plain [TextButton] that
  /// nothing else on this screen shares.
  TextButton generateButton(WidgetTester tester) => tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Draft reply'),
          matching: find.byType(TextButton),
        ),
      );

  testWidgets('the switch starts off on every launch', (tester) async {
    await seedThread();
    await pumpScreen(tester);

    expect(toggle(), findsOneWidget);
    expect(tester.widget<Switch>(toggle()).value, isFalse,
        reason: 'a launch that started working before the owner had pointed '
            'it at a server is the whole reason this switch exists');
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('turning it on pumps triage and then the lanes', (tester) async {
    final order = <String>[];
    await seedThread();
    await pumpScreen(tester, extra: recorders(order));

    // Whatever the screen's own load pumped on the way up is not this test's
    // subject: the list is emptied so the order below is the SWITCH's.
    await tester.pump(const Duration(milliseconds: 10));
    order.clear();

    await throwSwitch(tester);

    // Triage FIRST and not merely alongside: the gates have to have spoken
    // before extraction reads the row — see `pumpTriageThenWorkers`.
    expect(order.first, 'triage');
    expect(order, containsAll(['triage', 'fast', 'storyline', 'draft']));
    expect(tester.widget<Switch>(toggle()).value, isTrue);
    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('turning it off stops all four drains', (tester) async {
    // The mirror of the test above, and the half that costs model time when
    // it is missing: a fast drain that was already running keeps dialling for
    // as long as its backlog lasts unless something tells it to stop.
    final order = <String>[];
    await seedThread();
    await pumpScreen(tester, extra: recorders(order));

    await throwSwitch(tester);
    order.clear();
    await throwSwitch(tester);

    expect(order, [
      'stop triage',
      'stop fast',
      'stop storyline',
      'stop draft',
    ]);
    expect(tester.widget<Switch>(toggle()).value, isFalse);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('the switch records what it was set to, both ways',
      (tester) async {
    await seedThread();
    await pumpScreen(tester, extra: recorders(<String>[]));

    await throwSwitch(tester);
    await throwSwitch(tester);

    final rows = [
      for (final row in await store.recentActivity())
        if (row['kind'] == 'processing') row['status'],
    ];
    // Newest first, so the off is the head: one row per throw, and the status
    // is the whole of what the row says.
    expect(rows, ['off', 'on']);
  });

  testWidgets('the composer cannot be asked for a draft while off',
      (tester) async {
    await seedThread();
    await pumpScreen(tester, extra: recorders(<String>[]));
    await openThread(tester);

    expect(find.byType(Composer), findsOneWidget);
    // Visible and inert, not hidden: the button is how a reader learns the
    // switch is down.
    expect(find.text('Draft reply'), findsOneWidget);
    expect(generateButton(tester).onPressed, isNull);
    expect(find.byTooltip('Processing is off'), findsOneWidget);

    await throwSwitch(tester);

    expect(generateButton(tester).onPressed, isNotNull);
    expect(find.byTooltip('Processing is off'), findsNothing);
  });

  group('Retry while the switch is off', () {
    /// The home feed's Retry, reached through the pane's own callback rather
    /// than through a stalled fixture: what is under test is the HOST's
    /// answer to the switch, and the row that draws the link is
    /// `home_feed_row_test`'s subject.
    Future<void> pressRetry(WidgetTester tester) async {
      tester.widget<HomePane>(find.byType(HomePane)).onRetry!('email', 'c1-m1');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets('says the work is queued rather than done', (tester) async {
      await seedThread();
      await pumpScreen(
        tester,
        section: RailSection.home,
        extra: [
          ...recorders(<String>[]),
          pipelineRepairServiceProvider.overrideWith((ref) => _StubRepair(
                ref.watch(messageStoreProvider),
              )),
        ],
      );

      await pressRetry(tester);

      // The requeue landed and nothing will drain it until the switch moves.
      // Without the sentence the press reads as ignored: the row is unchanged
      // afterwards, which is exactly what a press that did nothing looks like.
      expect(find.text('Queued until processing is on.'), findsOneWidget);
    });

    testWidgets('and says nothing at all once it is on', (tester) async {
      await seedThread();
      await pumpScreen(
        tester,
        section: RailSection.home,
        extra: [
          ...recorders(<String>[]),
          processingProvider.overrideWith((ref) => ProcessingNotifier()..set(true)),
          pipelineRepairServiceProvider.overrideWith((ref) => _StubRepair(
                ref.watch(messageStoreProvider),
              )),
        ],
      );

      await pressRetry(tester);

      expect(find.text('Queued until processing is on.'), findsNothing);
    });

    testWidgets('a row that owes nothing is still told so', (tester) async {
      // The older sentence, which the switch must not have taken over: an
      // empty answer is about the ROW, and it is true either way.
      await seedThread();
      await pumpScreen(
        tester,
        section: RailSection.home,
        extra: [
          ...recorders(<String>[]),
          pipelineRepairServiceProvider.overrideWith((ref) => _StubRepair(
                ref.watch(messageStoreProvider),
                owed: const [],
              )),
        ],
      );

      await pressRetry(tester);

      expect(find.text('Nothing to retry — every stage has finished.'),
          findsOneWidget);
      expect(find.text('Queued until processing is on.'), findsNothing);
    });
  });
}
