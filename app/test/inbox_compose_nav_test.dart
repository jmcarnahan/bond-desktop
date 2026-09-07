import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/new_message_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/chips.dart' show BondFilterPillRow;
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Compose as a PANE inside the inbox.
///
/// The same bag of booleans Settings lives in, and so the same wiring touches:
/// the rail button that sets the flag, the six selectors that clear it, the
/// rail highlight that has to go quiet, and the `_main()` ladder that puts
/// compose first. None of it is visible from the screen's own tests, which
/// pump the widget alone.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _FakeMail implements MailBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// `myUserId` throws on purpose: `RecipientSearch` swallows it, and a fake
/// that answered would be pretending this account has a Teams grant it does
/// not.
class _FakeTeams implements TeamsBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakePeople implements PeopleBackend {
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async =>
      const [];
}

class _FakeAuth implements AuthSession {
  @override
  Future<bool> get isSignedIn async => true;

  @override
  Future<bool> get needsReconsent async => false;

  @override
  Future<bool> hasScope(String bareScope) async => false;

  @override
  Future<AccountInfo?> get storedAccount async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread(String key, String subject) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Sarah Whitfield',
      'received_at': '2026-09-05T09:00:00Z',
      'body_text': 'body',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'state': 'waiting',
      'last_message_at': '2026-09-05T09:00:00Z',
    });
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        mailBackendProvider.overrideWithValue(_FakeMail()),
        teamsBackendProvider.overrideWithValue(_FakeTeams()),
        peopleBackendProvider.overrideWithValue(_FakePeople()),
        authSessionProvider.overrideWithValue(_FakeAuth()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );
  }

  Future<void> openCompose(WidgetTester tester) async {
    await tester.tap(find.byTooltip('New message'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the rail button opens compose in the main pane', (tester) async {
    await pumpInbox(tester);
    expect(find.byType(NewMessageScreen), findsNothing);

    await openCompose(tester);

    expect(find.byType(NewMessageScreen), findsOneWidget);
  });

  testWidgets('Back returns to the section underneath', (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openCompose(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsNothing);
    expect(find.text('NEEDS YOU'), findsWidgets);
  });

  testWidgets('the Home link lands on Home', (tester) async {
    await pumpInbox(tester);
    await openCompose(tester);

    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
  });

  testWidgets('the rail highlights no section while compose is open',
      (tester) async {
    await pumpInbox(tester);
    expect(
      tester.widget<AppRail>(find.byType(AppRail)).selectedSection,
      RailSection.needsYou,
    );

    await openCompose(tester);

    expect(
      tester.widget<AppRail>(find.byType(AppRail)).selectedSection,
      isNull,
      reason: 'the pane is not showing a section, so nothing is current',
    );
  });

  testWidgets('an OpenComposeIntent opens it, on the channel it names',
      (tester) async {
    await pumpInbox(tester);

    container.read(navIntentProvider.notifier).request(OpenComposeIntent());
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsOneWidget);
    expect(
      tester
          .widget<BondFilterPillRow<RecipientChannel>>(
            find.byKey(const Key('compose-channel')),
          )
          .selected,
      RecipientChannel.mail,
    );

    container
        .read(navIntentProvider.notifier)
        .request(OpenComposeIntent(channel: RecipientChannel.teams));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<BondFilterPillRow<RecipientChannel>>(
            find.byKey(const Key('compose-channel')),
          )
          .selected,
      RecipientChannel.teams,
    );
  });

  testWidgets('Settings replaces compose rather than opening behind it',
      (tester) async {
    await pumpInbox(tester);
    await openCompose(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets("a notification's OpenThreadIntent closes compose",
      (tester) async {
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openCompose(tester);
    expect(find.byType(NewMessageScreen), findsOneWidget);

    container
        .read(navIntentProvider.notifier)
        .request(OpenThreadIntent('email', 'c1'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
  });
}
