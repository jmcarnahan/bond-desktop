import 'dart:io';

import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// The loopback wait in [GraphAuth.awaitCallbackCode], against a real socket.
///
/// The port the app listens on is shared with another local backend whose own
/// clients poll it, so the wait must answer strangers and keep waiting — only
/// the request carrying this run's `state` may end it, in either direction
/// (code or error).
///
/// The store stub is deliberately duplicated from the other auth tests rather
/// than shared, so no file can break another by editing it.
class InMemoryTokenStore implements TokenStore {
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
  late GraphAuth auth;
  late HttpServer server;
  late Uri base;

  setUp(() async {
    auth = GraphAuth(store: InMemoryTokenStore());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/cb');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('the callback with the right state returns its code', () async {
    final wait = auth.awaitCallbackCode(server, 'expected-state');
    final reply = await http
        .get(base.replace(queryParameters: {'state': 'expected-state', 'code': 'the-code'}));
    expect(reply.statusCode, 200);
    expect(await wait, 'the-code');
  });

  test('a stray request is answered and does NOT consume the wait', () async {
    final wait = auth.awaitCallbackCode(server, 'expected-state');

    // A poll with no sign-in params at all — what a stopped backend's own
    // clients send at this port.
    final stray = await http.get(base);
    expect(stray.statusCode, 200);

    // A forged callback with a code but the wrong state must not be adopted
    // AND must not abort the wait.
    final forged = await http.get(
        base.replace(queryParameters: {'state': 'wrong', 'code': 'attacker'}));
    expect(forged.statusCode, 200);

    // The genuine callback still wins afterwards.
    await http.get(base
        .replace(queryParameters: {'state': 'expected-state', 'code': 'real'}));
    expect(await wait, 'real');
  });

  test('a denied consent with the right state throws AuthorizeDenied', () async {
    final wait = auth.awaitCallbackCode(server, 'expected-state');
    await http.get(base.replace(queryParameters: {
      'state': 'expected-state',
      'error': 'access_denied',
      'error_description': 'AADSTS65004: user declined',
    }));
    await expectLater(wait, throwsA(isA<AuthorizeDenied>()));
  });

  test('a matching callback without a code is an error, not a hang', () async {
    final wait = auth.awaitCallbackCode(server, 'expected-state');
    await http.get(base.replace(queryParameters: {'state': 'expected-state'}));
    await expectLater(wait, throwsA(isA<AuthException>()));
  });

  test('closing the server under the wait fails cleanly', () async {
    final wait = auth.awaitCallbackCode(server, 'expected-state');
    await server.close(force: true);
    await expectLater(wait, throwsA(isA<AuthException>()));
  });
}
