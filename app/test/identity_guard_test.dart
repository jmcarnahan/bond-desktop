import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/sign_in_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/identity_guard.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// One database, one identity — enforced rather than ritualized.
///
/// The rule was always "two Microsoft accounts never mix in one local
/// database", and until now the only thing enforcing it was that sign-out
/// happened to wipe. Anything that skipped sign-out — a crash, a session that
/// expired, a server switched in Settings — let the next person sign in on top
/// of somebody else's mail. What is pinned here is that the guard wipes on a
/// change of identity, that it wipes on nothing else, and that a wipe costs
/// mail rather than settings.
///
/// The stubs are deliberately duplicated from the other screen tests rather
/// than shared, so no file can break another by editing it.
class _FakeSession implements AuthSession {
  _FakeSession(this.account, {this.reconsent = false});

  final AccountInfo account;
  final bool reconsent;
  int signIns = 0;

  @override
  Future<bool> get isSignedIn async => signIns > 0;

  @override
  Future<bool> get needsReconsent async => reconsent;

  @override
  Future<bool> hasScope(String bareScope) async => true;

  @override
  Future<AccountInfo?> get storedAccount async => account;

  @override
  Future<AccountInfo> signIn() async {
    signIns++;
    return account;
  }

  @override
  Future<void> signOut() async {}
}

/// The wire, scripted. The last reply is sticky.
class _FakeMcp implements BondMcpClient {
  _FakeMcp(this.replies);

  final List<Map<String, dynamic>> replies;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      replies.length == 1 ? replies.first : replies.removeAt(0);

  @override
  Future<void> close() async {}
}

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

void main() {
  late Database db;
  late MessageStore store;
  late IdentityGuard guard;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    guard = IdentityGuard(store);
  });

  tearDown(() => db.close());

  void seedMail(String id) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': 'c1',
      'direction': 'inbound',
      'from_name': 'Eric Vance',
      'from_address': 'eric@harborline.com',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The appraisal is in.',
    });
  }

  int mailCount() =>
      store.db.select('SELECT COUNT(*) AS n FROM messages').first['n'] as int;

  group('IdentityGuard.adopt', () {
    test('an identity-less account neither wipes nor claims', () async {
      // The local-session placeholder and a workspace sign-in with no
      // Microsoft account connected both arrive with neither a mail address
      // nor a UPN. They have read no mail, so there is nothing of theirs to
      // protect — and claiming the database in their name would hand it to a
      // label instead of a person.
      seedMail('m1');

      final wiped =
          await guard.adopt(const AccountInfo(displayName: 'Local session'));

      expect(wiped, isFalse);
      expect(mailCount(), 1);
      expect(store.getPref(dbOwnerKey), isNull);
    });

    test('the first identity claims an unowned database, silently', () async {
      seedMail('m1');

      final wiped = await guard.adopt(const AccountInfo(
        displayName: 'Ada Lovelace',
        mail: 'ada@example.test',
      ));

      expect(wiped, isFalse);
      expect(mailCount(), 1, reason: 'nothing to protect it from');
      expect(store.getPref(dbOwnerKey), 'ada@example.test');
    });

    test('the same identity in another case is the same person', () async {
      // Microsoft hands the address back in whatever case it was typed, and a
      // user must not lose their mailbox to a capital letter.
      store.setPref(dbOwnerKey, 'ada@example.test');
      seedMail('m1');

      final wiped = await guard.adopt(const AccountInfo(
        displayName: 'Ada Lovelace',
        mail: '  Ada@Example.Test ',
      ));

      expect(wiped, isFalse);
      expect(mailCount(), 1);
    });

    test('the UPN stands in when the tenant sets no mail address', () async {
      store.setPref(dbOwnerKey, 'ada@corp.example.test');
      seedMail('m1');

      final wiped = await guard.adopt(const AccountInfo(
        displayName: 'Ada Lovelace',
        userPrincipalName: 'ada@corp.example.test',
      ));

      expect(wiped, isFalse);
      expect(mailCount(), 1);
    });

    test('a different identity finds the mail gone, and the settings kept',
        () async {
      store.setPref(dbOwnerKey, 'ada@example.test');
      store.setPref(backendModeKey, backendModeSdk);
      store.setPref(aboutMeKey, 'An LO in Denver');
      seedMail('m1');
      store.setDeltaLink('inbox', 'cursor-1');

      final wiped = await guard.adopt(const AccountInfo(
        displayName: 'Grace Hopper',
        mail: 'grace@example.test',
      ));

      expect(wiped, isTrue);
      expect(mailCount(), 0);
      expect(store.getDeltaLink('inbox', source: 'email'), isNull,
          reason: "resuming Ada's sync position against Grace's mailbox is "
              'the other half of the same bug');
      expect(store.getPref(dbOwnerKey), 'grace@example.test');
      // A wipe is about mail isolation, not about the machine's setup: which
      // backend it talks through has to survive, or every account switch is a
      // re-setup.
      expect(store.getPref(backendModeKey), backendModeSdk);
      expect(store.getPref(aboutMeKey), 'An LO in Denver');
    });

    test('an unclaimed database after a sign-out wipe is claimed, not wiped',
        () async {
      // The sign-out path clears db_owner along with the rows (see the wipeAll
      // group in store_test), so the next person to sign in — the same one or
      // not — takes an empty database over rather than wiping an empty one.
      store.setPref(dbOwnerKey, 'ada@example.test');
      seedMail('m1');
      store.wipeAll();
      seedMail('m2');

      final wiped = await guard.adopt(const AccountInfo(
        displayName: 'Grace Hopper',
        mail: 'grace@example.test',
      ));

      expect(wiped, isFalse);
      expect(mailCount(), 1);
      expect(store.getPref(dbOwnerKey), 'grace@example.test');
    });
  });

  group('the sign-in screen adopts before it hands over', () {
    testWidgets('a new identity finds the old mail already gone',
        (tester) async {
      store.setPref(dbOwnerKey, 'ada@example.test');
      seedMail('m1');

      int? mailWhenHandedOver;
      String? ownerWhenHandedOver;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          authSessionProvider.overrideWithValue(_FakeSession(
            const AccountInfo(
              displayName: 'Grace Hopper',
              mail: 'grace@example.test',
            ),
          )),
        ],
        child: MaterialApp(
          home: SignInScreen(onSignedIn: () {
            mailWhenHandedOver = mailCount();
            ownerWhenHandedOver = store.getPref(dbOwnerKey);
          }),
        ),
      ));

      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();

      // Before the handover, not after: the gate swaps in the inbox the
      // moment this fires, and an inbox built over the previous account's
      // rows is exactly the state that must never be reachable.
      expect(mailWhenHandedOver, 0);
      expect(ownerWhenHandedOver, 'grace@example.test');
    });

    testWidgets('the connect step is guarded too', (tester) async {
      // The second door into the inbox. The sign-in that leads here has no
      // Microsoft account behind it, so the guard saw no identity and claimed
      // nothing; the identity arrives only when the connect lands, which is
      // where the rows finally become somebody's.
      store.setPref(dbOwnerKey, 'ada@example.test');
      seedMail('m1');

      final tokens = _Tokens();
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(mcpLocalUrl),
        mcpClient: _FakeMcp([
          {'connected': true, 'scopes': const ['Mail.Read']},
        ]),
        store: tokens,
      );
      tokens.values[auth.accountJsonKey] = jsonEncode(const AccountInfo(
        displayName: 'Grace Hopper',
        mail: 'grace@example.test',
      ).toJson());

      int? mailWhenHandedOver;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          // Reconsent on the fake session is what routes the screen to the
          // connect step; the REAL session under the stack is what the step
          // itself re-probes and reads the account off.
          authSessionProvider.overrideWithValue(
            _FakeSession(
              const AccountInfo(displayName: 'Bond workspace'),
              reconsent: true,
            ),
          ),
          mcpStackProvider.overrideWithValue((auth: auth, client: _FakeMcp([
            {'connected': true},
          ]))),
        ],
        child: MaterialApp(
          home: SignInScreen(onSignedIn: () => mailWhenHandedOver = mailCount()),
        ),
      ));

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(mailCount(), 1, reason: 'a nameless sign-in wipes nothing');

      await tester.tap(find.text("I've connected — continue"));
      await tester.pumpAndSettle();

      expect(mailWhenHandedOver, 0);
      expect(store.getPref(dbOwnerKey), 'grace@example.test');
    });
  });
}
