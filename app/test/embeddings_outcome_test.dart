import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Which failures are worth retrying, and which are not.
///
/// The vector is the same null either way, so nothing else in the suite can
/// tell these apart — and the whole pipeline decision that hangs off them (a
/// storyline pass queued and parked, versus a thread dropped) is invisible
/// from a null.
const String _url = 'http://localhost:8081/v1/embeddings';

EmbeddingsClient clientThat(
  Future<http.Response> Function(http.Request request) respond, {
  void Function(String reason)? onFail,
}) =>
    EmbeddingsClient(
      baseUrl: _url,
      httpClient: MockClient(respond),
      onFail: onFail,
    );

http.Response jsonOk(Object body) =>
    http.Response(jsonEncode(body), 200, headers: const {
      'content-type': 'application/json',
    });

void main() {
  group('unavailable — nothing answered', () {
    test('a server that is not running', () async {
      final client = clientThat(
        (_) async => throw const SocketException('refused'),
      );

      final result = await client.embedResult('anything');

      expect(result.outcome, EmbedOutcome.unavailable);
      expect(result.vector, isNull);
      expect(result.reason, contains('make embed'));
    });

    test('a dropped socket', () async {
      final client = clientThat((_) async => throw http.ClientException('reset'));

      expect(
        (await client.embedResult('anything')).outcome,
        EmbedOutcome.unavailable,
      );
    });

    test('a server that never answered', () async {
      final client = clientThat((_) async => throw TimeoutException('slow'));

      final result = await client.embedResult('anything');

      expect(result.outcome, EmbedOutcome.unavailable);
      expect(result.reason, contains('did not answer'));
    });

    test('the three gateway statuses a server still loading sends', () async {
      for (final status in [502, 503, 504]) {
        final client = clientThat((_) async => http.Response('nope', status));

        expect(
          (await client.embedResult('anything')).outcome,
          EmbedOutcome.unavailable,
          reason: 'HTTP $status',
        );
      }
    });
  });

  group('rejected — something answered, and it was not a vector', () {
    test('every other non-200', () async {
      for (final status in [400, 404, 429, 500]) {
        final client = clientThat((_) async => http.Response('nope', status));

        expect(
          (await client.embedResult('anything')).outcome,
          EmbedOutcome.rejected,
          reason: 'HTTP $status',
        );
      }
    });

    test('a body that is not JSON', () async {
      final client = clientThat(
        (_) async => http.Response('<html>oops</html>', 200),
      );

      final result = await client.embedResult('anything');

      expect(result.outcome, EmbedOutcome.rejected);
      expect(result.reason, contains('not JSON'));
    });

    test('JSON of the wrong shape, and values that are not numbers', () async {
      for (final body in <Object>[
        {'data': <Object>[]},
        {'data': 'nope'},
        const [1, 2, 3],
        {
          'data': [
            {'embedding': 'nope'}
          ]
        },
        {
          'data': [
            {'embedding': ['not', 'numbers']}
          ]
        },
      ]) {
        final client = clientThat((_) async => jsonOk(body));

        expect(
          (await client.embedResult('anything')).outcome,
          EmbedOutcome.rejected,
          reason: '$body',
        );
      }
    });
  });

  group('ok', () {
    test('carries the vector and no reason', () async {
      final client = clientThat((_) async => jsonOk({
            'data': [
              {'embedding': [0.5, -0.25, 0]}
            ]
          }));

      final result = await client.embedResult('anything');

      expect(result.outcome, EmbedOutcome.ok);
      expect(result.vector, [0.5, -0.25, 0.0]);
      expect(result.reason, isNull);
    });
  });

  group('embed', () {
    test('is embedResult with the outcome thrown away', () async {
      // The wrapper is what keeps every caller that would do the same thing
      // either way unchanged.
      final down = clientThat(
        (_) async => throw const SocketException('refused'),
      );
      final nonsense = clientThat((_) async => http.Response('nope', 400));
      final good = clientThat((_) async => jsonOk({
            'data': [
              {'embedding': [1, 0]}
            ]
          }));

      expect(await down.embed('anything'), isNull);
      expect(await nonsense.embed('anything'), isNull);
      expect(await good.embed('anything'), [1.0, 0.0]);
    });
  });

  group('onFail', () {
    test('still fires once per distinct reason, whatever the outcome',
        () async {
      final reasons = <String>[];
      var status = 503;
      final client = clientThat(
        (_) async => http.Response('nope', status),
        onFail: reasons.add,
      );

      for (var i = 0; i < 5; i++) {
        await client.embedResult('anything');
      }
      status = 500;
      await client.embedResult('anything');
      await client.embedResult('anything');

      // One line per distinct failure however long the backlog — the outcomes
      // differ (503 is unavailable, 500 is rejected) and the dedupe does not
      // care, because it is about how often a person is told.
      expect(reasons, [
        'rejected the request (HTTP 503)',
        'rejected the request (HTTP 500)',
      ]);
    });

    test('the reason on the result is the reason reported', () async {
      final reasons = <String>[];
      final client = clientThat(
        (_) async => http.Response('nope', 503),
        onFail: reasons.add,
      );

      final result = await client.embedResult('anything');

      expect(result.reason, reasons.single);
    });
  });
}
