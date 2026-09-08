import 'dart:convert';

import 'package:bond_inbox/data/database.dart' hide ActivityEvent;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The safety net beside the delta feed.
///
/// Graph's delta feed has been seen to skip a message — two of nine inbound on
/// one day, both present in a fresh enumeration hours later — so every ten
/// minutes the mail pass re-enumerates the last day of each folder from
/// scratch and ingests whatever it has never seen. The whole design rests on
/// one rule, and it is the rule these tests exist to keep: **the reconcile
/// never stores a cursor**. Graph hands a `deltaLink` back for a from-scratch
/// walk exactly as it does for a delta drain, and storing that one would rewind
/// the folder's position to now — losing every change behind it — and stamp
/// `synced_at`, which is the field the vacation rule reads to decide how far a
/// pass reaches back. A safety net that quietly deleted mail would be worse
/// than none.
///
/// The rest is cadence, reporting and blast radius: it runs at most once per
/// [reconcileEvery], it says what it caught rather than that it ran, and a
/// failure inside it costs the net and never the sync.
///
/// The harness is duplicated from sync_lookback_test / sync_extract_test rather
/// than shared, on the principle those files state: neither test can break the
/// other by editing it.

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

/// A finished, empty drain — with the deltaLink a real one carries, which is
/// the whole point on the reconcile's side of the queue.
http.Response emptyPage(String folder) => jsonOk({
      'value': const [],
      '@odata.deltaLink': deltaCursor(folder, 'done'),
    });

Map<String, dynamic> graphMessage({
  required String id,
  String? conversationId = 'conv-1',
  String subject = 'Project brief',
  String fromAddress = 'sarah@example.com',
  required String receivedDateTime,
}) =>
    {
      'id': id,
      'conversationId': ?conversationId,
      'subject': subject,
      'from': {
        'emailAddress': {'name': 'Sarah', 'address': fromAddress}
      },
      'toRecipients': [
        {
          'emailAddress': {'name': null, 'address': 'lo@bond.com'}
        }
      ],
      'receivedDateTime': receivedDateTime,
      'isRead': false,
      'isDraft': false,
      'bodyPreview': 'Preview text',
    };

Map<String, dynamic> deltaBody(
  List<Map<String, dynamic>> messages, {
  String? deltaLink,
}) =>
    {'value': messages, '@odata.deltaLink': ?deltaLink};

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
  late SyncService sync;

  /// Inside the sync floor, and so inside the AI window with it.
  String fresh(Duration ago) =>
      DateTime.now().toUtc().subtract(ago).toIso8601String();

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = GraphStub();

    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;

    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    sync = SyncService(
      GraphMail(auth, httpClient: graph.client),
      store,
      // A real log, because half of what this phase built is what the pass
      // says it did.
      activityLog: ActivityLog(store),
      lookbackDays: () => syncFloorDays,
    );
  });

  tearDown(() async => db.close());

  /// The `$filter`'s timestamp, with the operator stripped.
  String floorOf(Uri request) {
    final filter = request.queryParameters[r'$filter'];
    expect(filter, startsWith('receivedDateTime ge '),
        reason: r'the floor rides on the delta request as a $filter');
    return filter!.replaceFirst('receivedDateTime ge ', '');
  }

  Future<List<ActivityEvent>> events(String kind) async => [
        for (final row in await store.recentActivity(limit: 300))
          if (row['kind'] == kind) ActivityEvent.fromRow(row),
      ];

  Future<List<String>> queuedIds({String kind = 'extract'}) async => [
        for (final row in await db
            .customSelect(
              'SELECT entity_id FROM work_items WHERE task_kind = ? '
              'ORDER BY entity_id',
              variables: [Variable<String>(kind)],
            )
            .get())
          row.data['entity_id'] as String,
      ];

  /// Both folders left where a settled mailbox leaves them: a cursor on the
  /// inbox, and a last-sync stamp old enough that this pass's floor is that
  /// stamp rather than the rolling fortnight. Order matters — `setDeltaLink`
  /// stamps `synced_at` as a side effect, so the stamp is written second.
  Future<String> settledMailbox() async {
    await store.setDeltaLink('inbox', deltaCursor('inbox', 'stale'));
    final away = isoDaysAgo(2);
    await store.setSyncedAt('inbox', away);
    await store.setSyncedAt('sentitems', away);
    return away;
  }

  void expectStampedNow(String? stamp) {
    expect(stamp, isNotNull);
    final parsed = DateTime.tryParse(stamp!);
    expect(parsed, isNotNull, reason: 'the stamp has to be re-readable');
    expect(
      DateTime.now().toUtc().difference(parsed!.toUtc()).abs(),
      lessThan(const Duration(minutes: 2)),
    );
  }

  test('with no stamp, the pass re-enumerates the last day and leaves the '
      'cursor alone', () async {
    final away = await settledMailbox();

    graph.queue('inbox', [
      // The ordinary drain: a page with neither a nextLink nor a deltaLink, so
      // it cannot move the cursor and anything that did move it afterwards is
      // the reconcile.
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'seen-1',
                receivedDateTime: fresh(const Duration(hours: 2)),
              ),
            ],
          }),
      // The reconcile, carrying the message the feed never handed over — and a
      // deltaLink that must go nowhere near the store.
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'skipped-1',
                conversationId: 'conv-s',
                subject: 'The one the feed skipped',
                receivedDateTime: fresh(const Duration(hours: 3)),
              ),
            ],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);

    await sync.syncNow();

    final inbox = graph.requestsFor('inbox');
    expect(inbox.length, 2, reason: 'the ordinary drain, then the reconcile');
    expect(inbox.first.toString(), deltaCursor('inbox', 'stale'));
    expect(inbox[1].queryParameters.containsKey(r'$deltatoken'), isFalse,
        reason: 'a reconcile enumerates from scratch, cursor and all');
    expect(
      DateTime.parse(floorOf(inbox[1]))
          .difference(DateTime.now().toUtc().subtract(reconcileWindow))
          .abs(),
      lessThan(const Duration(minutes: 2)),
    );

    // The rule the whole design rests on.
    expect(await store.getDeltaLink('inbox'), deltaCursor('inbox', 'stale'));
    expect(await store.getSyncedAt('inbox'), away);

    expect(await store.hasMessage('email', 'skipped-1'), isTrue);
    expectStampedNow(await store.getPref(mailLastReconcileKey));

    // The sent folder gets the same two passes, whether or not it has news.
    expect(graph.requestsFor('sentitems').length, 2);
  });

  test('a stamp younger than the cadence skips the reconcile', () async {
    await settledMailbox();
    final recent = MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(const Duration(minutes: 3)),
    );
    await store.setPref(mailLastReconcileKey, recent);

    await sync.syncNow();

    expect(graph.requestsFor('inbox').length, 1);
    expect(graph.requestsFor('sentitems').length, 1);
    // Untouched to the character: a skipped reconcile must not restart the
    // ten-minute clock, or a mailbox polled every minute would never reconcile.
    expect(await store.getPref(mailLastReconcileKey), recent);
  });

  test('a stamp older than the cadence runs it', () async {
    await settledMailbox();
    final stale = MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(const Duration(minutes: 11)),
    );
    await store.setPref(mailLastReconcileKey, stale);

    await sync.syncNow();

    expect(graph.requestsFor('inbox').length, 2);
    final moved = await store.getPref(mailLastReconcileKey);
    expect(moved, isNot(stale));
    expectStampedNow(moved);
  });

  test('a replay is not counted and not re-folded', () async {
    await settledMailbox();
    final message = graphMessage(
      id: 'seen-1',
      receivedDateTime: fresh(const Duration(hours: 2)),
    );

    graph.queue('inbox', [
      () => jsonOk({'value': [message]}),
      // The same message again, which is what a healthy reconcile mostly sees.
      () => jsonOk(deltaBody(
            [message],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);

    await sync.syncNow();

    expect(await store.hasMessage('email', 'seen-1'), isTrue);

    final mail = await events('sync_mail');
    expect(mail, hasLength(1));
    expect(mail.first.detail.containsKey('reconciled'), isFalse);
    expect(await events('sync_reconcile'), isEmpty);

    // The fold is the expensive half of the idempotence: a second fold would
    // reopen threads a human had closed.
    final conversation = await store.getConversationRow('email', 'conv-1');
    expect(conversation?['inbound_count'], 1);
  });

  test('what it finds is reported by subject', () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'seen-1',
                receivedDateTime: fresh(const Duration(hours: 2)),
              ),
            ],
          }),
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'skipped-1',
                conversationId: 'conv-s',
                subject: 'The one the feed skipped',
                receivedDateTime: fresh(const Duration(hours: 3)),
              ),
            ],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);
    graph.queue('sentitems', [
      () => jsonOk({'value': const []}),
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'sent-skipped',
                conversationId: 'conv-t',
                subject: 'The reply it never listed',
                fromAddress: 'lo@bond.com',
                receivedDateTime: fresh(const Duration(hours: 4)),
              ),
            ],
            deltaLink: deltaCursor('sentitems', 'reconcile-must-not-store'),
          )),
    ]);

    await sync.syncNow();

    final mail = await events('sync_mail');
    expect(mail.first.detail['reconciled'], 2);

    final reconcile = await events('sync_reconcile');
    expect(reconcile, hasLength(1));
    expect(reconcile.first.count, 2);
    expect(reconcile.first.detail['inbox'], 1);
    expect(reconcile.first.detail['sent'], 1);
    // Inbox first, because that is the order the pass walks them.
    expect(reconcile.first.detail['subjects'], [
      'The one the feed skipped',
      'The reply it never listed',
    ]);
  });

  test('nothing is reported when it finds nothing', () async {
    await settledMailbox();

    graph.queue('inbox', [
      // News on the ordinary drain, so the (quiet-suppressed) `sync_mail` row
      // is written at all and can be read for the absence below.
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'seen-1',
                receivedDateTime: fresh(const Duration(hours: 2)),
              ),
            ],
          }),
      // And an empty reconcile, which is what every healthy pass looks like.
      () => emptyPage('inbox'),
    ]);

    await sync.syncNow();

    final mail = await events('sync_mail');
    expect(mail, hasLength(1));
    expect(mail.first.detail.containsKey('reconciled'), isFalse);
    expect(await events('sync_reconcile'), isEmpty);
  });

  test('a reconciled message is pending triage and gets its extract work row '
      'in the same pass', () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({'value': const []}),
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'skipped-1',
                conversationId: 'conv-s',
                subject: 'The one the feed skipped',
                receivedDateTime: fresh(const Duration(hours: 3)),
              ),
            ],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);

    await sync.syncNow();

    final row = await store.getMessageRow('email', 'skipped-1');
    expect(row?['triage_status'], 'pending');
    // The backlog enqueue runs after the drains, so a message the reconcile
    // caught is filed by the same pass rather than waiting for the next one.
    expect(await queuedIds(), contains('skipped-1'));
  });

  test('a 410 inside the reconcile costs the safety net, never the sync',
      () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'fresh-1',
                receivedDateTime: fresh(const Duration(hours: 1)),
              ),
            ],
          }),
      // A reconcile holds no cursor, so this is a server hiccup rather than
      // the recoverable state the ordinary drain treats a 410 as.
      () => http.Response('{"error":{"code":"resyncRequired"}}', 410),
    ]);

    await sync.syncNow();

    final mail = await events('sync_mail');
    expect(mail, hasLength(1));
    expect(mail.first.status, 'ok');
    expect(mail.first.detail['reconcile_error'], isA<String>());
    expect((mail.first.detail['reconcile_error'] as String).isNotEmpty, isTrue);

    expect(await queuedIds(), contains('fresh-1'));
    // Stamped anyway, so a reconcile that fails every time retries on its own
    // cadence rather than on every sixty-second poll.
    expectStampedNow(await store.getPref(mailLastReconcileKey));
  });

  test('a server error inside the reconcile costs the safety net, never the '
      'sync', () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'fresh-1',
                receivedDateTime: fresh(const Duration(hours: 1)),
              ),
            ],
          }),
      () => http.Response('boom', 500),
    ]);

    await sync.syncNow();

    final mail = await events('sync_mail');
    expect(mail, hasLength(1));
    expect(mail.first.status, 'ok');
    expect((mail.first.detail['reconcile_error'] as String).isNotEmpty, isTrue);
    expect(await queuedIds(), contains('fresh-1'));
    expectStampedNow(await store.getPref(mailLastReconcileKey));
  });

  test('a failure in the sent half keeps what the inbox half found', () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({'value': const []}),
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'skipped-1',
                conversationId: 'conv-s',
                subject: 'The one the feed skipped',
                receivedDateTime: fresh(const Duration(hours: 3)),
              ),
            ],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);
    graph.queue('sentitems', [
      () => jsonOk({'value': const []}),
      () => http.Response('boom', 500),
    ]);

    await sync.syncNow();

    // The inbox page committed before the sent request went out, and a
    // failure after it is a fact about the net, not a reason to unsay the
    // message it already caught: both the count and the row report it.
    expect(await store.hasMessage('email', 'skipped-1'), isTrue);
    final mail = await events('sync_mail');
    expect(mail.first.detail['reconciled'], 1);
    expect((mail.first.detail['reconcile_error'] as String).isNotEmpty, isTrue);
    final reconcile = await events('sync_reconcile');
    expect(reconcile, hasLength(1));
    expect(reconcile.first.detail['inbox'], 1);
    expect(reconcile.first.detail['sent'], 0);
  });

  test('the subjects list is capped at ten', () async {
    await settledMailbox();

    graph.queue('inbox', [
      () => jsonOk({'value': const []}),
      () => jsonOk(deltaBody(
            [
              for (var i = 0; i < 12; i++)
                graphMessage(
                  id: 'skipped-$i',
                  conversationId: 'conv-$i',
                  subject: 'Skipped $i',
                  receivedDateTime: fresh(Duration(hours: i + 1)),
                ),
            ],
            deltaLink: deltaCursor('inbox', 'reconcile-must-not-store'),
          )),
    ]);

    await sync.syncNow();

    final reconcile = await events('sync_reconcile');
    expect(reconcile, hasLength(1));
    // The count is the truth; the subjects are a sample of it. A bad day must
    // not write a mailbox listing into the activity log.
    expect(reconcile.first.count, 12);
    expect((reconcile.first.detail['subjects'] as List).length, 10);
  });
}
