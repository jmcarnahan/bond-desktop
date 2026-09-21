import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/ai_workers.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The one sentence that tells somebody the pipeline is stuck, and why.
///
/// Three claims, tested at three heights. The WORDING is a pure function and
/// is pinned as one, because that is the thing a copy change breaks. The
/// MERGE of the two drains' streams is a provider and is pinned in a
/// container. And the rail actually renders it, which is pinned against the
/// assembled screen, because the wiring between the three is where this could
/// silently do nothing.
///
/// Nothing here polls anything: the reason rides the progress streams the
/// counts already ride, and the next pump is what clears it.

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

/// A triage queue that drains nothing and publishes whatever a test pushes.
class _FeedTriage extends TriageQueue {
  _FeedTriage(MessageStore store) : super(store, ScriptedLlm.never());

  final StreamController<TriageProgress> _feed =
      StreamController<TriageProgress>.broadcast();

  @override
  Stream<TriageProgress> get progress => _feed.stream;

  @override
  Future<void> pump() async {}

  void push(TriageProgress value) => _feed.add(value);

  @override
  Future<void> dispose() async {
    await _feed.close();
    await super.dispose();
  }
}

/// The same for the worker lanes, behind the `AiWorkers` the rail reads.
///
/// A subclass rather than an `implements`, so the three lane fields and
/// everything the screen might reach for are real. The three workers drain
/// nothing: they are built with no handlers, over a store this file never
/// seeds.
class _FeedWorkers extends AiWorkers {
  _FeedWorkers(MessageStore store)
      : super(
          fast: AiWorker(store, handlers: const []),
          storyline: AiWorker(store, handlers: const []),
          draft: AiWorker(store, handlers: const []),
        );

  final StreamController<WorkProgress> _feed =
      StreamController<WorkProgress>.broadcast();

  @override
  Stream<WorkProgress> get progress => _feed.stream;

  /// Nothing to drain, and nothing that should try: the rail's own poll pumps
  /// this on a timer.
  @override
  Future<void> pumpAll() async {}

  void push(WorkProgress value) {
    if (!_feed.isClosed) _feed.add(value);
  }

  @override
  Future<void> dispose() async {
    await _feed.close();
    await super.dispose();
  }
}

const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

void main() {
  group('the sentence', () {
    test('a parked box names the box, and a parked local server does not', () {
      expect(
        railProgressLine(
          on: true,
          remaining: 3,
          reason: 'model_unavailable',
          waiting: 3,
          onBox: true,
        ),
        'GPU box unreachable · 3 waiting · retrying each minute',
      );
      expect(
        railProgressLine(
          on: true,
          remaining: 3,
          reason: 'model_unavailable',
          waiting: 3,
          onBox: false,
        ),
        'Model server unreachable · 3 waiting · retrying each minute',
      );
    });

    test('a refused key names the machine that refused, and claims no retry',
        () {
      // Deliberately without "retrying each minute": retrying will not help
      // until somebody fixes the key, and promising a fix on a timer would be
      // a lie a person waits through.
      expect(
        railProgressLine(
          on: true,
          remaining: 2,
          reason: 'unauthorized',
          waiting: 2,
          onBox: true,
        ),
        'GPU box refused the access key · 2 waiting',
      );
      // A local server behind a reverse proxy answers 401 too, and sending
      // that person to look at a GPU box would be the wrong address.
      expect(
        railProgressLine(
          on: true,
          remaining: 2,
          reason: 'unauthorized',
          waiting: 2,
          onBox: false,
        ),
        'Model server refused the access key · 2 waiting',
      );
    });

    test('session keeps the wording it always had', () {
      // A sign-out is already routed by the inbox notifier, and a second
      // sentence about it here would be the app saying the same thing twice.
      for (final onBox in [true, false]) {
        expect(
          railProgressLine(
            on: true,
            remaining: 4,
            reason: 'session',
            waiting: 4,
            onBox: onBox,
          ),
          'Triaging 4 remaining…',
        );
      }
    });

    test('nothing parked is the count it always was', () {
      expect(
        railProgressLine(
          on: true,
          remaining: 7,
          reason: null,
          waiting: 7,
          onBox: true,
        ),
        'Triaging 7 remaining…',
      );
    });

    test('processing being off wins over every park', () {
      // A queue nobody is draining is not a queue that is stuck, and the
      // sentence has to say the thing the person can actually change.
      for (final reason in [null, 'model_unavailable', 'unauthorized']) {
        expect(
          railProgressLine(
            on: false,
            remaining: 5,
            reason: reason,
            waiting: 5,
            onBox: true,
          ),
          'Processing is off · 5 waiting',
          reason: '$reason',
        );
      }
    });

    test('the off count is the whole backlog, not triage alone', () {
      // Triage has two and the three worker lanes hold six more. The switch
      // is about the pipeline, so the number is the pipeline's.
      expect(
        railProgressLine(
          on: false,
          remaining: 2,
          reason: null,
          waiting: 8,
          onBox: false,
        ),
        'Processing is off · 8 waiting',
      );
    });

    test('no sentence carries an em-dash, a parenthesis or an arrow', () {
      for (final reason in [null, 'model_unavailable', 'unauthorized', 'session']) {
        for (final on in [true, false]) {
          final line = railProgressLine(
            on: on,
            remaining: 1,
            reason: reason,
            waiting: 1,
            onBox: true,
          );
          expect(line, isNot(contains('—')));
          expect(line, isNot(contains('(')));
          expect(line, isNot(contains('->')));
          expect(line, isNot(contains('→')));
        }
      }
    });
  });

  group('the merge', () {
    late BondDatabase db;
    late MessageStore store;
    late _FeedTriage triage;
    late _FeedWorkers workers;
    late ProviderContainer container;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
      triage = _FeedTriage(store);
      workers = _FeedWorkers(store);
      container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        triageQueueProvider.overrideWithValue(triage),
        aiWorkersProvider.overrideWithValue(workers),
      ]);
    });

    tearDown(() async {
      container.dispose();
      await triage.dispose();
      await workers.dispose();
      await db.close();
    });

    /// Subscribes, pushes, and reads the last value.
    Future<ParkedFact?> after(void Function() push) async {
      final seen = <ParkedFact>[];
      final sub = container.listen<AsyncValue<ParkedFact>>(
        parkedProvider,
        (_, next) {
          final value = next.valueOrNull;
          if (value != null) seen.add(value);
        },
        fireImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);
      push();
      await Future<void>.delayed(Duration.zero);
      sub.close();
      return seen.isEmpty ? null : seen.last;
    }

    test('the waiting count is both drains together', () async {
      final fact = await after(() {
        triage.push(const TriageProgress({'pending': 2}));
        workers.push(const WorkProgress('extract', {'pending': 3}));
      });

      expect(fact?.waiting, 5);
      expect(fact?.reason, isNull);
    });

    test('a park on either drain is reported', () async {
      var fact = await after(() {
        workers.push(const WorkProgress('extract', {'pending': 1},
            parkedReason: 'model_unavailable'));
      });
      expect(fact?.reason, 'model_unavailable');

      fact = await after(() {
        triage.push(const TriageProgress({'pending': 1},
            parkedReason: 'unauthorized'));
      });
      expect(fact?.reason, 'unauthorized');
    });

    test('triage wins when both parked, and one drain holds its last value',
        () async {
      // Triage is at the front of the pipeline, and a second sentence about
      // the same server being down is not more information. The worker's
      // count stays in the total while triage keeps emitting, which is what
      // "holds the last value of each" buys.
      final fact = await after(() {
        workers.push(const WorkProgress('extract', {'pending': 4},
            parkedReason: 'model_unavailable'));
        triage.push(const TriageProgress({'pending': 1},
            parkedReason: 'unauthorized'));
      });

      expect(fact?.reason, 'unauthorized');
      expect(fact?.waiting, 5);
    });

    test('a fast-lane park survives the other lanes emitting nothing',
        () async {
      // `AiWorkers` forwards three lanes onto ONE stream and a drain emits per
      // handler even when that handler had no rows, so the storyline lane
      // reports itself a microsecond after the fast lane parked. With one slot
      // for all three that emit erased the reason and replaced the count; with
      // one slot per kind it does neither.
      final fact = await after(() {
        workers.push(const WorkProgress('extract', {'pending': 4},
            parkedReason: 'model_unavailable'));
        workers.push(const WorkProgress('storyline', {}));
        workers.push(const WorkProgress('draft', {}));
      });

      expect(fact?.reason, 'model_unavailable');
      expect(fact?.waiting, 4);
    });

    test('the count sums the three lanes and triage', () async {
      final fact = await after(() {
        triage.push(const TriageProgress({'pending': 1}));
        workers.push(const WorkProgress('extract', {'pending': 2}));
        workers.push(const WorkProgress('storyline', {'pending': 3}));
        workers.push(const WorkProgress('draft', {'processing': 4}));
      });

      expect(fact?.waiting, 10);
      expect(fact?.reason, isNull);
    });

    test('a kind that parks and then clears gives the reason back up',
        () async {
      // One kind's later emit speaks for that kind only. The draft lane's park
      // is still the answer once the fast lane has cleared its own.
      final fact = await after(() {
        workers.push(const WorkProgress('extract', {'pending': 1},
            parkedReason: 'model_unavailable'));
        workers.push(const WorkProgress('draft', {'pending': 2},
            parkedReason: 'unauthorized'));
        workers.push(const WorkProgress('extract', {'pending': 0}));
      });

      // `extract` came first and is clear now, so the next non-null in order
      // is the draft lane's.
      expect(fact?.reason, 'unauthorized');
      expect(fact?.waiting, 2);
    });

    test('a later emit with no reason clears it', () async {
      final fact = await after(() {
        triage.push(const TriageProgress({'pending': 1},
            parkedReason: 'model_unavailable'));
        triage.push(const TriageProgress({'pending': 0}));
      });

      expect(fact?.reason, isNull);
      expect(fact?.waiting, 0);
    });
  });

  group('the rail', () {
    late BondDatabase db;
    late MessageStore store;
    late _FeedTriage triage;
    late _FeedWorkers workers;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
      triage = _FeedTriage(store);
      workers = _FeedWorkers(store);
    });

    tearDown(() async {
      await triage.dispose();
      await workers.dispose();
      await db.close();
    });

    /// The scope's container, for the one thing a test has to set that no
    /// override can: the processing switch, which is state rather than wiring.
    ProviderContainer scopeOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byType(InboxScreen)),
          listen: false,
        );

    /// The assembled screen, with the triage queue replaced by a feed and the
    /// placement set by hand.
    Future<void> pumpRail(
      WidgetTester tester, {
      required ModelPlacement placement,
      bool processing = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final client = MockClient((_) async => http.Response('{}', 200));
      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt-1';
      tokens.values['granted_scopes'] = _readGrant;
      final auth = GraphAuth(httpClient: client, store: tokens);
      await store.setPref(backendModeKey, backendModeSdk);
      if (placement == ModelPlacement.box) {
        await store.setPref(modelPlacementKey, ModelPlacement.box.name);
      }
      final prefs = await AppPrefsNotifier.read(store);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          initialSectionProvider.overrideWithValue(RailSection.home),
          initialAppPrefsProvider.overrideWithValue(prefs),
          graphAuthProvider.overrideWithValue(auth),
          syncServiceProvider.overrideWithValue(_FakeSync()),
          triageQueueProvider.overrideWithValue(triage),
          aiWorkersProvider.overrideWithValue(workers),
          appPrefsProvider.overrideWith(
            (ref) => AppPrefsNotifier(
              MessageStore(db),
              initial: prefs,
              tokens: MemoryTokenStore(),
            ),
          ),
        ],
        child: const MaterialApp(home: InboxScreen()),
      ));
      // The switch is OFF at every launch and its branch outranks every park,
      // which is the point of the last case in this group. Every other case
      // here is about a pipeline somebody is actually running.
      if (processing) {
        scopeOf(tester).read(processingProvider.notifier).set(true);
        await tester.pump();
      }
      // Three bare pumps: this screen owns a sixty-second periodic timer and
      // a settle would never come back.
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    Future<void> feed(WidgetTester tester, TriageProgress value) async {
      triage.push(value);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('renders the box sentence on the box placement',
        (tester) async {
      await pumpRail(tester, placement: ModelPlacement.box);

      await feed(
        tester,
        const TriageProgress({'pending': 3},
            parkedReason: 'model_unavailable'),
      );

      expect(
        find.text('GPU box unreachable · 3 waiting · retrying each minute'),
        findsOneWidget,
      );
    });

    testWidgets('renders the local sentence on this Mac', (tester) async {
      await pumpRail(tester, placement: ModelPlacement.local);

      await feed(
        tester,
        const TriageProgress({'pending': 3},
            parkedReason: 'model_unavailable'),
      );

      expect(
        find.text('Model server unreachable · 3 waiting · retrying each minute'),
        findsOneWidget,
      );
      expect(find.textContaining('GPU box'), findsNothing);
    });

    testWidgets('renders the refused-key sentence', (tester) async {
      await pumpRail(tester, placement: ModelPlacement.box);

      await feed(
        tester,
        const TriageProgress({'pending': 2}, parkedReason: 'unauthorized'),
      );

      expect(
        find.text('GPU box refused the access key · 2 waiting'),
        findsOneWidget,
      );
    });

    testWidgets('says nothing new when the reason is null or session',
        (tester) async {
      await pumpRail(tester, placement: ModelPlacement.box);

      await feed(tester, const TriageProgress({'pending': 4}));
      expect(find.text('Triaging 4 remaining…'), findsOneWidget);
      expect(find.textContaining('GPU box'), findsNothing);

      await feed(
        tester,
        const TriageProgress({'pending': 4}, parkedReason: 'session'),
      );
      expect(find.text('Triaging 4 remaining…'), findsOneWidget);
      expect(find.textContaining('GPU box'), findsNothing);
    });

    testWidgets('processing being off outranks a parked box', (tester) async {
      await pumpRail(
        tester,
        placement: ModelPlacement.box,
        processing: false,
      );

      await feed(
        tester,
        const TriageProgress({'pending': 3},
            parkedReason: 'model_unavailable'),
      );

      expect(find.text('Processing is off · 3 waiting'), findsOneWidget);
      expect(find.textContaining('GPU box'), findsNothing);
    });

    testWidgets('an empty queue says nothing at all', (tester) async {
      await pumpRail(tester, placement: ModelPlacement.box);

      await feed(
        tester,
        const TriageProgress({'triaged': 9}, parkedReason: 'model_unavailable'),
      );

      // Nothing waiting anywhere is no news, whatever the last park was about.
      expect(find.textContaining('waiting'), findsNothing);
      expect(find.textContaining('Triaging'), findsNothing);
    });

    testWidgets('a parked worker backlog speaks even with triage empty',
        (tester) async {
      // The gate used to be the TRIAGE count alone, so a drafts lane parked
      // against a dead box with nothing left to triage rendered nothing at
      // all — the one case a person most needs told about, silent.
      await pumpRail(tester, placement: ModelPlacement.box);

      await feed(tester, const TriageProgress({'triaged': 9}));
      expect(find.textContaining('waiting'), findsNothing);

      workers.push(const WorkProgress('draft', {'pending': 3},
          parkedReason: 'model_unavailable'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('GPU box unreachable · 3 waiting · retrying each minute'),
        findsOneWidget,
      );
    });
  });
}
