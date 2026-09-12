import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What floor a drain actually asks Graph for.
///
/// Two rules meet in one string. The lookback preference sets a rolling window
/// and the settings screen names the day it starts on, which is why the floor
/// is cut back to UTC midnight. The vacation rule says that window can only
/// ever be widened by a sync that finished long ago: mail delivered while the
/// app was closed has no cursor coming for it, so a pass must reach at least as
/// far back as the last one ended.
///
/// The harness is duplicated from delta_paging_test rather than shared, on the
/// same principle that file states for its token store: neither test can break
/// the other by editing it.

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

const String _grantedScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

const String _graphBase = 'https://graph.microsoft.com/v1.0';

String deltaCursor(String folder, String token) =>
    '$_graphBase/me/mailFolders/$folder/messages/delta?\$deltatoken=$token';

http.Response jsonOk(Object body) => http.Response(
      body is String ? body : jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// A finished, empty drain. These tests read the request, never the response.
http.Response emptyPage(String folder) => jsonOk({
      'value': const [],
      '@odata.deltaLink': deltaCursor(folder, 'done'),
    });

class GraphStub {
  final List<Uri> requests = [];
  final Map<String, List<http.Response Function()>> pages = {};

  void queue(String folder, List<http.Response Function()> responses) {
    pages[folder] = [...responses];
  }

  List<Uri> requestsFor(String folder) => [
        for (final uri in requests)
          if (uri.path.contains('/mailFolders/$folder/')) uri,
      ];

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return jsonOk({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
            'token_type': 'Bearer',
          });
        }

        requests.add(request.url);

        if (request.url.path.endsWith('/messages/delta')) {
          final folder =
              request.url.path.contains('sentitems') ? 'sentitems' : 'inbox';
          final queued = pages[folder];
          if (queued == null || queued.isEmpty) return emptyPage(folder);
          return queued.removeAt(0)();
        }

        return http.Response('unexpected ${request.url}', 404);
      });
}

/// UTC midnight [days] back, in the shape the floor is written in. Recomputed
/// per call rather than held, so a test straddling midnight can ask twice and
/// accept either answer.
String midnightDaysAgo(int days) {
  final t = DateTime.now().toUtc().subtract(Duration(days: days));
  return DateTime.utc(t.year, t.month, t.day)
      .toIso8601String()
      .replaceFirst('.000Z', 'Z');
}

/// An exact stamp, for the sync times these tests pin by hand.
String isoDaysAgo(int days) => DateTime.now()
    .toUtc()
    .subtract(Duration(days: days))
    .toIso8601String()
    .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

void main() {
  late BondDatabase db;
  late MessageStore store;
  late GraphStub graph;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = GraphStub();
  });

  tearDown(() async => db.close());

  SyncService syncReaching(int Function()? lookback) {
    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;
    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    return SyncService(
      GraphMail(auth, httpClient: graph.client),
      store,
      lookbackDays: lookback,
    );
  }

  /// The `$filter`'s timestamp, with the operator stripped.
  String floorOf(Uri request) {
    final filter = request.queryParameters[r'$filter'];
    expect(filter, startsWith('receivedDateTime ge '),
        reason: r'the floor rides on the delta request as a $filter');
    return filter!.replaceFirst('receivedDateTime ge ', '');
  }

  test('the lookback setting is the floor a first drain asks for', () async {
    final before = midnightDaysAgo(90);
    await syncReaching(() => 90).syncNow();
    final after = midnightDaysAgo(90);

    final floor = floorOf(graph.requestsFor('inbox').first);
    // Midnight, not the moment of the sync: the settings screen promises mail
    // "since <day>", and this is what makes that sentence exactly true.
    expect(DateTime.parse(floor).isUtc, isTrue);
    expect(floor, endsWith('T00:00:00Z'));
    // Two answers accepted only because a run can straddle midnight itself.
    expect(floor, anyOf(before, after));
  });

  test('a resolver that throws costs the setting, never the sync', () async {
    final before = midnightDaysAgo(syncFloorDays);
    await syncReaching(() => throw StateError('container disposed')).syncNow();
    final after = midnightDaysAgo(syncFloorDays);

    expect(floorOf(graph.requestsFor('inbox').first), anyOf(before, after));
  });

  test('a sync that last finished before the window reaches back to it',
      () async {
    // Two months away, with no cursor left to fetch what arrived meanwhile.
    final away = isoDaysAgo(60);
    await store.setSyncedAt('inbox', away);
    await store.setSyncedAt('sentitems', away);

    await syncReaching(() => syncFloorDays).syncNow();

    // The stored stamp itself, to the character: rounding it forward by even
    // an hour would leave mail nothing ever asks for again.
    expect(floorOf(graph.requestsFor('inbox').first), away);
    expect(floorOf(graph.requestsFor('sentitems').first), away);
  });

  test('a sync that finished yesterday leaves the rolling window in charge',
      () async {
    final recent = isoDaysAgo(2);
    await store.setSyncedAt('inbox', recent);
    await store.setSyncedAt('sentitems', recent);

    final before = midnightDaysAgo(syncFloorDays);
    await syncReaching(() => syncFloorDays).syncNow();
    final after = midnightDaysAgo(syncFloorDays);

    // The OLDER of the two wins, and here that is the default floor.
    expect(floorOf(graph.requestsFor('inbox').first), anyOf(before, after));
  });

  test('a 410 recovery restarts from the floor the pass began with', () async {
    // Order matters: setDeltaLink stamps `synced_at` as a side effect, so the
    // stamp this test is about has to be written after the cursor.
    await store.setDeltaLink('inbox', deltaCursor('inbox', 'stale'));
    final away = isoDaysAgo(60);
    await store.setSyncedAt('inbox', away);
    await store.setSyncedAt('sentitems', away);

    graph.queue('inbox', [
      () => http.Response('{"error":{"code":"resyncRequired"}}', 410),
      () => emptyPage('inbox'),
    ]);

    await syncReaching(() => syncFloorDays).syncNow();

    final inbox = graph.requestsFor('inbox');
    // The dead cursor, the restart, and the reconcile behind them both — it
    // runs on every pass of a mailbox that has never stamped one.
    expect(inbox.length, 3);
    // The trap this test exists for: the 410 handler clears the cursor with
    // `setDeltaLink(folder, null)`, which stamps `synced_at` with now. A floor
    // recomputed here — rather than carried down from the top of the pass —
    // would read that fresh stamp and silently shrink to the default floor.
    expect(floorOf(inbox[1]), away);
  });
}
