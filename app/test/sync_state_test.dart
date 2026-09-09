import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// Thread state at INGEST: the fold reads only the messages the gate kept.
///
/// A message the gate throws out AT INSERT — mail from behind the sync floor,
/// stored `skipped`/`backlog` — is history being backfilled and not news: no
/// stage of this app will ever read it, so no thread may be made to ask for a
/// reply to it. It folds as `historical`, which moves the watermarks and the
/// counts and leaves the state where it stands.
///
/// The other half is the guard that keeps that rule from eating everything.
/// An outbound is ALWAYS `skipped`/`outbound` at insert — triage answers
/// "does this need me?" and the user's own send never does — so the rule is
/// inbound-only, and a reply still settles its thread.
///
/// The harness is duplicated from sync_widen_test rather than shared, on the
/// principle those files state for their token stores: neither test can break
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

Map<String, dynamic> deltaBody(
  List<Map<String, dynamic>> messages, {
  String? nextLink,
  String? deltaLink,
}) =>
    {
      'value': messages,
      '@odata.nextLink': ?nextLink,
      '@odata.deltaLink': ?deltaLink,
    };

/// A finished, empty drain that closes on a named cursor.
http.Response emptyPage(String folder, [String token = 'done']) =>
    jsonOk(deltaBody(const [], deltaLink: deltaCursor(folder, token)));

/// One message as a delta page renders it — the tier-one fields only.
Map<String, dynamic> graphMessage({
  required String id,
  required String receivedDateTime,
  String? conversationId = 'c1',
  String subject = 'Rate lock timing',
  String fromName = 'Sarah Whitfield',
  String fromAddress = 'sarah@example.test',
  List<String> to = const ['owner@example.test'],
  bool isRead = false,
  bool isDraft = false,
  String preview = 'Preview text',
}) =>
    {
      'id': id,
      'internetMessageId': '<$id@example.test>',
      'conversationId': ?conversationId,
      'subject': subject,
      'from': {
        'emailAddress': {'name': fromName, 'address': fromAddress}
      },
      'toRecipients': [
        for (final address in to)
          {
            'emailAddress': {'name': null, 'address': address}
          },
      ],
      'receivedDateTime': receivedDateTime,
      'isRead': isRead,
      'isDraft': isDraft,
      'bodyPreview': preview,
    };

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

/// An exact stamp, for the message dates these tests pin by hand.
String isoAgo(Duration ago) => DateTime.now()
    .toUtc()
    .subtract(ago)
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

  SyncService syncReaching(int lookbackDays) {
    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;
    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    return SyncService(
      GraphMail(auth, httpClient: graph.client),
      store,
      // Wired, because the one-shot below reports itself in the `sync_mail`
      // row's detail and nowhere else.
      activityLog: ActivityLog(store),
      lookbackDays: () => lookbackDays,
    );
  }

  Future<Map<String, Object?>> conversation(String key) async =>
      (await store.getConversationRow('email', key))!;

  /// How many `sync_mail` rows name the one-shot at all — the key is absent
  /// on every pass but the one that ran it.
  Future<int> reportedRefolds() async {
    final rows = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
          "AND detail_json LIKE '%refolded_threads%'",
        )
        .getSingle();
    return (rows.data['n'] as num).toInt();
  }

  /// The `detail` map off the newest `sync_mail` activity row.
  Future<Map<String, Object?>> syncMailDetail() async {
    final rows = await db
        .customSelect(
          "SELECT detail_json FROM activity_events WHERE kind = 'sync_mail' "
          'ORDER BY id DESC LIMIT 1',
        )
        .get();
    final raw = rows.first.data['detail_json'] as String?;
    return raw == null
        ? const {}
        : Map<String, Object?>.from(jsonDecode(raw) as Map);
  }

  group('what the fold reads', () {
    test('an inbound the gate drops at insert does not ask for a reply',
        () async {
      // Twenty days back under a fortnight's lookback: stored, rendered, and
      // gated `backlog` — nothing will ever read it.
      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm1',
                receivedDateTime: isoAgo(const Duration(days: 20)),
              ),
            ], deltaLink: deltaCursor('inbox', 'c1'))),
      ]);

      await syncReaching(14).syncNow();

      final message = (await store.getMessageRow('email', 'm1'))!;
      expect(message['triage_status'], 'skipped');
      expect(message['gate_reason'], 'backlog');

      final row = await conversation('c1');
      expect(row['state'], 'waiting',
          reason: 'a message no stage of this app will read is not a message '
              'anybody is waiting to answer');
      // The thread's RECORD is genuinely more complete, and says so: only the
      // state is withheld.
      expect(row['message_count'], 1);
      expect(row['inbound_count'], 1);
      expect(row['last_inbound_at'], isNotNull);
    });

    test('an in-window inbound in the same page still asks', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'old',
                conversationId: 'c1',
                receivedDateTime: isoAgo(const Duration(days: 20)),
              ),
              graphMessage(
                id: 'new',
                conversationId: 'c2',
                receivedDateTime: isoAgo(const Duration(hours: 2)),
              ),
            ], deltaLink: deltaCursor('inbox', 'c1'))),
      ]);

      await syncReaching(14).syncNow();

      // Scoped by the gate's own verdict, not by the pass: one drain carries
      // both, and only the gated one is quiet.
      expect((await conversation('c1'))['state'], 'waiting');
      expect((await conversation('c2'))['state'], 'needs_reply');
    });

    test('an outbound at insert still settles the thread', () async {
      // Every outbound is born `skipped`/`outbound`. Reading that stamp as a
      // gate would make every reply historical and no thread would ever go
      // quiet — which is why the rule is inbound-only.
      final ask = isoAgo(const Duration(hours: 4));
      final reply = isoAgo(const Duration(hours: 1));
      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(id: 'm1', receivedDateTime: ask),
            ], deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      graph.queue('sentitems', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm2',
                receivedDateTime: reply,
                to: const ['sarah@example.test'],
              ),
            ], deltaLink: deltaCursor('sentitems', 'c2'))),
      ]);

      await syncReaching(14).syncNow();

      final sent = (await store.getMessageRow('email', 'm2'))!;
      expect(sent['triage_status'], 'skipped');
      expect(sent['gate_reason'], 'outbound');
      expect((await conversation('c1'))['state'], 'waiting',
          reason: 'the reply the user sent is what takes the thread off the '
              'hook, whatever the gates stamped on it');
    });
  });

  group('the one-shot repair', () {
    test('the thread-state refold runs once and reports its count', () async {
      // A thread written before the fold learned to wait for the gate: its
      // only inbound is gated, and it is still asking for a reply.
      await store.upsertMessage({
        'source_message_id': 'stale',
        'conversation_key': 'lying',
        'direction': 'inbound',
        'from_address': 'no-reply@example.test',
        'received_at': isoAgo(const Duration(days: 2)),
        'triage_status': 'skipped',
        'gate_reason': 'no_reply',
      });
      await store.upsertConversation({
        'conversation_key': 'lying',
        'state': 'needs_reply',
      });

      await syncReaching(14).syncNow();

      expect((await conversation('lying'))['state'], 'waiting');
      expect(await store.getPref('thread_state_refold'), '1');
      final detail = await syncMailDetail();
      expect(detail['refolded_threads'], 1);

      // Once, and the pref is what says so. A later pass omits the key
      // entirely rather than reporting a zero, which would read as a repair
      // that ran and found nothing.
      graph.requests.clear();
      await syncReaching(14).syncNow();
      expect(await reportedRefolds(), 1,
          reason: 'exactly one sync_mail row ever names the repair');
    });
  });

}
