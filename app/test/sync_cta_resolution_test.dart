import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/conversation_state.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What the user's own reply does to a thread's standing CTA.
///
/// The composer's send path clears the CTA directly; these tests cover the
/// other half of that promise — a reply written in Outlook or on a phone
/// arrives through sync, and the ask it answers must not keep haunting
/// NEEDS YOU as a dimmed row nothing will ever resolve.
///
/// The Graph stub is deliberately duplicated from sync_extract_test rather
/// than shared, so neither file can break the other by editing it.

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
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

Map<String, dynamic> graphMessage({
  required String id,
  String conversationId = 'conv-1',
  String fromAddress = 'sarah@example.com',
  String? internetMessageId,
  required String receivedDateTime,
}) =>
    {
      'id': id,
      'conversationId': conversationId,
      'internetMessageId': ?internetMessageId,
      'subject': 'Contract review',
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

class GraphStub {
  final Map<String, List<http.Response Function()>> pages = {};

  void queue(String folder, List<http.Response Function()> responses) {
    pages[folder] = [...responses];
  }

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
        if (request.url.path.endsWith('/messages/delta')) {
          final folder =
              request.url.path.contains('sentitems') ? 'sentitems' : 'inbox';
          final queued = pages[folder];
          if (queued == null || queued.isEmpty) {
            return jsonOk({
              'value': const [],
              '@odata.deltaLink': deltaCursor(folder, 'empty'),
            });
          }
          return queued.removeAt(0)();
        }
        return http.Response('unexpected ${request.url}', 404);
      });
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late GraphStub graph;
  late SyncService sync;

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
      // The recorder the sync writes progress through — the same one that
      // takes the Needs You chip off a thread the user has answered.
      progress: PipelineProgress(store),
    );
  });

  tearDown(() async => db.close());

  void queueInbound(List<Map<String, dynamic>> messages, {String token = 'c1'}) {
    graph.queue('inbox', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('inbox', token),
          }),
    ]);
  }

  void queueSent(List<Map<String, dynamic>> messages, {String token = 's1'}) {
    graph.queue('sentitems', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('sentitems', token),
          }),
    ]);
  }

  Future<Map<String, Object?>?> row() =>
      store.getConversationRow('email', 'conv-1');

  test('a reply synced from the server clears the CTA and folds to waiting',
      () async {
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueSent([
      graphMessage(
        id: 'sent-1',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 1)),
      ),
    ]);
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateWaiting);
    expect(r?['cta_text'], isNull);
    expect(r?['cta_urgency'], 'normal');
  });

  test('an outbound OLDER than the newest inbound clears nothing', () async {
    // A sent-folder backfill of an old reply answers nothing the thread is
    // currently asking; the fold refuses to go quiet and so does the CTA.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueSent([
      graphMessage(
        id: 'sent-old',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 3)),
      ),
    ]);
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateNeedsReply);
    expect(r?['cta_text'], 'Review the contract sent earlier');
    expect(r?['cta_urgency'], 'high');
  });

  test('a new inbound message leaves the CTA alone', () async {
    // The extract worker owns what an inbound does to the ask — sync clearing
    // it here would race the fresher CTA that worker is about to write.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueInbound([
      graphMessage(id: 'in-2', receivedDateTime: fresh(const Duration(hours: 1))),
    ], token: 'c2');
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateNeedsReply);
    expect(r?['cta_text'], 'Review the contract sent earlier');
  });

  test('a reply clears a CTA that arrived while the thread was already waiting',
      () async {
    // The extract can pin an ask on a thread the state machine already calls
    // quiet ("review the attachment"). A later reply still resolves it.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 3))),
    ]);
    queueSent([
      graphMessage(
        id: 'sent-1',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 2)),
      ),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the attachment',
      ctaUrgency: 'normal',
    );

    queueSent([
      graphMessage(
        id: 'sent-2',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 1)),
      ),
    ], token: 's2');
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateWaiting);
    expect(r?['cta_text'], isNull);
  });
  /// The chip is earned at settle time and survives being read. A reply the
  /// user sent — from here, from Outlook, from a phone — is what takes it off.
  group('the Needs You chip', () {
    /// The chip on the messages that were asking — the user's own mail is not
    /// one of them, and lands with the column at 0 whatever happens here.
    Future<List<Object?>> needsYouOn(String key) async => [
          for (final row in await db
              .customSelect(
                'SELECT p.needs_you FROM message_progress p '
                'JOIN messages m ON m.source = p.source '
                '  AND m.source_message_id = p.source_message_id '
                "WHERE p.conversation_key = ? AND m.direction = 'inbound' "
                'ORDER BY p.source_message_id',
                variables: [Variable(key)],
              )
              .get())
            row.data['needs_you'],
        ];

    Future<void> markAsking() => db.customUpdate(
          'UPDATE message_progress SET needs_you = 1',
        );

    test('a synced reply takes it off every message of the thread', () async {
      queueInbound([
        graphMessage(
            id: 'in-1', receivedDateTime: fresh(const Duration(hours: 2))),
      ]);
      await sync.syncNow();
      await store.updateConversationTriage(
        'email',
        'conv-1',
        ctaText: 'Review the contract sent earlier',
        ctaUrgency: 'high',
      );
      await markAsking();

      queueSent([
        graphMessage(
          id: 'sent-1',
          fromAddress: 'lo@bond.com',
          receivedDateTime: fresh(const Duration(hours: 1)),
        ),
      ]);
      await sync.syncNow();

      expect(await needsYouOn('conv-1'), [0]);
    });

    test('and an outbound that answers nothing leaves it standing', () async {
      queueInbound([
        graphMessage(
            id: 'in-1', receivedDateTime: fresh(const Duration(hours: 1))),
      ]);
      await sync.syncNow();
      await markAsking();

      queueSent([
        graphMessage(
          id: 'sent-old',
          fromAddress: 'lo@bond.com',
          receivedDateTime: fresh(const Duration(hours: 3)),
        ),
      ]);
      await sync.syncNow();

      expect(await needsYouOn('conv-1'), [1]);
    });
  });

  /// What the drain does about the row a mail send wrote for itself.
  ///
  /// The echo carries the internet message id the Sent Items copy will carry
  /// and an id the server has never heard of, so without the delete inside the
  /// page transaction the thread would end up holding the same message twice —
  /// once under `local:` forever.
  group('the local echo', () {
    const messageId = '<reply-1@bond.local>';

    /// The row the send writes: the draft's id, the body typed here, gated
    /// exactly as a Sent Items copy is.
    Future<void> seedEcho(String sentAt) => store.insertLocalEcho({
          'source': 'email',
          'source_message_id': 'local:draft-1',
          'internet_message_id': messageId,
          'conversation_key': 'conv-1',
          'direction': 'outbound',
          'received_at': sentAt,
          'body_text': 'Friday works.',
          'body_preview': 'Friday works.',
          'is_read': 1,
          'triage_status': 'skipped',
          'gate_reason': 'outbound',
        });

    Future<List<Map<String, Object?>>> outbound() async {
      final rows = await db
          .customSelect(
            "SELECT * FROM messages WHERE direction = 'outbound' "
            'ORDER BY source_message_id',
          )
          .get();
      return [for (final r in rows) r.data];
    }

    Future<List<String>> progressIds() async {
      final rows = await db
          .customSelect(
            'SELECT source_message_id FROM message_progress ORDER BY 1',
          )
          .get();
      return [for (final r in rows) r.data['source_message_id'] as String];
    }

    test('a Sent Items copy replaces the echo with the same internet message '
        'id', () async {
      final inboundAt = fresh(const Duration(hours: 2));
      final sentAt = fresh(const Duration(hours: 1));
      queueInbound([graphMessage(id: 'in-1', receivedDateTime: inboundAt)]);
      await sync.syncNow();
      await seedEcho(sentAt);

      // Graph's own copy: same internet message id, an id of its own.
      queueSent([
        graphMessage(
          id: 'sent-1',
          fromAddress: 'lo@bond.com',
          internetMessageId: messageId,
          receivedDateTime: sentAt,
        ),
      ]);
      await sync.syncNow();

      final rows = await outbound();
      expect(rows, hasLength(1), reason: 'one message, one row');
      expect(rows.single['source_message_id'], 'sent-1');
      expect(await progressIds(), ['in-1', 'sent-1'],
          reason: 'the echo\'s progress row went with it');
      final conversation = (await row())!;
      expect(conversation['message_count'], 2);
      expect(conversation['inbound_count'], 1);
      expect(conversation['state'], stateWaiting);
      expect(conversation['last_outbound_at'], sentAt);
    });

    test('and folds it, because the real row is a true first sighting',
        () async {
      // The delete runs BEFORE `hasMessage`, so the copy that lands is news to
      // the fold and resolves the ask exactly as a reply from Outlook would.
      final inboundAt = fresh(const Duration(hours: 2));
      final sentAt = fresh(const Duration(hours: 1));
      queueInbound([graphMessage(id: 'in-1', receivedDateTime: inboundAt)]);
      await sync.syncNow();
      await store.updateConversationTriage(
        'email',
        'conv-1',
        ctaText: 'Review the contract sent earlier',
        ctaUrgency: 'high',
      );
      await seedEcho(sentAt);

      queueSent([
        graphMessage(
          id: 'sent-1',
          fromAddress: 'lo@bond.com',
          internetMessageId: messageId,
          receivedDateTime: sentAt,
        ),
      ]);
      await sync.syncNow();

      final conversation = (await row())!;
      expect(conversation['cta_text'], isNull);
      expect(conversation['state'], stateWaiting);
    });

    test('a Sent Items copy with no echo folds as before', () async {
      final inboundAt = fresh(const Duration(hours: 2));
      final sentAt = fresh(const Duration(hours: 1));
      queueInbound([graphMessage(id: 'in-1', receivedDateTime: inboundAt)]);
      await sync.syncNow();

      queueSent([
        graphMessage(
          id: 'sent-1',
          fromAddress: 'lo@bond.com',
          internetMessageId: messageId,
          receivedDateTime: sentAt,
        ),
      ]);
      await sync.syncNow();

      final rows = await outbound();
      expect(rows.single['source_message_id'], 'sent-1');
      expect((await row())!['state'], stateWaiting);
      expect((await row())!['message_count'], 2);
    });

    test('a replay of the same page does not resurrect the echo', () async {
      final sentAt = fresh(const Duration(hours: 1));
      queueInbound([
        graphMessage(
          id: 'in-1',
          receivedDateTime: fresh(const Duration(hours: 2)),
        ),
      ]);
      await sync.syncNow();
      await seedEcho(sentAt);

      final copy = graphMessage(
        id: 'sent-1',
        fromAddress: 'lo@bond.com',
        internetMessageId: messageId,
        receivedDateTime: sentAt,
      );
      queueSent([copy]);
      await sync.syncNow();
      // A delta feed legitimately replays: across pages, and wholesale after a
      // 410. The second pass has nothing to delete and nothing to fold.
      queueSent([copy], token: 's2');
      await sync.syncNow();

      final rows = await outbound();
      expect(rows, hasLength(1));
      expect(rows.single['source_message_id'], 'sent-1');
      expect((await row())!['message_count'], 2);
    });

    test('an echo whose copy has not arrived is left alone', () async {
      // The reply is on screen and stays there. Nothing in a drain that never
      // reaches this message may touch it.
      final sentAt = fresh(const Duration(hours: 1));
      queueInbound([
        graphMessage(
          id: 'in-1',
          receivedDateTime: fresh(const Duration(hours: 2)),
        ),
      ]);
      await sync.syncNow();
      await seedEcho(sentAt);

      queueSent(const [], token: 's-empty');
      await sync.syncNow();

      final rows = await outbound();
      expect(rows.single['source_message_id'], 'local:draft-1');
      expect(rows.single['body_text'], 'Friday works.');
    });
  });
}
