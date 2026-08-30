import 'dart:convert';

import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// What [McpAuthSession] answers about an existing session: what it may do,
/// whether the platform still has a connection, and what sign-out removes.
///
/// The stubs here are deliberately duplicated from the other MCP tests rather
/// than shared, so no file can break another by editing it.
class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  /// Sign-out must never wipe the store: the direct-Graph session keeps its
  /// own keys in here and would go down with it.
  bool deleteAllCalled = false;

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
  Future<void> deleteAll() async {
    deleteAllCalled = true;
    values.clear();
  }
}

/// A scripted MCP client: each tool name maps to a payload to return or an
/// object to throw, and every call is counted.
class _FakeBondMcpClient implements BondMcpClient {
  final Map<String, Object> scripted;
  final Map<String, int> callCounts = {};

  _FakeBondMcpClient(this.scripted);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    callCounts[name] = (callCounts[name] ?? 0) + 1;
    final reply = scripted[name];
    if (reply is Map<String, dynamic>) return reply;
    if (reply == null) {
      throw McpTransportException('no script for "$name"');
    }
    throw reply;
  }

  @override
  Future<void> close() async {}
}

final Uri _mcpUrl = Uri.parse('https://mcp.example.test/mcp');

McpAuthSession _session(BondMcpClient client, TokenStore store) =>
    McpAuthSession(mcpUrl: _mcpUrl, mcpClient: client, store: store);

void main() {
  group('resourceMetadataUrlFrom', () {
    test('reads the metadata URL out of the challenge', () {
      // The path carries the resource as a SUFFIX, which is exactly why this
      // is parsed rather than constructed from the origin.
      final url = resourceMetadataUrlFrom(
        'Bearer resource_metadata='
        '"https://mcp.example.test/.well-known/oauth-protected-resource/mcp"',
      );
      expect(
        url.toString(),
        'https://mcp.example.test/.well-known/oauth-protected-resource/mcp',
      );
    });

    test('tolerates other challenge parameters either side of it', () {
      final url = resourceMetadataUrlFrom(
        'Bearer error="invalid_token", '
        'resource_metadata="https://h.test/.well-known/x/mcp", '
        'error_description="expired"',
      );
      expect(url.toString(), 'https://h.test/.well-known/x/mcp');
    });

    test('tolerates an unquoted value', () {
      final url =
          resourceMetadataUrlFrom('Bearer resource_metadata=https://h.test/prm');
      expect(url.toString(), 'https://h.test/prm');
    });

    test('a challenge without the parameter yields nothing', () {
      expect(resourceMetadataUrlFrom('Bearer realm="mcp"'), isNull);
      expect(resourceMetadataUrlFrom(null), isNull);
    });
  });

  group('isSignedIn', () {
    test('a stored refresh token is a session', () async {
      final store = _Tokens()..values['mcp_refresh_token'] = 'rt';
      expect(await _session(_FakeBondMcpClient(const {}), store).isSignedIn, isTrue);
    });

    test('the local-mode flag is a session with no token at all', () async {
      final store = _Tokens()..values['mcp_local_mode'] = '1';
      expect(await _session(_FakeBondMcpClient(const {}), store).isSignedIn, isTrue);
    });

    test('an empty store is not a session', () async {
      expect(
        await _session(_FakeBondMcpClient(const {}), _Tokens()).isSignedIn,
        isFalse,
      );
    });

    test('a Graph session alone is not an MCP session', () async {
      final store = _Tokens()..values['refresh_token'] = 'graph-rt';
      expect(await _session(_FakeBondMcpClient(const {}), store).isSignedIn, isFalse);
    });
  });

  group('needsReconsent', () {
    test('a disconnected account needs the connect step', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {'connected': false, 'scopes': <String>[]},
        }),
        _Tokens(),
      );
      expect(await auth.needsReconsent, isTrue);
    });

    test('a not_connected payload needs it too', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {'error': 'not_connected', 'connect_url': null},
        }),
        _Tokens(),
      );
      expect(await auth.needsReconsent, isTrue);
    });

    test('a connected account does not', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {
            'connected': true,
            'scopes': ['mail.read'],
          },
        }),
        _Tokens(),
      );
      expect(await auth.needsReconsent, isFalse);
    });

    test('a transient transport failure must NOT read as "reconnect"', () async {
      // A dropped network would otherwise push a good session into a
      // reconnect loop over nothing.
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status':
              const McpTransportException('connection reset', statusCode: 502),
        }),
        _Tokens(),
      );
      expect(await auth.needsReconsent, isFalse);
    });

    test('a tool failure does not either', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': const McpToolException('upstream is down'),
        }),
        _Tokens(),
      );
      expect(await auth.needsReconsent, isFalse);
    });

    test('the answer is cached, so a second question costs no call', () async {
      final client = _FakeBondMcpClient({
        'connection_status': {
          'connected': true,
          'scopes': ['mail.read'],
        },
      });
      final auth = _session(client, _Tokens());

      await auth.needsReconsent;
      await auth.needsReconsent;
      await auth.hasScope('mail.read');
      expect(client.callCounts['connection_status'], 1);
    });

    test('invalidating the cache makes the next question ask again', () async {
      final client = _FakeBondMcpClient({
        'connection_status': {
          'connected': true,
          'scopes': ['mail.read'],
        },
      });
      final auth = _session(client, _Tokens());

      await auth.needsReconsent;
      auth.invalidateStatusCache();
      await auth.needsReconsent;
      expect(client.callCounts['connection_status'], 2);
    });

    test('a cold-start stall never costs the user their session', () async {
      // The platform's database wakes in 10-30s after an idle spell, so the
      // first probe of the day can time out. Both halves are pinned together
      // deliberately: the pair is what decides whether the app stays where it
      // is or throws the user back to the sign-in screen.
      final store = _Tokens()..values['mcp_refresh_token'] = 'rt';
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': const McpTransportException('timed out'),
        }),
        store,
      );

      expect(await auth.needsReconsent, isFalse);
      expect(await auth.isSignedIn, isTrue);
      expect(store.values['mcp_refresh_token'], 'rt');
    });

    test('a failed probe is not cached as an answer', () async {
      final client = _FakeBondMcpClient({
        'connection_status': const McpTransportException('reset'),
      });
      final auth = _session(client, _Tokens());

      await auth.needsReconsent;
      await auth.needsReconsent;
      expect(client.callCounts['connection_status'], 2);
    });
  });

  group('hasScope', () {
    Future<bool> ask(String scope, List<String> granted) {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {'connected': true, 'scopes': granted},
        }),
        _Tokens(),
      );
      return auth.hasScope(scope);
    }

    test('a named scope is granted', () async {
      expect(await ask('mail.send', ['mail.read', 'mail.send']), isTrue);
    });

    test('a scope nobody granted is not', () async {
      expect(await ask('chat.read', ['mail.read']), isFalse);
    });

    test('mail.readwrite subsumes mail.read', () async {
      expect(await ask('mail.read', ['mail.readwrite']), isTrue);
    });

    test('subsumption does not run the other way', () async {
      expect(await ask('mail.readwrite', ['mail.read']), isFalse);
    });

    test('the comparison is case-insensitive', () async {
      expect(await ask('Mail.Send', ['MAIL.SEND']), isTrue);
    });

    test('an empty scope list is a legacy mail-only grant', () async {
      // Rows that predate the platform recording scopes were all mail-only.
      expect(await ask('mail.read', const []), isTrue);
      expect(await ask('mail.send', const []), isTrue);
      expect(await ask('chat.read', const []), isFalse);
    });

    test('a disconnected account grants nothing', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {
            'connected': false,
            'scopes': ['mail.read'],
          },
        }),
        _Tokens(),
      );
      expect(await auth.hasScope('mail.read'), isFalse);
    });

    test('a failed probe grants nothing', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': const McpTransportException('reset'),
        }),
        _Tokens(),
      );
      expect(await auth.hasScope('mail.read'), isFalse);
    });
  });

  group('storedAccount', () {
    test('reads the stored summary', () async {
      final store = _Tokens()
        ..values['mcp_account_json'] = jsonEncode(const AccountInfo(
          displayName: 'Ada Lovelace',
          mail: 'ada@example.test',
        ).toJson());

      final account =
          await _session(_FakeBondMcpClient(const {}), store).storedAccount;
      expect(account?.displayName, 'Ada Lovelace');
      expect(account?.mail, 'ada@example.test');
    });

    test('unreadable storage is null, not a crash', () async {
      final store = _Tokens()..values['mcp_account_json'] = 'not json at all';
      expect(
        await _session(_FakeBondMcpClient(const {}), store).storedAccount,
        isNull,
      );
    });

    test('nothing stored and no token is null', () async {
      expect(
        await _session(_FakeBondMcpClient(const {}), _Tokens()).storedAccount,
        isNull,
      );
    });

    test('the Graph session\'s account is not read as this one\'s', () async {
      final store = _Tokens()
        ..values['account_json'] =
            jsonEncode(const AccountInfo(displayName: 'Graph User').toJson());
      expect(
        await _session(_FakeBondMcpClient(const {}), store).storedAccount,
        isNull,
      );
    });
  });

  group('microsoftConnectUrl', () {
    test('returns the platform\'s connect URL', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {
            'error': 'not_connected',
            'connect_url': 'https://connect.example.test/start',
          },
        }),
        _Tokens(),
      );
      expect(await auth.microsoftConnectUrl(), 'https://connect.example.test/start');
    });

    test('a null connect_url is null', () async {
      final auth = _session(
        _FakeBondMcpClient({
          'connection_status': {'connected': true, 'connect_url': null},
        }),
        _Tokens(),
      );
      expect(await auth.microsoftConnectUrl(), isNull);
    });

    test('always asks fresh, bypassing the cache', () async {
      final client = _FakeBondMcpClient({
        'connection_status': {
          'connected': true,
          'connect_url': 'https://connect.example.test/start',
        },
      });
      final auth = _session(client, _Tokens());

      await auth.needsReconsent;
      await auth.microsoftConnectUrl();
      expect(client.callCounts['connection_status'], 2);
    });
  });

  group('signOut', () {
    test('clears the MCP keys and leaves the Graph session alone', () async {
      final store = _Tokens()
        ..values['mcp_refresh_token'] = 'mcp-rt'
        ..values['mcp_account_json'] = '{"displayName":"Ada"}'
        ..values['mcp_local_mode'] = '1'
        ..values['refresh_token'] = 'graph-rt'
        ..values['granted_scopes'] = 'Mail.Read User.Read'
        ..values['account_json'] = '{"displayName":"Graph User"}';

      await _session(_FakeBondMcpClient(const {}), store).signOut();

      expect(store.values.containsKey('mcp_refresh_token'), isFalse);
      expect(store.values.containsKey('mcp_account_json'), isFalse);
      expect(store.values.containsKey('mcp_local_mode'), isFalse);
      expect(store.values['refresh_token'], 'graph-rt');
      expect(store.values['granted_scopes'], 'Mail.Read User.Read');
      expect(store.values['account_json'], '{"displayName":"Graph User"}');
      expect(store.deleteAllCalled, isFalse);
    });

    test('leaves the session signed out', () async {
      final store = _Tokens()..values['mcp_refresh_token'] = 'mcp-rt';
      final auth = _session(_FakeBondMcpClient(const {}), store);
      await auth.signOut();
      expect(await auth.isSignedIn, isFalse);
    });
  });

  group('decodeJwtPayload', () {
    /// An unpadded base64url JWT, the way a real one arrives.
    String jwtWith(Map<String, dynamic> claims) {
      final payload =
          base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
      return 'header.$payload.signature';
    }

    test('reads claims through missing padding', () {
      final claims = decodeJwtPayload(jwtWith({'sub': 'user-1', 'exp': 123}));
      expect(claims?['sub'], 'user-1');
      expect(claims?['exp'], 123);
    });

    test('a non-JWT string is null, not a throw', () {
      expect(decodeJwtPayload('not-a-jwt'), isNull);
      expect(decodeJwtPayload('a.!!!!.c'), isNull);
    });
  });
}
