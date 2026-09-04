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
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The whole screen, with sqlite real and every socket faked.
///
/// Two things are pinned here that cannot be pinned anywhere else, because
/// both are properties of the WIRING rather than of any one class:
///
/// - **the sixty-second poll timer never reaches Teams.** Microsoft's terms
///   for the Teams messaging endpoints forbid background polling, and the only
///   place that rule can actually be broken is here, where the timer is
///   created and the refresh button is wired.
/// - **a chat thread's reply surface follows the GRANT.** With
///   `Chat.ReadWrite` it gets the same bar and collapsible composer a mail
///   thread does; without it, a box that could not send would be worse than
///   none, so the pane says where to reply instead. Only the assembled screen
///   knows both the capability and the pane.
/// - **the reply surface a mail thread DOES get**: the stored short replies
///   reaching the transcript, and the composer staying collapsed until asked
///   for. Both are wiring between the draft row and the pane, which is only
///   assembled here.

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
  int syncCalls = 0;

  @override
  Future<void> syncNow() async => syncCalls++;

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _RecordingTeams extends TeamsSync {
  int calls = 0;

  _RecordingTeams(super.teams, super.store);

  @override
  Future<void> syncNow() async => calls++;
}

const String _coreScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';
const String _withChat = '$_coreScopes https://graph.microsoft.com/Chat.Read';

/// Reading chats and answering them — what the MCP backend's grant carries,
/// and the only grant under which a chat thread offers a reply box.
const String _withChatWrite =
    '$_coreScopes https://graph.microsoft.com/Chat.ReadWrite';

/// Yesterday's date, carrying the fixtures' hour-of-day so their ordering
/// stays readable at the call sites. Relative because absolute dates rot: a
/// literal that was fresh the day it was written aged out of the app's
/// recency windows, and rows the tests reached for stopped being listed.
String _at(int hour) {
  final day = DateTime.now().toUtc().subtract(const Duration(days: 1));
  return DateTime.utc(day.year, day.month, day.day, hour).toIso8601String();
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeSync sync;
  late _RecordingTeams teams;

  /// Every socket the app would have opened. Nothing in this file may move it.
  var httpCalls = 0;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = _FakeSync();
    httpCalls = 0;
  });

  tearDown(() => db.close());

  Future<void> seedChat(
    String key, {
    String subject = 'Sarah Whitfield',
    String body = 'Any word on the CD?',
  }) async {
    await store.upsertMessage({
      'source': 'teams',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'teams:u1',
      'received_at': _at(11),
      'body_text': body,
      'body_preview': 'Any word on the CD?',
      'triage_status': 'skipped',
      'gate_reason': teamsSourceGate,
    });
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
      'state': 'needs_reply',
      'last_message_at': _at(11),
      'last_inbound_at': _at(11),
      'last_message_preview': 'Any word on the CD?',
    });
    await store.recomputeConversationCounts('teams', key);
  }

  Future<void> seedMail(
    String key, {
    String subject = 'Homepage copy',
    String body = 'The homepage copy is in.',
    // Null means 9am yesterday — a default has to be a constant, and the one
    // constant worth writing here is no date at all.
    String? at,
  }) async {
    at ??= _at(9);
    await store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': at,
      'body_text': body,
    });
    await store.upsertConversation({
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': at,
      'last_inbound_at': at,
    });
    await store.recomputeConversationCounts('email', key);
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    String grantedScopes = _withChat,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((request) async {
      httpCalls++;
      return http.Response('{}', 200);
    });
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = grantedScopes;
    final auth = GraphAuth(httpClient: client, store: tokens);
    teams = _RecordingTeams(
      GraphTeams(auth, httpClient: client),
      store,
    );
    // This screen is pumped over a faked GraphAuth, which is the SDK backend —
    // and the app's default is now the MCP one, whose session would answer the
    // scope question by asking a server that is not there. Said in the store
    // because that is where the app reads it, once, at construction.
    await store.setPref(backendModeKey, backendModeSdk);
    // Read here rather than left to load a microtask into the first frame,
    // which is what `main()` does and for the same reason: every backend
    // provider watches the mode, so a stored setting arriving late rebuilds
    // the session — and with it the inbox's read model, which would then sit
    // at its initial state, spinning, with the load that this screen kicks
    // from `initState` having landed on the notifier that was replaced.
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        // Predates Home: this file asserts on a pane the rail's old landing
        // section opened.
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(sync),
        teamsSyncProvider.overrideWithValue(teams),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // The launch refresh is a microtask; two pumps settle it and the loads
    // behind it without advancing the poll timer. A third for the reads
    // themselves, which are round trips through drift now — and pumps rather
    // than a settle, because this screen owns a sixty-second periodic timer
    // and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  group('the poll timer', () {
    testWidgets('refreshes mail and never Teams', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);

      final atLaunch = teams.calls;
      expect(atLaunch, 1, reason: 'opening the app is an app-focus event');
      final mailAtLaunch = sync.syncCalls;

      // Five minutes of the timer.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 61));
      }

      expect(sync.syncCalls, greaterThan(mailAtLaunch),
          reason: 'the timer did fire');
      expect(teams.calls, atLaunch,
          reason: 'Microsoft’s terms forbid polling the Teams messaging '
              'endpoints — only a person may refresh them');
      expect(httpCalls, 0, reason: 'every socket in this test is faked');
    });

    testWidgets('the refresh button does reach Teams', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);
      final before = teams.calls;

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();

      expect(teams.calls, before + 1);
    });
  });

  testWidgets('a chat row opens the chat, even when mail shares its key',
      (tester) async {
    // Both connectors mint conversation keys with no knowledge of each other,
    // so one key can name two threads. The row hands its source to the
    // selection along with the id — without it the screen scans the loaded
    // list for the key alone and opens whichever thread it reaches first,
    // which here is the mail one, because it sorts newest.
    await seedChat('shared', body: 'the chat transcript');
    await seedMail(
      'shared',
      body: 'the mail transcript',
      at: _at(13),
    );
    await pumpScreen(tester);

    await tester.tap(find.descendant(
      of: find.byType(ConversationListPane),
      matching: find.text('💬 Sarah Whitfield'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('the chat transcript'), findsOneWidget);
    expect(find.text('the mail transcript'), findsNothing);
  });

  group('a chat thread', () {
    Future<void> openChat(WidgetTester tester) async {
      await tester.tap(find.text('💬 Sarah Whitfield').first);
      await tester.pump();
      await tester.pump();
      // The capability is a keychain read, and the reply surface waits on it.
      await tester.pump();
    }

    testWidgets('without Chat.ReadWrite says where to reply instead',
        (tester) async {
      // `_withChat` is Chat.Read: this build can see the chat and could not
      // answer it, and the caption is the honest version of that.
      await seedChat('chat-1');
      await pumpScreen(tester);

      await openChat(tester);

      expect(find.byType(Composer), findsNothing,
          reason: 'a reply box that cannot send is worse than none');
      expect(find.text('Reply…'), findsNothing);
      expect(find.text('Reply in Microsoft Teams'), findsOneWidget);
    });

    testWidgets('with it, the chat gets the same reply surface mail does',
        (tester) async {
      // Nothing drafted for this one yet, so the bar is the `Reply…`
      // affordance alone, and it opens the same collapsed composer a mail
      // thread's does.
      await seedChat('chat-1');
      await pumpScreen(tester, grantedScopes: _withChatWrite);

      await openChat(tester);

      expect(find.text('Reply in Microsoft Teams'), findsNothing);
      expect(find.byType(Composer), findsNothing, reason: 'collapsed by default');

      await tester.tap(find.text('Reply…'));
      await tester.pump();

      expect(find.byType(Composer), findsOneWidget);
      // A chat drafts through the same queue and the same system prompt a mail
      // does — only the channel's style rules differ, and those ride in the
      // user message — so the button is reachable on either kind of thread.
      expect(find.text('Draft reply'), findsOneWidget);
    });

    testWidgets('and its stored options reach the transcript as cards',
        (tester) async {
      // The other half of the same parity: a chat's draft row carries short
      // replies now, so the bar draws them exactly as a mail thread's does.
      await seedChat('chat-1');
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'chat-1',
        replyToMessageId: 'chat-1-m1',
        body: 'Sending it over this afternoon.',
        optionsJson: '[{"stance":"Confirm today","body":"On its way today."},'
            '{"stance":"Ask for a deadline","body":"When do you need it?"}]',
      );
      await pumpScreen(tester, grantedScopes: _withChatWrite);

      await openChat(tester);

      expect(find.text('Confirm today'), findsOneWidget);
      expect(find.text('Ask for a deadline'), findsOneWidget);
    });

    testWidgets('a mail thread reaches one through Reply…', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);

      await tester.tap(find.text('Eric Vance').first);
      await tester.pump();
      await tester.pump();

      // Collapsed is the DEFAULT: a thread opens as something to read.
      expect(find.byType(Composer), findsNothing);
      expect(find.text('Reply in Microsoft Teams'), findsNothing);

      await tester.tap(find.text('Reply…'));
      await tester.pump();

      expect(find.byType(Composer), findsOneWidget);
    });

    testWidgets('and the reply window closes again on its ×', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);

      await tester.tap(find.text('Eric Vance').first);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Reply…'));
      await tester.pump();

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();

      expect(find.byType(Composer), findsNothing);
      expect(find.text('Reply…'), findsOneWidget);
    });
  });

  group('the quick replies', () {
    Future<void> seedOptions(String key) async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: key,
        replyToMessageId: '$key-m1',
        body: 'Thanks Eric — the copy looks good, I will review it today.',
        optionsJson: '[{"stance":"Confirm receipt","body":"Got it, thanks."},'
            '{"stance":"Ask for a deadline","body":"When do you need this by?"}]',
      );
    }

    Future<void> openThread(WidgetTester tester) async {
      await tester.tap(find.text('Eric Vance').first);
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the stored options reach the end of the transcript',
        (tester) async {
      await seedMail('c1');
      await seedOptions('c1');
      await pumpScreen(tester);

      await openThread(tester);

      expect(find.text('Confirm receipt'), findsOneWidget);
      expect(find.text('Ask for a deadline'), findsOneWidget);
    });

    testWidgets('without a send grant a card opens the composer instead',
        (tester) async {
      // The honest version of the gesture: nothing in this build could put
      // that mail in front of anyone, so nothing pretends to.
      await seedMail('c1');
      await seedOptions('c1');
      await pumpScreen(tester);
      await openThread(tester);

      await tester.tap(find.text('Confirm receipt'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(Composer), findsOneWidget);
      expect(find.widgetWithText(Composer, 'Got it, thanks.'), findsOneWidget);
    });

    testWidgets('after the user\'s OWN last message there is nothing to answer',
        (tester) async {
      await seedMail('c1');
      await seedOptions('c1');
      await store.upsertMessage({
        'source_message_id': 'c1-m2',
        'conversation_key': 'c1',
        'direction': 'outbound',
        'received_at': _at(10),
        'body_text': 'Already answered this one.',
      });
      await pumpScreen(tester);

      await openThread(tester);

      expect(find.text('Confirm receipt'), findsNothing);
      expect(find.text('Reply…'), findsNothing);
    });
  });

  group('the source filter', () {
    testWidgets('narrows the whole screen, rail included', (tester) async {
      await seedMail('c1');
      await seedChat('chat-1');
      await pumpScreen(tester);

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);

      await tester.tap(find.byKey(SourceFilterBar.teamsKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsNothing);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);

      await tester.tap(find.byKey(SourceFilterBar.mailKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsNothing);

      await tester.tap(find.byKey(SourceFilterBar.allKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);
    });

    testWidgets('without Chat.Read the Teams pill is dead rather than gone',
        (tester) async {
      await seedMail('c1');
      await pumpScreen(tester, grantedScopes: _coreScopes);
      // The scope is a keychain read behind a FutureBuilder.
      await tester.pump();

      final pill = tester.widget<Widget>(find.byKey(SourceFilterBar.teamsKey));
      expect(pill, isNotNull);
      expect(
        find.byTooltip(SourceFilterBar.unavailableTooltip),
        findsOneWidget,
      );
    });
  });

  group('the freshness caption', () {
    testWidgets('says nothing before the first pull, and how old after',
        (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);
      expect(find.textContaining('Teams updated'), findsNothing);

      await store.setSyncedAt(
        TeamsSync.folder,
        DateTime.now().toUtc().subtract(const Duration(minutes: 4))
            .toIso8601String(),
        source: TeamsSync.source,
      );
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Teams updated 4m ago'), findsOneWidget);
    });
  });

  /// A storyline holding one mail thread and one chat, and the reply bar under
  /// it. The source the composer is routed with is not directly visible — but
  /// the CAPABILITY is, and under `Chat.ReadWrite` alone the two sources sit on
  /// different rungs: a chat can send, a mail thread can only be copied. So the
  /// rung the box reports is the proof of which conversation it is answering.
  group('a mixed storyline replies to the episode the user picked', () {
    Future<void> openMixedStoryline(
      WidgetTester tester, {
      String grantedScopes = _withChatWrite,
    }) async {
      // The chat is the newer of the two, so it is the default target.
      await seedMail('c1');
      await seedChat('chat-1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'teams', 'chat-1',
          addedBy: 'auto');

      await pumpScreen(tester, grantedScopes: grantedScopes);
      await tester.tap(find.text('Website redesign'));
      // One for the tap, then the timeline read, then the capability read the
      // reply surface waits on.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // A storyline's reply window is collapsed by default, the way a thread's
      // is, so every test below has to ask for it before there is a target to
      // pick or a box to type into.
      await tester.tap(find.text('Reply…'));
      await tester.pump();
      await tester.pump();
    }

    /// The reply targets by name, and which one the box is pointed at. The
    /// source filter bar is built from the same pill, so these are read by
    /// label rather than counted.
    Map<String, bool> replyPills(WidgetTester tester) => {
          for (final pill
              in tester.widgetList<BondFilterPill>(find.byType(BondFilterPill)))
            pill.label: pill.selected,
        };

    /// By the pill and not by its text: the list pane names the same threads.
    Finder pillNamed(String label) =>
        find.byWidgetPredicate((w) => w is BondFilterPill && w.label == label);

    testWidgets('a chat is offered as a target and drafted down the chat path',
        (tester) async {
      await openMixedStoryline(tester);

      // Both episodes are on offer, which is the change: a chat used to be
      // filtered out of the list entirely. The newest is the default target,
      // and here that is the chat.
      final labels = tester
          .widgetList<BondFilterPill>(find.byType(BondFilterPill))
          .map((pill) => pill.label)
          .where((label) =>
              label == 'Homepage copy' || label == 'Sarah Whitfield')
          .toList();
      expect(labels, ['Homepage copy', 'Sarah Whitfield']);
      expect(replyPills(tester)['Sarah Whitfield'], isTrue);
      // A chat message has no subject of its own, so the pill is named by who
      // is on it rather than by a blank.
      expect(find.text('Sarah Whitfield'), findsWidgets);
      expect(find.text('(no subject)'), findsNothing);

      final composer = tester.widget<Composer>(find.byType(Composer));
      expect(composer.capability, SendCapability.send,
          reason: 'only the chat can send under this grant — a composer '
              'routed at the mail thread would report copy-only');
    });

    testWidgets('picking the mail thread routes the box back to mail',
        (tester) async {
      await openMixedStoryline(tester);

      await tester.tap(pillNamed('Homepage copy'));
      await tester.pump();
      await tester.pump();

      expect(replyPills(tester)['Homepage copy'], isTrue);
      final composer = tester.widget<Composer>(find.byType(Composer));
      expect(composer.capability, SendCapability.copyOnly,
          reason: 'this grant carries no Mail.Send and no Mail.ReadWrite');
    });

    testWidgets(
        'without Chat.ReadWrite the chat says where to reply, and the mail '
        'thread is still one pick away', (tester) async {
      await openMixedStoryline(tester, grantedScopes: _withChat);

      // The same ladder the thread pane applies: a box that could not send is
      // worse than none, in a storyline as much as in a thread.
      expect(find.byType(Composer), findsNothing);
      expect(find.text('Reply in Microsoft Teams'), findsOneWidget);

      // The pills stay put above the caption, because they are the way to the
      // episode this build CAN answer. Hiding them with the box would strand a
      // storyline whose newest episode happens to be a chat.
      await tester.tap(pillNamed('Homepage copy'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Reply in Microsoft Teams'), findsNothing);
      expect(find.byType(Composer), findsOneWidget);
    });
  });
}
