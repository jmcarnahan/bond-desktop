// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// A message that lands DURING a sync reaches the open transcript on the same
/// tick.
///
/// The transcript is a one-shot read, not a watch — nothing re-reads it
/// because a row appeared. The screen's poll used to start that read beside
/// the sync rather than after it, so a message the sync had just stored sat
/// invisible until the next tick a minute later. The Sent Items copy that
/// takes a local echo's place is exactly such a message, which is why this is
/// pinned at the screen and not at the notifier.

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

/// A mail sync that writes one message into the open thread, the way a real
/// drain's page transaction does — after [drainTime] on the wire.
///
/// The delay is the whole instrument. A pull takes time; a transcript read
/// started BESIDE it finishes long before the row lands and is never repeated,
/// which is precisely the bug. Without a delay here both orderings pass.
class _WritingSync implements MailSync {
  static const Duration drainTime = Duration(milliseconds: 400);

  final MessageStore store;
  int syncCalls = 0;

  /// Armed by the test just before it advances the poll timer, so the row
  /// lands on a KNOWN tick — the launch sync runs before the thread is even
  /// open, and a row written there would prove nothing about ordering.
  bool writeNext = false;

  _WritingSync(this.store);

  @override
  Future<void> syncNow() async {
    syncCalls++;
    if (!writeNext) return;
    writeNext = false;
    await Future<void>.delayed(drainTime);
    await store.upsertMessage({
      'source_message_id': 'sent-1',
      'internet_message_id': '<abc@bond.local>',
      'conversation_key': 'c1',
      'direction': 'outbound',
      'subject': 'Homepage copy',
      'received_at': _at(12),
      'body_text': 'the reply the sync brought in',
      'body_preview': 'the reply the sync brought in',
      'is_read': 1,
      'triage_status': 'skipped',
      'gate_reason': 'outbound',
    });
    await store.recomputeConversationCounts('email', 'c1');
  }

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _SilentTeams extends TeamsSync {
  _SilentTeams(super.teams, super.store);

  @override
  Future<void> syncNow() async {}
}

const String _scopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

/// Yesterday, carrying the hour so the fixtures' ordering stays readable.
/// Relative because absolute dates rot out of the app's recency windows.
String _at(int hour) {
  final day = DateTime.now().toUtc().subtract(const Duration(days: 1));
  return DateTime.utc(day.year, day.month, day.day, hour).toIso8601String();
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _WritingSync sync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = _WritingSync(store);
  });

  tearDown(() => db.close());

  Future<void> seedMail() async {
    await store.upsertMessage({
      'source_message_id': 'in-1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': _at(9),
      'body_text': 'the message that was already there',
    });
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': _at(9),
      'last_inbound_at': _at(9),
    });
    await store.recomputeConversationCounts('email', 'c1');
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _scopes;
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The SDK backend, said in the store because that is where the app reads
    // it — the MCP default would ask a server that is not there.
    await store.setPref(backendModeKey, backendModeSdk);
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(sync),
        teamsSyncProvider
            .overrideWithValue(_SilentTeams(GraphTeams(auth, httpClient: client), store)),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Pumps rather than a settle: this screen owns a sixty-second periodic
    // timer, and an unbounded settle would never come back.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets('a message stored by the tick\'s own sync is in the transcript '
      'on that tick', (tester) async {
    await seedMail();
    await pumpScreen(tester);

    await tester.tap(find.descendant(
      of: find.byType(ConversationListPane),
      matching: find.text('Homepage copy').first,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text('the message that was already there'), findsOneWidget);
    expect(find.text('the reply the sync brought in'), findsNothing,
        reason: 'the sync has not run since the thread was opened');

    // One turn of the poll timer, then past the drain, then the reads behind
    // it. The row lands mid-tick, which is the case that matters: a read
    // started beside the sync would already have finished by now.
    sync.writeNext = true;
    await tester.pump(const Duration(seconds: 61));
    await tester.pump(_WritingSync.drainTime * 2);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(sync.syncCalls, greaterThan(1), reason: 'the timer did fire');
    expect(find.text('the reply the sync brought in'), findsOneWidget);
  });
}
