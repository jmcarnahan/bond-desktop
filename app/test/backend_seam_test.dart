import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The seam a second backend plugs into.
///
/// Every one of these is a property of the WIRING rather than of any class, and
/// none of the behaviour tests would notice if it broke: the app would keep
/// working perfectly against Graph while quietly having no seam left. What is
/// pinned here is that the Graph classes satisfy the interfaces, and that the
/// three providers the app consumes are typed to those interfaces — so swapping
/// an implementation in is a change to three provider bodies and nothing else.

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
  final client = MockClient((request) async => http.Response('{}', 200));

  group('the Graph classes are implementations, not the interface', () {
    test('GraphAuth is an AuthSession', () {
      expect(
        GraphAuth(httpClient: client, store: _Tokens()),
        isA<AuthSession>(),
      );
    });

    test('GraphMail is a MailBackend', () {
      final auth = GraphAuth(httpClient: client, store: _Tokens());
      expect(GraphMail(auth, httpClient: client), isA<MailBackend>());
    });

    test('GraphTeams is a TeamsBackend', () {
      final auth = GraphAuth(httpClient: client, store: _Tokens());
      expect(GraphTeams(auth, httpClient: client), isA<TeamsBackend>());
    });
  });

  group('the providers the app consumes', () {
    test('are typed to the interfaces and default to the Graph backends', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // The static types are the point: each of these variables is declared as
      // the interface, so a provider that went back to a concrete type would
      // stop compiling here rather than silently reclose the seam.
      final AuthSession auth = container.read(authSessionProvider);
      final MailBackend mail = container.read(mailBackendProvider);
      final TeamsBackend teams = container.read(teamsBackendProvider);

      expect(auth, isA<GraphAuth>());
      expect(mail, isA<GraphMail>());
      expect(teams, isA<GraphTeams>());
    });

    test('still follow an override of the concrete session provider', () {
      // graphAuthProvider stays public and concrete precisely so a test can
      // hand the whole app one faked session; the interface providers are
      // built from it rather than from a GraphAuth of their own, which is what
      // makes that single override reach all three.
      final shared = GraphAuth(httpClient: client, store: _Tokens());
      final container = ProviderContainer(
        overrides: [graphAuthProvider.overrideWithValue(shared)],
      );
      addTearDown(container.dispose);

      expect(identical(container.read(authSessionProvider), shared), isTrue);
      // These build at all only because the override supplied their session.
      expect(container.read(mailBackendProvider), isA<GraphMail>());
      expect(container.read(teamsBackendProvider), isA<GraphTeams>());
    });
  });
}
