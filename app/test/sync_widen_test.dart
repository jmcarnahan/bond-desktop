import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What a widened lookback does to a mailbox that already has cursors.
///
/// Two facts have to hold together. A window the user made wider must actually
/// reach the mail behind the delta cursor — the cursor knows only what changed
/// since it was minted, and nothing else is ever going to fetch what sits
/// behind it. And the mail that arrives that way must not remake the threads
/// it lands in: it is history, and every decision the user made about those
/// threads was made after it.
///
/// The harness is duplicated from sync_lookback_test and delta_paging_test
/// rather than shared, on the same principle those files state for their token
/// stores: neither test can break the other by editing it.

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

  Future<Map<String, Object?>> conversation(String key) async =>
      (await store.getConversationRow('email', key))!;

  group('detecting a widened window', () {
    test('a wider setting re-drains both folders from the new floor', () async {
      await syncReaching(() => 14).syncNow();
      expect(await store.getDeltaLink('inbox', source: 'email'),
          deltaCursor('inbox', 'done'),
          reason: 'the first pass has to leave a cursor for the second to '
              'have something to abandon');
      graph.requests.clear();

      graph.queue('inbox', [() => emptyPage('inbox', 'wide')]);
      graph.queue('sentitems', [() => emptyPage('sentitems', 'wide')]);

      final before = midnightDaysAgo(90);
      await syncReaching(() => 90).syncNow();
      final after = midnightDaysAgo(90);

      // Two answers accepted only because a run can straddle midnight itself.
      final wider = anyOf(before, after);
      expect(floorOf(graph.requestsFor('inbox').single), wider);
      expect(floorOf(graph.requestsFor('sentitems').single), wider);
      expect(await store.getPref(mailBootstrapFloorKey), wider,
          reason: 'the marker records how far back the mailbox has been '
              'drained, so the pass after this one is incremental again');
      // The re-drain closed on its own cursor, exactly as a first run does.
      expect(await store.getDeltaLink('inbox', source: 'email'),
          deltaCursor('inbox', 'wide'));
      expect(await store.getDeltaLink('sentitems', source: 'email'),
          deltaCursor('sentitems', 'wide'));
    });

    test('a narrower setting changes nothing that already happened', () async {
      final before = midnightDaysAgo(14);
      await syncReaching(() => 14).syncNow();
      final after = midnightDaysAgo(14);
      graph.requests.clear();

      await syncReaching(() => 7).syncNow();

      final second = graph.requestsFor('inbox').single;
      expect(second.toString(), deltaCursor('inbox', 'done'));
      expect(second.queryParameters[r'$filter'], isNull,
          reason: 'a narrower window is a preference about what to keep, not '
              'a reason to re-fetch anything');
      // Monotone: the marker only ever moves older, so a fortnight already
      // drained is not forgotten by a week's worth of setting.
      expect(await store.getPref(mailBootstrapFloorKey), anyOf(before, after));
    });

    test('a mailbox with no marker adopts this pass silently', () async {
      // What every database from before the marker existed looks like: cursors
      // in place, no record of the floor they were born from.
      await store.setDeltaLink('inbox', deltaCursor('inbox', 'pre'));
      await store.setDeltaLink('sentitems', deltaCursor('sentitems', 'pre'));
      expect(await store.getPref(mailBootstrapFloorKey), isNull);

      final before = midnightDaysAgo(14);
      await syncReaching(() => 14).syncNow();
      final after = midnightDaysAgo(14);

      // Silence is not "never drained anything": reading it that way would
      // make the first sync after every upgrade re-drain for nothing.
      expect(graph.requestsFor('inbox').single.toString(),
          deltaCursor('inbox', 'pre'));
      expect(graph.requestsFor('sentitems').single.toString(),
          deltaCursor('sentitems', 'pre'));
      expect(await store.getPref(mailBootstrapFloorKey), anyOf(before, after));
    });

    test('an empty marker reads as no marker, and is written over', () async {
      // A pref is TEXT and this one is compared as a string: left in place, an
      // empty marker would sort below every real floor and quietly disable
      // widening forever. It reads as absent instead — adopted over, exactly
      // like the upgrade case above.
      await store.setDeltaLink('inbox', deltaCursor('inbox', 'pre'));
      await store.setDeltaLink('sentitems', deltaCursor('sentitems', 'pre'));
      await store.setPref(mailBootstrapFloorKey, '');

      final before = midnightDaysAgo(14);
      await syncReaching(() => 14).syncNow();
      final after = midnightDaysAgo(14);

      expect(graph.requestsFor('inbox').single.toString(),
          deltaCursor('inbox', 'pre'),
          reason: 'adoption, not a widen: the cursor is still what drains');
      expect(await store.getPref(mailBootstrapFloorKey), anyOf(before, after));
    });

    test('a widen that only half landed is detected again next pass', () async {
      final before = midnightDaysAgo(14);
      await syncReaching(() => 14).syncNow();
      final after = midnightDaysAgo(14);
      final fortnight = anyOf(before, after);
      graph.requests.clear();

      // The inbox re-drains; the sent folder never answers.
      graph.queue('inbox', [() => emptyPage('inbox', 'half')]);
      graph.queue('sentitems', [
        () => http.Response('{"error":{"code":"serverError"}}', 500),
      ]);

      await expectLater(
        syncReaching(() => 90).syncNow(),
        throwsA(isA<GraphMailException>()),
      );

      // The marker is what says a widen is still owed, so it moves only once
      // BOTH folders have come back.
      expect(await store.getPref(mailBootstrapFloorKey), fortnight);
      graph.requests.clear();

      graph.queue('inbox', [() => emptyPage('inbox', 'whole')]);
      graph.queue('sentitems', [() => emptyPage('sentitems', 'whole')]);
      final wideBefore = midnightDaysAgo(90);
      await syncReaching(() => 90).syncNow();
      final wideAfter = midnightDaysAgo(90);

      final wider = anyOf(wideBefore, wideAfter);
      expect(floorOf(graph.requestsFor('inbox').single), wider,
          reason: 'the inbox drains from the wide floor a second time rather '
              'than resuming the cursor its half-done pass left behind');
      expect(floorOf(graph.requestsFor('sentitems').single), wider);
      expect(await store.getPref(mailBootstrapFloorKey), wider);
    });
  });

  group('what the backfill is allowed to change', () {
    /// A mailbox synced at a fortnight, with one thread in it, and the cursors
    /// and marker a widen needs something to widen from.
    Future<void> syncedAtAFortnight(
      List<Map<String, dynamic>> inbox,
    ) async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(inbox, deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      await syncReaching(() => 14).syncNow();
      graph.requests.clear();
    }

    test('a message from behind the old floor leaves a done thread done',
        () async {
      final recent = isoAgo(const Duration(days: 2));
      await syncedAtAFortnight([
        graphMessage(id: 'm1', receivedDateTime: recent),
      ]);
      // The human decision the backfill must not undo.
      await store.setConversationState(
          'email', 'c1', ConversationState.done);

      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm0',
                receivedDateTime: isoAgo(const Duration(days: 30)),
              ),
            ], deltaLink: deltaCursor('inbox', 'c2'))),
      ]);
      await syncReaching(() => 90).syncNow();

      final row = await conversation('c1');
      expect(row['state'], 'done',
          reason: 'mail that arrived a month ago cannot reopen a thread the '
              'user closed last week');
      // The record of the thread is genuinely more complete, and says so.
      expect(row['message_count'], 2);
      expect(row['inbound_count'], 2);
      expect(await store.getMessageRow('email', 'm0'), isNotNull);
      // The watermark still ran through `_newer`, which only moves forward —
      // the backfilled message is older, so the newest inbound is still m1.
      expect(row['last_inbound_at'], recent);
    });

    test('a reply from behind the old floor answers nothing', () async {
      // The ask is three weeks old and already in the database: an incremental
      // cursor pass delivered it when it was fresh, back when this mailbox was
      // set to a fortnight. Nothing has answered it since.
      await store.setDeltaLink('inbox', deltaCursor('inbox', 'pre'));
      await store.setDeltaLink('sentitems', deltaCursor('sentitems', 'pre'));
      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm1',
                receivedDateTime: isoAgo(const Duration(days: 20)),
              ),
            ], deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      await syncReaching(() => 14).syncNow();
      graph.requests.clear();

      expect((await conversation('c1'))['state'], 'needs_reply');
      await store.updateConversationTriage(
        'email',
        'c1',
        ctaText: 'Send the updated figures',
        ctaUrgency: 'normal',
      );

      // Older than the fortnight the last bootstrap drained from, and so
      // backfill — but NEWER than the ask, which is what would otherwise make
      // it that ask's answer.
      final reply = isoAgo(const Duration(days: 15));
      graph.queue('sentitems', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm2',
                receivedDateTime: reply,
                to: const ['sarah@example.test'],
              ),
            ], deltaLink: deltaCursor('sentitems', 'c2'))),
      ]);
      await syncReaching(() => 90).syncNow();

      final row = await conversation('c1');
      expect(row['state'], 'needs_reply',
          reason: 'the user has been looking at this ask for three weeks; a '
              'widened window turning up an old sent message does not mean '
              'they answered it');
      expect(row['cta_text'], 'Send the updated figures',
          reason: 'and it must not take the live ask off the thread either');
      expect(row['last_outbound_at'], reply,
          reason: 'the thread had no outbound at all, so the backfill is the '
              'newest one there is');
    });

    test('an in-window message in the same page still escalates', () async {
      await syncedAtAFortnight(const []);

      graph.queue('inbox', [
        () => jsonOk(deltaBody([
              graphMessage(
                id: 'm0',
                conversationId: 'c2',
                receivedDateTime: isoAgo(const Duration(days: 30)),
              ),
              graphMessage(
                id: 'm3',
                conversationId: 'c2',
                receivedDateTime: isoAgo(const Duration(hours: 1)),
              ),
            ], deltaLink: deltaCursor('inbox', 'c2'))),
      ]);
      await syncReaching(() => 90).syncNow();

      // The guard is scoped by DATE, not by pass: the widen drain carries both
      // history and this morning's mail, and only the history is quiet.
      expect((await conversation('c2'))['state'], 'needs_reply');
    });
  });
}
