import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
// `show`: the one thing this file wants from the embedding client is the pair
// of tags the clustering one-shot moves between.
import 'package:bond_inbox/services/llm/embeddings_client.dart'
    show EmbeddingsClient;
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
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

  SyncService syncReaching(
    int lookbackDays, {
    Future<({int repaired, bool complete})> Function()?
        repairGatedConversations,
    Future<({int redecided, bool complete})> Function()? redecide,
    PipelineProgress? progress,
    String? userAddress,
  }) {
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
      repairGatedConversations: repairGatedConversations,
      redecide: redecide,
      lookbackDays: () => lookbackDays,
      progress: progress,
      userAddress: userAddress == null ? null : () async => userAddress,
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

    test('the meeting regate runs once, refolds, and reports its count',
        () async {
      // A meeting response triaged before the gate existed: still kept, and
      // its thread still asking for a reply nobody owes anyone.
      await store.upsertMessage({
        'source_message_id': 'accepted',
        'conversation_key': 'resp',
        'direction': 'inbound',
        'from_address': 'colleague@example.com',
        'subject': 'Accepted: Weekly sync',
        'received_at': isoAgo(const Duration(hours: 20)),
        'triage_status': 'triaged',
        'source_meta_json': '{"meeting":"meetingAccepted"}',
      });
      await store.upsertConversation({
        'conversation_key': 'resp',
        'state': 'needs_reply',
      });

      await syncReaching(14).syncNow();

      final row = (await store.getMessageRow('email', 'accepted'))!;
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'meeting_response');
      // The refold is paired with the regate: a gated row falls out of
      // "kept", so the thread stops asking.
      expect((await conversation('resp'))['state'], 'waiting');
      expect(await store.getPref('meeting_regate_crlf'), '1');
      expect((await syncMailDetail())['regated_meeting_responses'], 1);

      // Once, and the pref is what says so. A later pass omits the key
      // rather than reporting a zero.
      graph.requests.clear();
      await syncReaching(14).syncNow();
      final named = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
            "AND detail_json LIKE '%regated_meeting_responses%'",
          )
          .getSingle();
      expect((named.data['n'] as num).toInt(), 1,
          reason: 'exactly one sync_mail row ever names the regate');
    });

    test('the meeting regate dismisses a suggested reply, and only that',
        () async {
      // Responses drafted for before this build: the thread leaves the rail,
      // and opening it must not still show a suggestion.
      for (final id in ['accepted', 'declined']) {
        await store.upsertMessage({
          'source_message_id': id,
          'conversation_key': 'k-$id',
          'direction': 'inbound',
          'from_address': 'colleague@example.com',
          'subject': 'Accepted: Weekly sync',
          'received_at': isoAgo(const Duration(hours: 20)),
          'triage_status': 'triaged',
          'source_meta_json': '{"meeting":"meetingAccepted"}',
        });
      }
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'k-accepted',
        replyToMessageId: 'accepted',
        body: 'Thanks, see you there.',
      );
      // An edited draft is the owner's own work and stays.
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'k-declined',
        replyToMessageId: 'declined',
        body: 'Sorry to miss it.',
        status: 'edited',
      );

      await syncReaching(14).syncNow();

      expect((await store.getDraftForMessage('email', 'accepted'))!['status'],
          'dismissed');
      expect((await store.getDraftForMessage('email', 'declined'))!['status'],
          'edited');
      expect((await syncMailDetail())['regated_meeting_responses'], 2);
    });

    test('the chips are reconciled under the probability rule, even where '
        'the verdict-era one-shots already ran', () async {
      // Every machine that ran an earlier build has the OLD pair set, so the
      // probability rule reconciles under keys of its own.
      await store.setPref('needs_you_flag_backfill', '1');
      await store.setPref('needs_you_flag_veto', '1');
      await store.setPref('needs_you_model_revive', '1');
      await store.setPref('needs_you_hedge_rejudge', '1');

      /// A settled inbound with a stale snapshot [chip] and probability [p].
      Future<void> settled(String id, {required double p, required int chip}) async {
        final at = isoAgo(const Duration(hours: 6));
        await store.upsertMessage({
          'source': 'email',
          'source_message_id': id,
          'conversation_key': 'k-$id',
          'direction': 'inbound',
          'from_address': 'sam@example.com',
          'subject': 'Numbers',
          'received_at': at,
          'triage_status': 'triaged',
        });
        await store.upsertConversation({
          'source': 'email',
          'conversation_key': 'k-$id',
          'subject': 'Numbers',
          'state': 'needs_reply',
          'last_inbound_at': at,
        });
        await store.writeNeedsYouP('email', id, p: p, reason: 'Judged.');
        await db.customUpdate(
          "UPDATE message_progress SET settle_state = 'done', needs_you = ? "
          'WHERE source_message_id = ?',
          variables: [Variable<int>(chip), Variable<String>(id)],
        );
      }

      await settled('owed-unchipped', p: 0.9, chip: 0);
      await settled('below-chipped', p: 0.1, chip: 1);

      await syncReaching(14, progress: PipelineProgress(store)).syncNow();

      Future<int?> chip(String id) async => ((await db
              .customSelect(
                'SELECT needs_you FROM message_progress '
                'WHERE source_message_id = ?',
                variables: [Variable<String>(id)],
              )
              .getSingle())
          .data['needs_you'] as num?)
          ?.toInt();
      // Each snapshot now says what the predicate says.
      expect(await chip('owed-unchipped'), 1);
      expect(await chip('below-chipped'), 0);
      expect(await store.getPref('needs_you_flag_backfill_p'), '1');
      expect(await store.getPref('needs_you_flag_veto_p'), '1');
      expect(MessageStore.derivedOneShotPrefs,
          containsAll(['needs_you_flag_backfill_p', 'needs_you_flag_veto_p']));
    });

    /// A triaged inbound with a stored decision, its probability on the row,
    /// and a `needs_you` work row that ended [status].
    Future<void> decided(
      String id, {
      required bool ownerKnown,
      String status = 'done',
    }) async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': 'k-$id',
        'direction': 'inbound',
        'from_address': 'sam@example.com',
        'subject': 'Numbers',
        'received_at': isoAgo(const Duration(hours: 5)),
        'triage_status': 'triaged',
      });
      await store.writeDecision(
        'email',
        id,
        fakeDecision(fakeAnswers(needsYou: 0.7)),
        qhash: decisionQhash,
        ownerKnown: ownerKnown,
      );
      await store.writeNeedsYouP('email', id, p: 0.7, reason: 'Judged.');
      // Answered, so the stale-triage re-pend leaves the row triaged.
      await db.customUpdate(
        'UPDATE messages SET reply_expected = 0 WHERE source_message_id = ?',
        variables: [Variable<String>(id)],
      );
      await store.enqueueWork('needs_you', 'email', id);
      await db.customUpdate(
        'UPDATE work_items SET status = ? WHERE entity_id = ?',
        variables: [Variable<String>(status), Variable<String>(id)],
      );
    }

    test('an ownerless decision puts the needs-you pass back on the queue',
        () async {
      await store.setPref('needs_you_model_revive', '1');
      await store.setPref('needs_you_hedge_rejudge', '1');
      await decided('ownerless', ownerKnown: false);
      await decided('owned', ownerKnown: true);

      await syncReaching(14, userAddress: 'owner@example.com').syncNow();

      expect(await store.workStatusOf('needs_you', 'email', 'ownerless'),
          'pending');
      expect(await store.workStatusOf('needs_you', 'email', 'owned'), 'done');
      expect((await syncMailDetail())['requeued_needs_you_ownerless'], 1);
    });

    test('the ownerless requeue revives only a finished work row', () async {
      // One the decision server keeps refusing is left in `error`: reviving
      // it here would cost a call per sync, forever, with its attempts reset
      // each time. Asked of the store directly, because the sync's own
      // interrupted-work revive has its own rules for errored rows.
      await decided('finished', ownerKnown: false);
      await decided('refused', ownerKnown: false, status: 'error');
      await decided('queued', ownerKnown: false, status: 'pending');

      expect(await store.requeueOwnerlessNeedsYou(), 1);
      expect(await store.workStatusOf('needs_you', 'email', 'finished'),
          'pending');
      expect(
          await store.workStatusOf('needs_you', 'email', 'refused'), 'error');
      expect(
          await store.workStatusOf('needs_you', 'email', 'queued'), 'pending');
    });

    test('and nothing is swept while the owner is still unknown', () async {
      // The pass would only keep each probability as it is: a whole queue
      // of no-ops on every sync.
      await store.setPref('needs_you_model_revive', '1');
      await store.setPref('needs_you_hedge_rejudge', '1');
      await decided('ownerless', ownerKnown: false);

      await syncReaching(14).syncNow();

      expect(await store.workStatusOf('needs_you', 'email', 'ownerless'),
          'done');
      expect(
        (await syncMailDetail()).containsKey('requeued_needs_you_ownerless'),
        isFalse,
      );
    });

    test('the hedge re-judge re-queues in-window 0.0 inbound once',
        () async {
      // Old hedges were stored as a verdict of 0, carried across as a
      // probability of 0.0, and cannot be told from a real no, so every
      // in-window 0.0 is asked again. Mail and chat alike; a yes, an undecided
      // row, an outbound and a row behind the floor are left alone.
      Future<void> judged(
        String id, {
        String source = 'email',
        double? p = 0.0,
        String direction = 'inbound',
        Duration ago = const Duration(hours: 20),
      }) async {
        await store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': 'k-$id',
          'direction': direction,
          'from_address': 'sam@example.com',
          'subject': 'Numbers',
          'received_at': isoAgo(ago),
          'triage_status': 'triaged',
        });
        if (p != null) {
          await store.writeNeedsYouP(source, id, p: p, reason: 'Judged.');
        }
        // Finished once already, which is the row the enqueue will never
        // offer again.
        await store.enqueueWork('needs_you', source, id);
        await db.customUpdate(
          "UPDATE work_items SET status = 'done' WHERE entity_id = ?",
          variables: [Variable<String>(id)],
        );
      }

      // The older revive one-shot re-asks every done row with no probability,
      // and it has closed on every installed machine. Closed here too, so the
      // undecided row below says what THIS one-shot leaves alone.
      await store.setPref('needs_you_model_revive', '1');
      await judged('mail-no');
      await judged('chat-no', source: 'teams');
      await judged('mail-yes', p: 0.9);
      await judged('mail-unjudged', p: null);
      await judged('sent-no', direction: 'outbound');
      await judged('old-no', ago: const Duration(days: 40));

      Future<Map<String, String>> statuses() async => {
            for (final row in (await db
                    .customSelect(
                      'SELECT entity_id, status FROM work_items '
                      "WHERE task_kind = 'needs_you'",
                    )
                    .get()))
              row.data['entity_id'] as String: row.data['status'] as String,
          };

      await syncReaching(14).syncNow();

      final after = await statuses();
      expect(after['mail-no'], 'pending');
      expect(after['chat-no'], 'pending');
      for (final id in ['mail-yes', 'mail-unjudged', 'sent-no', 'old-no']) {
        expect(after[id], 'done', reason: id);
      }
      expect(await store.getPref('needs_you_hedge_rejudge'), '1');
      expect((await syncMailDetail())['requeued_needs_you_hedges'], 2);
      expect(MessageStore.derivedOneShotPrefs,
          isNot(contains('needs_you_hedge_rejudge')));

      // Once: a row judged 0 again after the pref is set stays done.
      await db.customUpdate(
        "UPDATE work_items SET status = 'done' WHERE task_kind = 'needs_you'",
      );
      await syncReaching(14).syncNow();
      expect((await statuses())['mail-no'], 'done');
    });

    test('the retired label-rule gate re-pends once and reports its count',
        () async {
      // Rows a label rule gated before the rules left (v19): `label_rule` is
      // a gate this build no longer writes, so without the one-shot nothing
      // would ever read them again. One per connector inside the window, and
      // one outside it that the floor keeps out.
      Future<void> gated(String id, String source, Duration ago) =>
          store.upsertMessage({
            'source': source,
            'source_message_id': id,
            'conversation_key': 'k-$id',
            'direction': 'inbound',
            'from_address': 'alerts@tracker.example.com',
            'subject': '[CI] Build finished',
            'received_at': isoAgo(ago),
            'triage_status': 'skipped',
            'gate_reason': 'label_rule',
          });
      await gated('mail-gated', 'email', const Duration(hours: 20));
      await gated('chat-gated', 'teams', const Duration(hours: 20));
      await gated('old-gated', 'email', const Duration(days: 40));

      Future<Map<String, Object?>> progress(String source, String id) async =>
          (await db
                  .customSelect(
                    'SELECT triage_state, dropped, outcome FROM '
                    'message_progress WHERE source = ? '
                    'AND source_message_id = ?',
                    variables: [Variable<String>(source), Variable<String>(id)],
                  )
                  .getSingle())
              .data;
      // The gate wrote a dropped progress row, which is what the re-pend
      // has to take back as well as the message's own status.
      expect((await progress('email', 'mail-gated'))['dropped'], 1);

      await syncReaching(14).syncNow();

      // Queued in the SAME pass: the one-shot runs before the backlog
      // enqueues, so the row it flipped to `pending` is already a needs-you
      // work item rather than one a sync later.
      final queued = await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM work_items '
            "WHERE task_kind = 'needs_you' AND source = 'email' "
            "AND entity_id = 'mail-gated'",
          )
          .getSingle();
      expect((queued.data['n'] as num).toInt(), 1);

      for (final (source, id) in [
        ('email', 'mail-gated'),
        ('teams', 'chat-gated'),
      ]) {
        final row = (await store.getMessageRow(source, id))!;
        expect(row['triage_status'], 'pending', reason: id);
        expect(row['gate_reason'], null, reason: id);
        final p = await progress(source, id);
        expect(p['triage_state'], 'pending', reason: id);
        expect(p['dropped'], 0, reason: id);
        expect(p['outcome'], 'pending', reason: id);
      }
      final old = (await store.getMessageRow('email', 'old-gated'))!;
      expect(old['triage_status'], 'skipped');
      expect(old['gate_reason'], 'label_rule');
      expect(await store.getPref('label_rule_gate_retired'), '1');
      expect((await syncMailDetail())['repended_label_rule_gates'], 2);

      // Once, and the pref is what says so. A later pass omits the key
      // rather than reporting a zero.
      graph.requests.clear();
      await syncReaching(14).syncNow();
      final named = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
            "AND detail_json LIKE '%repended_label_rule_gates%'",
          )
          .getSingle();
      expect((named.data['n'] as num).toInt(), 1,
          reason: 'exactly one sync_mail row ever names the re-pend');
    });

    test('the Day 1 banner strip runs once over stored asks', () async {
      // A kept inbound, so the refold one-shot ahead of the strip sees a
      // thread with something to answer and leaves its banner standing.
      await store.upsertMessage({
        'source_message_id': 'ticket-1',
        'conversation_key': 'ticket',
        'direction': 'inbound',
        'from_address': 'tracker@example.com',
        'subject': 'New Request under EDA-100',
        'received_at': isoAgo(const Duration(hours: 20)),
        'triage_status': 'triaged',
      });
      await store.upsertConversation({
        'conversation_key': 'ticket',
        'state': 'needs_reply',
        'cta_text': 'Confirm the upstream source — by Day 1',
      });

      await syncReaching(14).syncNow();

      final rows = await db
          .customSelect(
            "SELECT cta_text FROM conversations WHERE conversation_key = 'ticket'",
          )
          .get();
      expect(rows.first.data['cta_text'], 'Confirm the upstream source');
      expect(await store.getPref('plan_relative_banner_strip'), '1');
      expect((await syncMailDetail())['stripped_plan_relative_banners'], 1);
    });

    test('a mailbox that ran the first regate is owed the CRLF one',
        () async {
      // The first key's pass read this `\r\n` body as somebody talking and
      // kept the row; its pref being set must not close the corrected pass.
      await store.setPref('meeting_regate', '1');
      await store.upsertMessage({
        'source_message_id': 'accepted',
        'conversation_key': 'resp',
        'direction': 'inbound',
        'from_address': 'colleague@example.com',
        'subject': 'Accepted: Weekly sync',
        'received_at': isoAgo(const Duration(hours: 20)),
        'triage_status': 'triaged',
        'body_text': '\r\n',
        'body_preview': '',
      });

      await syncReaching(14).syncNow();

      expect(
        (await store.getMessageRow('email', 'accepted'))!['gate_reason'],
        'meeting_response',
      );
      expect(await store.getPref('meeting_regate_crlf'), '1');
    });

    /// How many `sync_mail` rows name the gate repair at all — the twin of
    /// [reportedRefolds], and the honest question when a later pass is quiet
    /// enough to write no row of its own.
    Future<int> reportedGateRepairs() async {
      final rows = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
            "AND detail_json LIKE '%repaired_gated_conversations%'",
          )
          .getSingle();
      return (rows.data['n'] as num).toInt();
    }

    test('the gate repair runs once and reports what it repaired', () async {
      var calls = 0;
      Future<({int repaired, bool complete})> repair() async {
        calls++;
        return (repaired: 3, complete: true);
      }

      await syncReaching(14, repairGatedConversations: repair).syncNow();

      expect(calls, 1);
      expect(await store.getPref('gated_conversation_repair'), '1');
      expect((await syncMailDetail())['repaired_gated_conversations'], 3);

      graph.requests.clear();
      await syncReaching(14, repairGatedConversations: repair).syncNow();

      expect(calls, 1, reason: 'the pref is what makes it a one-shot');
      // Named on exactly one row, ever. A later pass omits the key rather
      // than reporting a zero, which would read as a repair that ran and
      // found nothing.
      expect(await reportedGateRepairs(), 1);
    });

    test('a sweep that failed is owed again, and the sync around it is fine',
        () async {
      var calls = 0;
      Future<({int repaired, bool complete})> repair() async {
        calls++;
        if (calls == 1) throw StateError('the database went away');
        return (repaired: 2, complete: true);
      }

      // The pref is written only after the sweep returns: a one-shot that
      // never ran must not be marked as done by the sync that watched it fail.
      await syncReaching(14, repairGatedConversations: repair).syncNow();
      expect(calls, 1);
      expect(await store.getPref('gated_conversation_repair'), isNull);
      expect(await reportedGateRepairs(), 0);

      graph.requests.clear();
      await syncReaching(14, repairGatedConversations: repair).syncNow();
      expect(calls, 2);
      expect(await store.getPref('gated_conversation_repair'), '1');
      expect((await syncMailDetail())['repaired_gated_conversations'], 2);
    });

    test('a capped pass keeps the one-shot owed until a pass comes back short',
        () async {
      var calls = 0;
      Future<({int repaired, bool complete})> repair() async {
        calls++;
        return (repaired: calls == 1 ? 200 : 40, complete: calls > 1);
      }

      await syncReaching(14, repairGatedConversations: repair).syncNow();
      expect(calls, 1);
      expect(await store.getPref('gated_conversation_repair'), isNull);
      expect((await syncMailDetail())['repaired_gated_conversations'], 200);

      graph.requests.clear();
      await syncReaching(14, repairGatedConversations: repair).syncNow();
      expect(calls, 2);
      expect(await store.getPref('gated_conversation_repair'), '1');
      expect((await syncMailDetail())['repaired_gated_conversations'], 40);

      graph.requests.clear();
      await syncReaching(14, repairGatedConversations: repair).syncNow();
      expect(calls, 2, reason: 'closed by the short pass');
    });

    test('a build wired without the repair does not consume the one-shot',
        () async {
      await syncReaching(14).syncNow();

      // A test build must leave the pref for the app that is owed the sweep.
      expect(await store.getPref('gated_conversation_repair'), isNull);
      expect(await reportedGateRepairs(), 0);
    });

    /// One conversation carrying a vector under [tag], and the kept inbound
    /// message that makes it the clustering pool's. [kept] false writes a
    /// gated message instead, which is a thread the assign pass turns away
    /// before it re-embeds anything.
    Future<void> seedVector(
      String source,
      String key,
      String tag, {
      bool kept = true,
    }) async {
      await store.upsertMessage({
        'source': source,
        'source_message_id': 'in-$source-$key',
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Subject',
        'from_name': 'Sarah',
        'from_address': 'sarah@example.test',
        'received_at': isoAgo(const Duration(days: 2)),
        'body_text': 'Body',
        'triage_status': kept ? 'triaged' : 'skipped',
        'gate_reason': kept ? null : 'no_reply',
      });
      await store.upsertConversationAi(
        source,
        key,
        embedding: Uint8List.fromList([1, 2, 3, 4]),
        embeddedHash: 'h-$key',
        embedModel: tag,
      );
    }

    /// How many `sync_mail` rows name the clustering one-shot at all — the
    /// twin of [reportedRefolds], and the honest question here because a sync
    /// that queued nothing is quiet enough to write no row of its own.
    Future<int> reportedReembeds() async {
      final rows = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
            "AND detail_json LIKE '%requeued_clustering_reembeds%'",
          )
          .getSingle();
      return (rows.data['n'] as num).toInt();
    }

    /// Every thread with a pending `storyline` row, in no particular order.
    Future<Set<String>> queuedStorylineKeys() async {
      final rows = await db
          .customSelect(
            "SELECT source, entity_id FROM work_items WHERE task_kind = 'storyline' "
            "AND status = 'pending'",
          )
          .get();
      return {
        for (final row in rows)
          '${row.data['source']}/${row.data['entity_id']}',
      };
    }

    test('the old clustering vectors are queued for a re-embed, once',
        () async {
      // The model moved and the tag moved with it, so a vector under the
      // retired tag sits in a space — and at a width — this build cannot
      // read. The assign pass is the vehicle: it re-embeds before it judges
      // anything.
      await seedVector('email', 'stale-1', EmbeddingsClient.retiredModelTag);
      await seedVector('email', 'stale-2', EmbeddingsClient.retiredModelTag);
      await seedVector('teams', 'stale-3', EmbeddingsClient.retiredModelTag);
      await seedVector('email', 'current', EmbeddingsClient.modelTag);
      // A thread the gates emptied. It keeps its old-tag row and is not in the
      // slice: the assign pass would return `gated` before re-embedding it, so
      // counting it would hold the one-shot open on work that can never close.
      await seedVector('email', 'all-gated', EmbeddingsClient.retiredModelTag,
          kept: false);

      await syncReaching(14).syncNow();

      expect(await queuedStorylineKeys(),
          {'email/stale-1', 'email/stale-2', 'teams/stale-3'});
      // Three is short of the cap, so the pass closed the one-shot. The v1
      // one-shot closed on the same sync without costing a slice: this store
      // has nothing under the tag before last, so the walk carried straight
      // on to the one that did.
      expect(await store.getPref('clustering_card_v3'), '1');
      expect(await store.getPref('clustering_card_v2'), '1');
      expect((await syncMailDetail())['requeued_clustering_reembeds'], 3);

      graph.requests.clear();
      await store.writeWork('storyline', 'email', 'stale-1', status: 'done');
      await syncReaching(14).syncNow();

      // Nothing queued it again. Named on exactly one row, ever: a later pass
      // omits the key rather than reporting a zero, which would read as a
      // re-embed that ran and found nothing.
      expect(await queuedStorylineKeys(),
          {'email/stale-2', 'teams/stale-3'});
      expect(await reportedReembeds(), 1);
    });

    test('a full slice leaves the one-shot owed and the next sync walks on',
        () async {
      // The cap is a pace: a mailbox with more old vectors than one slice
      // holds is re-embedded over several syncs, and only the pass that comes
      // back short closes the pref.
      for (var i = 0; i < clusteringCardReembedCap; i++) {
        await seedVector('email', 'old-$i', EmbeddingsClient.retiredModelTag);
      }

      await syncReaching(14).syncNow();

      expect(await queuedStorylineKeys(), hasLength(clusteringCardReembedCap));
      expect(await store.getPref('clustering_card_v3'), isNull);
      expect((await syncMailDetail())['requeued_clustering_reembeds'],
          clusteringCardReembedCap);

      // The assign pass writes the new tag as it goes. All but five are done
      // by the time the next sync runs.
      for (var i = 0; i < clusteringCardReembedCap - 5; i++) {
        await store.upsertConversationAi(
          'email',
          'old-$i',
          embedModel: EmbeddingsClient.modelTag,
        );
      }
      graph.requests.clear();
      await syncReaching(14).syncNow();

      expect((await syncMailDetail())['requeued_clustering_reembeds'], 5);
      expect(await store.getPref('clustering_card_v3'), '1');
    });

    test('an install carrying both old tags drains the older one first',
        () async {
      // Two model swaps in two days, and an install that was closed across
      // both holds rows under each. The walk is oldest first and one SLICE a
      // sync, so the pace stays at the cap however many tags have been
      // retired — the whole reason `clusteringCardReembedCap` exists.
      await seedVector('email', 'v1-a', EmbeddingsClient.retiredModelTagV1);
      await seedVector('email', 'v1-b', EmbeddingsClient.retiredModelTagV1);
      await seedVector('email', 'v2-a', EmbeddingsClient.retiredModelTag);
      await seedVector('teams', 'v2-b', EmbeddingsClient.retiredModelTag);

      await syncReaching(14).syncNow();

      // The v1 rows alone, and the newer one-shot untouched: it has not run,
      // so its pref is still owed.
      expect(await queuedStorylineKeys(), {'email/v1-a', 'email/v1-b'});
      expect(await store.getPref('clustering_card_v2'), '1');
      expect(await store.getPref('clustering_card_v3'), isNull);
      expect((await syncMailDetail())['requeued_clustering_reembeds'], 2);

      graph.requests.clear();
      await syncReaching(14).syncNow();

      // The next sync skips the closed one-shot and files the v2 slice.
      expect(await queuedStorylineKeys(),
          {'email/v1-a', 'email/v1-b', 'email/v2-a', 'teams/v2-b'});
      expect(await store.getPref('clustering_card_v3'), '1');
      expect((await syncMailDetail())['requeued_clustering_reembeds'], 2);
    });
  });

  /// The install-time re-decide: once per decision model, keyed on the
  /// question-set hash, and never holding the sync that started it.
  group('the re-decide one-shot', () {
    test('runs once for this build\'s hash and records it', () async {
      var calls = 0;
      Future<({int redecided, bool complete})> redecide() async {
        calls++;
        return (redecided: 4, complete: true);
      }

      final first = syncReaching(14, redecide: redecide);
      await first.syncNow();
      await first.redecideInFlight;

      expect(calls, 1);
      // The value IS the hash it ran for, so a new model runs it again.
      expect(await store.getPref(redecideQhashKey), decisionQhash);

      final second = syncReaching(14, redecide: redecide);
      await second.syncNow();
      await second.redecideInFlight;
      expect(calls, 1, reason: 'the same hash never runs it twice');
    });

    test('a pref from another model\'s hash runs it again', () async {
      await store.setPref(redecideQhashKey, 'an-older-qhash');
      var calls = 0;
      final sync = syncReaching(14, redecide: () async {
        calls++;
        return (redecided: 0, complete: true);
      });

      await sync.syncNow();
      await sync.redecideInFlight;

      expect(calls, 1);
      expect(await store.getPref(redecideQhashKey), decisionQhash);
    });

    test('a parked or failed run leaves it owed, and the sync is fine',
        () async {
      var calls = 0;
      Future<({int redecided, bool complete})> redecide() async {
        calls++;
        if (calls == 1) return (redecided: 2, complete: false);
        if (calls == 2) throw StateError('the decision server went away');
        return (redecided: 1, complete: true);
      }

      for (var pass = 0; pass < 2; pass++) {
        final sync = syncReaching(14, redecide: redecide);
        await sync.syncNow();
        await sync.redecideInFlight;
        expect(await store.getPref(redecideQhashKey), isNull,
            reason: 'pass $pass');
      }

      final sync = syncReaching(14, redecide: redecide);
      await sync.syncNow();
      await sync.redecideInFlight;
      expect(calls, 3);
      expect(await store.getPref(redecideQhashKey), decisionQhash);
    });

    test('is not a derived one-shot: Clear AI results re-decides everything',
        () {
      expect(MessageStore.derivedOneShotPrefs, isNot(contains(redecideQhashKey)));
    });
  });

}
