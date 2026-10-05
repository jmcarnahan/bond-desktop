import 'dart:async';
import 'dart:io' show SocketException;

import 'package:bond_inbox/services/models/registry_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _fakeToken = 'test-token-123';

/// Settings' registry **Check**: one GET for the first byte of the decision
/// model's small file, and what its answer means.
void main() {
  final url = Uri.parse('https://artifactory.example.com/artifactory/'
      'bond-models/bundles/bond-decide-mbl-v3swap/heads.json');

  late List<http.BaseRequest> seen;

  MockClient answering(int status) => MockClient((request) async {
        seen.add(request);
        return http.Response('x', status);
      });

  setUp(() => seen = []);

  test('each status means what it says', () async {
    final cases = {
      200: RegistryCheck.reachable,
      206: RegistryCheck.reachable,
      302: RegistryCheck.redirected,
      307: RegistryCheck.redirected,
      401: RegistryCheck.unauthorized,
      403: RegistryCheck.unauthorized,
      404: RegistryCheck.notFound,
      500: RegistryCheck.unreachable,
      418: RegistryCheck.unreachable,
    };
    for (final entry in cases.entries) {
      expect(
        await probeRegistry(url: url, client: answering(entry.key)),
        entry.value,
        reason: 'HTTP ${entry.key}',
      );
    }
  });

  test('a web page is not a model, whatever its status says', () async {
    for (final status in [200, 206]) {
      final client = MockClient((request) async => http.Response(
            '<html>Sign in</html>',
            status,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ));
      expect(await probeRegistry(url: url, client: client),
          RegistryCheck.notAModel,
          reason: 'HTTP $status');
    }
    final bytes = MockClient((request) async => http.Response(
          'x',
          206,
          headers: {'content-type': 'application/octet-stream'},
        ));
    expect(await probeRegistry(url: url, client: bytes),
        RegistryCheck.reachable);
  });

  test('asks for the first byte only, does not follow redirects, and sends '
      'the bearer when there is one', () async {
    await probeRegistry(url: url, token: _fakeToken, client: answering(206));

    final request = seen.single;
    expect(request.method, 'GET');
    expect(request.url, url);
    expect(request.headers['range'], 'bytes=0-0');
    expect(request.headers['authorization'], 'Bearer $_fakeToken');
    expect(request.followRedirects, isFalse);
  });

  test('sends no authorization without a token, or with an empty one',
      () async {
    await probeRegistry(url: url, client: answering(401));
    await probeRegistry(url: url, token: '', client: answering(401));

    for (final request in seen) {
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers['range'], 'bytes=0-0');
    }
  });

  test('a transport error is unreachable, and never a throw', () async {
    final client = MockClient(
      (_) async => throw const SocketException('connection refused'),
    );
    expect(await probeRegistry(url: url, client: client),
        RegistryCheck.unreachable);
  });

  test('a server that never answers is unreachable at the timeout', () async {
    final never = Completer<http.Response>();
    final client = MockClient((_) => never.future);

    final answer = await probeRegistry(
      url: url,
      client: client,
      timeout: const Duration(milliseconds: 50),
    );

    expect(answer, RegistryCheck.unreachable);
  });
}
