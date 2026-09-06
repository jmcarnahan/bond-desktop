import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_people_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// The directory over MCP, with only the wire faked.
///
/// Two things are pinned here and neither is the happy path. The first is that
/// EVERY `error` this tool can answer with becomes an exception: the shared
/// `_call` special-cases only `not_connected`, so an unmapped error would
/// arrive as a result with no `people` key and read to the caller as "nobody
/// matched" — a directory that is refusing the request would look like an
/// empty organization. The second is which of those errors is permanent, since
/// that is the one bit the recipients field remembers.

/// A scripted client. Duplicated per test file on purpose — a shared fake is a
/// file that can break tests it is not in.
class _FakeMcp implements BondMcpClient {
  /// Per tool: the replies to give, in order. A Map is returned, anything else
  /// is thrown. The last entry is sticky.
  final Map<String, List<Object>> scripted;

  final List<({String tool, Map<String, Object?> args})> calls = [];
  int closes = 0;

  _FakeMcp([this.scripted = const {}]);

  Map<String, Object?> argsFor(String tool) =>
      calls.firstWhere((c) => c.tool == tool).args;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args));
    final queue = scripted[name];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> close() async => closes++;
}

Map<String, dynamic> _people(List<Object> people) => {'people': people};

void main() {
  group('the search', () {
    test('sends the trimmed query and the cap', () async {
      final mcp = _FakeMcp({'search_people_json': [_people(const [])]});

      await McpPeopleBackend(mcp).searchPeople('  sarah  ', top: 5);

      expect(mcp.argsFor('search_people_json'), {'query': 'sarah', 'top': 5});
    });

    test('clamps a top the server would refuse', () async {
      final mcp = _FakeMcp({'search_people_json': [_people(const [])]});

      await McpPeopleBackend(mcp).searchPeople('sarah', top: 500);

      expect(mcp.argsFor('search_people_json')['top'], 50);
    });

    test('makes no call at all for a blank query', () async {
      // The field asks on every keystroke, including the one that empties it.
      final mcp = _FakeMcp();

      expect(await McpPeopleBackend(mcp).searchPeople('   '), isEmpty);
      expect(mcp.calls, isEmpty);
    });

    test('maps the wire onto the model the Graph twin also produces', () async {
      final people = await McpPeopleBackend(
        _FakeMcp({
          'search_people_json': [
            _people(const [
              {
                'id': 'u1',
                'display_name': 'Sarah Whitfield',
                'mail': 'sarah@x.com',
                'user_principal_name': 'sarah@x.onmicrosoft.com',
                'job_title': 'General Counsel',
              },
            ]),
          ],
        }),
      ).searchPeople('sarah');

      expect(people, hasLength(1));
      expect(people.single.id, 'u1');
      expect(people.single.displayName, 'Sarah Whitfield');
      expect(people.single.mail, 'sarah@x.com');
      expect(people.single.userPrincipalName, 'sarah@x.onmicrosoft.com');
      expect(people.single.jobTitle, 'General Counsel');
      expect(people.single.hasGraphId, isTrue);
    });

    test('drops an entry nothing could be done with', () async {
      // No id means no chat and no chip key; no name and no address means an
      // empty row. Neither is worth putting in front of somebody.
      final people = await McpPeopleBackend(
        _FakeMcp({
          'search_people_json': [
            _people(const [
              {'display_name': 'No id here'},
              {'id': 'u2'},
              {'id': 'u3', 'display_name': 'Ravi Patel'},
              'not a map',
            ]),
          ],
        }),
      ).searchPeople('a');

      expect([for (final p in people) p.id], ['u3']);
    });
  });

  group('failures', () {
    test('a missing scope is permanent, and says so', () async {
      // The one answer the field remembers: no retry can change it until
      // somebody consents and the app reconnects.
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [
              {'error': 'directory_scope_missing'},
            ],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isTrue)),
      );
    });

    test('any other error is a bad moment, not a verdict', () async {
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [
              {'error': 'something_else'},
            ],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isFalse)
            .having((e) => e.message, 'message', contains('something_else'))),
      );
    });

    test('a throttled Graph call is one too', () async {
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [
              const McpToolException('Graph API error 429 (TooManyRequests)'),
            ],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isFalse)),
      );
    });

    test('and so is a transport that fell over', () async {
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [
              const McpTransportException('connection closed'),
            ],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isFalse)),
      );
    });

    test('a disconnected server routes to sign-in instead', () async {
      // Not a directory problem at all: the session is over, and this is the
      // exception the app routes on.
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [
              {'error': 'not_connected'},
            ],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<ReconsentRequired>()),
      );
    });

    test('an auth failure reaches the caller as itself', () async {
      await expectLater(
        McpPeopleBackend(
          _FakeMcp({
            'search_people_json': [const NotSignedIn()],
          }),
        ).searchPeople('sarah'),
        throwsA(isA<NotSignedIn>()),
      );
    });

    test('an unscripted tool answers with nothing, and nothing is empty',
        () async {
      // The fake returns `{}` for a tool nobody scripted. No `error` and no
      // `people` is a server that answered with an empty directory, which is
      // the one shape that is NOT a failure.
      expect(await McpPeopleBackend(_FakeMcp()).searchPeople('sarah'), isEmpty);
    });
  });
}
