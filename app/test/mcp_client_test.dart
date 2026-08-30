import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart'
    show McpError, McpProtocol, StaleSessionError;

/// The MCP wire client: how a tool result is read, and how a connection that
/// the stateless server has forgotten is recovered.
///
/// The session stub is deliberately duplicated from the auth tests' client
/// fakes rather than shared, so no file can break another by editing it.
class _ScriptedSession implements McpToolSession {
  /// One entry per call: a wire-JSON result to return, or an object to throw.
  final List<Object> replies;
  final List<String> calls = [];
  int disposals = 0;
  int _next = 0;

  _ScriptedSession(this.replies);

  @override
  Future<Map<String, dynamic>> callRaw(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add(name);
    final reply = replies[_next++];
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> dispose() async => disposals++;
}

/// A structured-content result, as the server frames one for a JSON tool.
Map<String, dynamic> _structured(Map<String, dynamic> payload) => {
      'structuredContent': payload,
      'isError': false,
    };

/// A text-content result, as the server actually frames one.
Map<String, dynamic> _textResult(String text, {bool isError = false}) => {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'isError': isError,
    };

void main() {
  group('decodeToolResult', () {
    test('structuredContent wins over the text block', () {
      final decoded = decodeToolResult({
        'structuredContent': {'connected': true},
        'content': [
          {'type': 'text', 'text': '{"connected": false}'},
        ],
        'isError': false,
      });
      expect(decoded, {'connected': true});
    });

    test('falls back to JSON in the first text block', () {
      final decoded = decodeToolResult(_textResult('{"mail": "a@b.test"}'));
      expect(decoded, {'mail': 'a@b.test'});
    });

    test('skips a non-text block to reach the text one', () {
      final decoded = decodeToolResult({
        'content': [
          {'type': 'image', 'data': 'irrelevant'},
          {'type': 'text', 'text': '{"id": "7"}'},
        ],
      });
      expect(decoded, {'id': '7'});
    });

    test('isError:true is a tool failure carrying the tool\'s own text', () {
      expect(
        () => decodeToolResult(_textResult('mailbox is locked', isError: true)),
        throwsA(isA<McpToolException>()
            .having((e) => e.message, 'message', 'mailbox is locked')),
      );
    });

    test('isError:true wins even when a structured payload rides along', () {
      // Returning the payload would hand the caller an error dressed as an
      // answer, which is the one outcome that must never happen.
      expect(
        () => decodeToolResult({
          'structuredContent': {'connected': true},
          'content': [
            {'type': 'text', 'text': 'not_connected'},
          ],
          'isError': true,
        }),
        throwsA(isA<McpToolException>()),
      );
    });

    test('text that is not JSON is a transport failure', () {
      expect(
        () => decodeToolResult(_textResult('<html>502 Bad Gateway</html>')),
        throwsA(isA<McpTransportException>()),
      );
    });

    test('JSON that is not an object is a transport failure', () {
      expect(
        () => decodeToolResult(_textResult('[1, 2, 3]')),
        throwsA(isA<McpTransportException>()),
      );
    });

    test('no content at all is a transport failure', () {
      expect(
        () => decodeToolResult({'content': <dynamic>[], 'isError': false}),
        throwsA(isA<McpTransportException>()),
      );
    });
  });

  group('connection options', () {
    test('the handshake is pinned to the legacy dialect', () {
      // FastMCP 3.x speaks the pre-2026 initialize flow. The package default
      // would spend a round trip probing for something this peer cannot answer.
      expect(buildClientOptions().protocol, McpProtocol.legacy);
    });

    test('Accept names both content types', () {
      final headers = buildRequestInit(null)['headers'] as Map<String, dynamic>;
      expect(headers['Accept'], 'application/json, text/event-stream');
    });

    test('a bearer becomes an Authorization header', () {
      final headers =
          buildRequestInit('the-jwt')['headers'] as Map<String, dynamic>;
      expect(headers['Authorization'], 'Bearer the-jwt');
    });

    test('no bearer means no Authorization header at all', () {
      final headers = buildRequestInit(null)['headers'] as Map<String, dynamic>;
      expect(headers.containsKey('Authorization'), isFalse);
    });

    test('an empty bearer is treated as no bearer', () {
      final headers = buildRequestInit('')['headers'] as Map<String, dynamic>;
      expect(headers.containsKey('Authorization'), isFalse);
    });
  });

  group('BondMcpHttpClient', () {
    test('one trailing slash is stripped from the endpoint', () {
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp/'),
        sessionFactory: (_, _) async => _ScriptedSession([]),
      );
      expect(client.baseUrl.toString(), 'https://example.test/mcp');
    });

    test('an endpoint without a trailing slash is left alone', () {
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async => _ScriptedSession([]),
      );
      expect(client.baseUrl.toString(), 'https://example.test/mcp');
    });

    test('connects once and reuses the session across calls', () async {
      var connects = 0;
      final session = _ScriptedSession([
        _structured({'ok': 1}),
        _structured({'ok': 2}),
      ]);
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return session;
        },
      );

      expect(await client.callTool('a', const {}), {'ok': 1});
      expect(await client.callTool('b', const {}), {'ok': 2});
      expect(connects, 1);
    });

    test('the bearer is fetched at connect time, not construction', () async {
      String? seenBearer;
      var bearer = 'first';
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        getBearer: () async => bearer,
        sessionFactory: (_, token) async {
          seenBearer = token;
          return _ScriptedSession([_structured({'ok': true})]);
        },
      );

      bearer = 'rotated';
      await client.callTool('a', const {});
      expect(seenBearer, 'rotated');
    });

    test('a forgotten session is re-initialized exactly once', () async {
      var connects = 0;
      final sessions = [
        _ScriptedSession([
          const McpTransportException('Session not found', statusCode: 404),
        ]),
        _ScriptedSession([_structured({'connected': true})]),
      ];
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async => sessions[connects++],
      );

      expect(await client.callTool('connection_status', const {}), {
        'connected': true,
      });
      expect(connects, 2);
      // The dead session is closed, not leaked.
      expect(sessions.first.disposals, 1);
    });

    test('a second 404 is a real failure, not another retry', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([
            const McpTransportException('Session not found', statusCode: 404),
          ]);
        },
      );

      await expectLater(
        client.callTool('connection_status', const {}),
        throwsA(isA<McpTransportException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
      expect(connects, 2);
    });

    test('a 401 mid-session reconnects once, on a fresh bearer', () async {
      // The whole point of the reconnect: the bearer is fixed at handshake
      // time, so a session that outlives its 24-hour JWT can only pick up the
      // refreshed one on a new connection.
      var connects = 0;
      final bearers = <String?>[];
      const tokens = ['stale-jwt', 'refreshed-jwt'];
      final sessions = [
        _ScriptedSession([
          const McpTransportException('invalid_token', statusCode: 401),
        ]),
        _ScriptedSession([_structured({'ok': true})]),
      ];
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        getBearer: () async => tokens[bearers.length],
        sessionFactory: (_, bearer) async {
          bearers.add(bearer);
          return sessions[connects++];
        },
      );

      expect(await client.callTool('list_mail_delta', const {}), {'ok': true});
      expect(connects, 2);
      expect(bearers, ['stale-jwt', 'refreshed-jwt']);
      expect(sessions.first.disposals, 1);
    });

    test('a second consecutive 401 is a real failure, not a loop', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([
            const McpTransportException('invalid_token', statusCode: 401),
          ]);
        },
      );

      await expectLater(
        client.callTool('list_mail_delta', const {}),
        throwsA(isA<McpTransportException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(connects, 2);
    });

    test('the 401 and 404 retries share one budget', () async {
      // Alternating causes must not each buy their own retry — that is how a
      // sick server turns into an unbounded reconnect loop.
      var connects = 0;
      final sessions = [
        _ScriptedSession([
          const McpTransportException('invalid_token', statusCode: 401),
        ]),
        _ScriptedSession([
          const McpTransportException('Session not found', statusCode: 404),
        ]),
      ];
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async => sessions[connects++],
      );

      await expectLater(
        client.callTool('connection_status', const {}),
        throwsA(isA<McpTransportException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
      expect(connects, 2);
    });

    test('a sign-out found during the 401 reconnect passes through unwrapped',
        () async {
      // NotSignedIn is what routes the app to the sign-in screen. Flattened
      // into a transport failure it would become a banner about the network.
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        getBearer: () async {
          if (connects > 0) throw const NotSignedIn();
          return 'stale-jwt';
        },
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([
            const McpTransportException('invalid_token', statusCode: 401),
          ]);
        },
      );

      await expectLater(
        client.callTool('list_mail_delta', const {}),
        throwsA(isA<NotSignedIn>()),
      );
    });

    test('a non-404 transport failure is not retried', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([
            const McpTransportException('gateway is down', statusCode: 502),
          ]);
        },
      );

      await expectLater(
        client.callTool('connection_status', const {}),
        throwsA(isA<McpTransportException>()),
      );
      expect(connects, 1);
    });

    test('a tool failure is not a reconnect', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([_textResult('no mailbox', isError: true)]);
        },
      );

      await expectLater(
        client.callTool('list_messages', const {}),
        throwsA(isA<McpToolException>()),
      );
      expect(connects, 1);
    });

    test('racing calls on a cold client share one handshake', () async {
      var connects = 0;
      final session = _ScriptedSession([
        _structured({'ok': 1}),
        _structured({'ok': 2}),
      ]);
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          await Future<void>.delayed(Duration.zero);
          return session;
        },
      );

      await Future.wait([
        client.callTool('a', const {}),
        client.callTool('b', const {}),
      ]);
      expect(connects, 1);
    });

    test('close drops the session so the next call reconnects', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([_structured({'ok': true})]);
        },
      );

      await client.callTool('a', const {});
      await client.close();
      await client.callTool('a', const {});
      expect(connects, 2);
    });
  });

  group('a server that predates this app\'s tools', () {
    test('is reported as needing an update, naming the tool', () async {
      var connects = 0;
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async {
          connects++;
          return _ScriptedSession([
            const McpTransportException('Unknown tool: list_mail_delta'),
          ]);
        },
      );

      await expectLater(
        client.callTool('list_mail_delta', const {}),
        throwsA(isA<McpTransportException>()
            .having((e) => e.message, 'message', contains('needs to be updated'))
            .having((e) => e.message, 'message', contains('list_mail_delta'))),
      );
      // Reconnecting cannot install a tool the deployment does not have.
      expect(connects, 1);
    });

    test('reads the same when the miss arrives as a tool error', () async {
      // Which of the two it is depends on the FastMCP build, so both are read.
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async => _ScriptedSession([
          _textResult('Unknown tool: send_draft', isError: true),
        ]),
      );

      await expectLater(
        client.callTool('send_draft', const {}),
        throwsA(isA<McpTransportException>()
            .having((e) => e.message, 'message', contains('needs to be updated'))
            .having((e) => e.message, 'message', contains('send_draft'))),
      );
    });

    test('an ordinary failure is left saying what it said', () async {
      final client = BondMcpHttpClient(
        Uri.parse('https://example.test/mcp'),
        sessionFactory: (_, _) async =>
            _ScriptedSession([_textResult('mailbox is locked', isError: true)]),
      );

      await expectLater(
        client.callTool('send_draft', const {}),
        throwsA(isA<McpToolException>()
            .having((e) => e.message, 'message', 'mailbox is locked')),
      );
    });
  });

  group('asTransportException', () {
    test('a stale session arrives with its 404', () {
      final failure =
          asTransportException(StaleSessionError('Session not found', code: 404));
      expect(failure.statusCode, 404);
    });

    test('a failed POST keeps the HTTP status buried in its text', () {
      // mcp_dart reduces a non-2xx tool POST to McpError(0, '… (HTTP 401): …'),
      // and that number is the only surviving sign that the bearer expired —
      // without reading it back out, the reconnect never fires.
      final failure = asTransportException(
        McpError(0, 'Error POSTing to endpoint (HTTP 401): {"error":"x"}'),
      );
      expect(failure.statusCode, 401);
    });

    test('an McpError naming no status carries none', () {
      final failure =
          asTransportException(McpError(-32602, 'Unknown tool: list_mail_delta'));
      expect(failure.statusCode, isNull);
      expect(failure.message, 'Unknown tool: list_mail_delta');
    });
  });
}
