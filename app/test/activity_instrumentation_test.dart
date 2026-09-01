import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// What the pipeline actually writes to `activity_events`.
///
/// The unit tests next door prove the recorder works; these prove each seam
/// calls it with the right thing at the right moment — which is where the
/// instrumentation can be wrong without any other test noticing, because none
/// of the pipeline's own behaviour changes when a row goes missing.
///
/// The fakes are deliberately local rather than shared with the queues' own
/// test files, following what those files already do to each other: neither
/// can break the other by editing its stub.

/// A [MailBackend] that hands back one page and then stops.
class FakeMail implements MailBackend {
  final List<Map<String, dynamic>> messages;

  /// Thrown from every call instead of answering — a Graph round trip that
  /// failed.
  final Object? error;

  int pages = 0;

  FakeMail({this.messages = const [], this.error});

  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async {
    pages++;
    final failure = error;
    if (failure != null) throw failure;
    return DeltaPage(
      // Only the inbox carries mail here: the second drain would otherwise
      // re-ingest the same ids as outbound and count nothing twice.
      messages: folder == 'inbox' ? messages : const [],
      deltaLink: 'delta-$folder',
    );
  }

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async => {};

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async => {};

  @override
  Future<void> updateDraftBody(String draftId, String text) async {}

  @override
  Future<void> sendDraft(String draftId) async {}
}

/// A [TeamsBackend] that answers from a fixed chat list and counts what it was
/// asked for. Nothing in the no-scope test may reach it at all.
class FakeTeams implements TeamsBackend {
  final List<Map<String, dynamic>> chats;

  /// Chat id → the messages that chat hands back.
  final Map<String, List<Map<String, dynamic>>> messages;

  int calls = 0;

  FakeTeams({this.chats = const [], this.messages = const {}});

  @override
  Future<String> myUserId() async {
    calls++;
    return 'me-1';
  }

  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async {
    calls++;
    return chats;
  }

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async {
    calls++;
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async {
    calls++;
    return messages[chatId] ?? const [];
  }
}

Map<String, dynamic> chatMessage(String id) => {
      'id': id,
      'messageType': 'message',
      'from': {
        'user': {'id': 'u1', 'displayName': 'Sarah Whitfield'}
      },
      'body': {'contentType': 'text', 'content': 'Can you send the CD?'},
      'createdDateTime':
          DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
    };

/// An [LlmClient] that answers from a script and never opens a socket, telling
/// its observer what each call cost exactly as the real client does.
class FakeLlm extends LlmClient {
  /// Answers in order. A `Map` is returned, an `Exception` is thrown. The last
  /// entry repeats once the script runs out.
  final List<Object> script;

  final LlmCallObserver? observer;

  FakeLlm(this.script, {this.observer})
      : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) {
      observer?.call(LlmCallRecord(
        label: schemaName,
        durationMs: 5,
        outcome: 'unavailable',
        error: '$step',
      ));
      throw step;
    }
    observer?.call(LlmCallRecord(
      label: schemaName,
      durationMs: 5,
      outcome: 'ok',
      promptTokens: 700,
      completionTokens: 40,
    ));
    return Map<String, dynamic>.from(step as Map);
  }
}

/// A [WorkHandler] that does whatever the test hands it and nothing else.
class ScriptedHandler implements WorkHandler {
  @override
  final String kind;

  final Future<void> Function(Map<String, Object?> item) body;

  ScriptedHandler(this.kind, this.body);

  @override
  Future<void> run(Map<String, Object?> item) async {
    // A real handler suspends before it finishes.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await body(item);
  }
}

Map<String, dynamic> graphMessage(String id) => {
      'id': id,
      'conversationId': 'conv-$id',
      'subject': 'Rate lock',
      'from': {
        'emailAddress': {'name': 'Sarah', 'address': 'sarah@example.com'}
      },
      'toRecipients': const [],
      'receivedDateTime':
          DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
      'isRead': false,
      'isDraft': false,
      'bodyPreview': 'Preview of $id',
    };

Map<String, dynamic> triageAnswer({
  String urgency = 'high',
  String category = 'borrower',
}) =>
    {
      'urgency': urgency,
      'category': category,
      'summary': 'Sarah asks about the rate lock.',
      'needs_action': true,
      'action_items': const ['Call Sarah about the lock'],
    };

void main() {
  late Database db;
  late MessageStore store;
  late ActivityLog log;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
    log = ActivityLog(store);
  });

  tearDown(() {
    log.dispose();
    db.close();
  });

  List<ActivityEvent> rows([String? kind]) => [
        for (final row in store.recentActivity())
          if (kind == null || row['kind'] == kind) ActivityEvent.fromRow(row),
      ];

  void seedMessage(String id) {
    store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Rate lock',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Body of $id',
      'triage_status': 'pending',
    });
  }

  group('SyncService', () {
    test('one row per sync, counting the messages that were new', () async {
      final mail = FakeMail(
        messages: [graphMessage('m1'), graphMessage('m2'), graphMessage('m3')],
      );

      await SyncService(mail, store, activityLog: log).syncNow();

      final row = rows('sync_mail').single;
      expect(row.status, 'ok');
      expect(row.source, 'email');
      expect(row.count, 3);
      expect(row.durationMs, isNotNull);
      expect(row.detail['inbox'], 3);
      expect(row.detail['sent'], 0);
      expect(row.detail['queued_extract'], isA<int>());
    });

    test('a replayed message is not counted twice, and writes no row at all',
        () async {
      final mail = FakeMail(messages: [graphMessage('m1'), graphMessage('m2')]);
      final sync = SyncService(mail, store, activityLog: log);

      await sync.syncNow();
      await sync.syncNow();

      // The replay ingested nothing, so it is suppressed rather than logged as
      // a second row — a poll that runs on a timer would otherwise fill the
      // panel with its own heartbeat.
      expect([for (final row in rows('sync_mail')) row.count], [2]);
      // It still happened, and the pref is where that is recorded.
      expect(store.getPref(activityLastSyncMailKey), isNotNull);
    });

    test('a failing backend writes an error row AND still throws', () async {
      final mail = FakeMail(error: Exception('Graph is down'));

      await expectLater(
        SyncService(mail, store, activityLog: log).syncNow(),
        throwsA(isA<Exception>()),
      );

      final row = rows('sync_mail').single;
      expect(row.status, 'error');
      expect(row.detail['error'], contains('Graph is down'));
      // The banner the caller shows is built from the rethrow; the row exists
      // so the panel can say what the banner said after it is gone.
      expect(row.durationMs, isNotNull);
    });
  });

  group('TeamsSync', () {
    test('a tenant without Chat.Read costs one skipped row and no calls',
        () async {
      final teams = FakeTeams();

      await TeamsSync(
        teams,
        store,
        canSync: () async => false,
        activityLog: log,
      ).syncNow();

      final row = rows('sync_teams').single;
      expect(row.status, 'skipped');
      expect(row.source, 'teams');
      expect(row.detail['reason'], 'no_scope');
      expect(teams.calls, 0);
    });

    test('an empty chat list is recorded as freshness, not as a row', () async {
      final teams = FakeTeams();

      await TeamsSync(teams, store, activityLog: log).syncNow();

      // No chats, no messages, nothing queued: there is nothing here a reader
      // would learn from, and the walk is reported by the timestamp instead.
      expect(rows('sync_teams'), isEmpty);
      expect(store.getPref(activityLastSyncTeamsKey), isNotNull);
    });

    test('the count is messages seen for the first time, not messages read',
        () async {
      final teams = FakeTeams(
        chats: [
          {'id': 'chat-1', 'chatType': 'oneOnOne'},
        ],
        messages: {
          'chat-1': [chatMessage('a'), chatMessage('b')],
        },
      );
      final sync = TeamsSync(teams, store, activityLog: log);

      await sync.syncNow();
      // The same two messages again: Graph replays, and a replay ingested
      // nothing.
      await sync.syncNow();

      final walks = rows('sync_teams');
      expect([for (final row in walks) row.count], [0, 2]);
      expect(walks.last.detail['chats_seen'], 1);
      expect(walks.last.detail['chats_fetched'], 1);
      expect(walks.last.detail['queued_extract'], 2);
    });
  });

  group('TriageQueue', () {
    test('a triaged message carries the verdict and the model call', () async {
      seedMessage('m1');
      final llm = FakeLlm([triageAnswer()], observer: log.noteLlmCall);

      await TriageQueue(store, llm, activityLog: log).pump();

      final row = rows('triage').single;
      expect(row.status, 'ok');
      expect(row.source, 'email');
      expect(row.entityId, 'm1');
      expect(row.durationMs, isNotNull);
      expect(row.detail['urgency'], 'high');
      expect(row.detail['category'], 'borrower');
      expect(row.detail['needs_action'], isTrue);
      expect(row.detail['action_items'], 1);
      // The tally the client reported, folded onto the item's own row.
      expect(row.detail['llm_calls'], 1);
      expect(row.detail['llm_label'], 'triage');
    });

    test('a gated message writes no row at all', () async {
      store.upsertMessage({
        'source': 'email',
        'source_message_id': 'bulk',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'This week at Harborline',
        'from_name': 'Harborline',
        'from_address': 'no-reply@harborline.com',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Newsletter',
        'triage_status': 'pending',
      });
      final llm = FakeLlm([triageAnswer()], observer: log.noteLlmCall);

      await TriageQueue(store, llm, activityLog: log).pump();

      // A gate is what keeps the model from being consulted, so there is
      // nothing to report — and a row per newsletter would bury the work the
      // panel exists to show.
      expect(store.recentActivity(), isEmpty);
      expect(store.getMessageRow('email', 'bulk')!['triage_status'], 'skipped');
    });

    test('a model server that is down parks rather than errors', () async {
      seedMessage('m1');
      final llm = FakeLlm(
        [const LlmUnavailableException('not reachable')],
        observer: log.noteLlmCall,
      );

      await TriageQueue(store, llm, activityLog: log).pump();

      final row = rows('triage').single;
      expect(row.status, 'parked');
      expect(row.entityId, 'm1');
      expect(row.detail['reason'], 'model_unavailable');
      // Nothing about the message failed, so its row stays pending.
      expect(store.getMessageRow('email', 'm1')!['triage_status'], 'pending');
    });

    test('a retry and the error it becomes are two distinct rows', () async {
      seedMessage('m1');
      final llm = FakeLlm([const LlmFormatException('not JSON')]);

      await TriageQueue(store, llm, activityLog: log).pump();

      // The message row cannot tell these apart after the fact — it goes back
      // to `pending` and then to `error` — so the distinction lives here.
      final triage = rows('triage');
      expect([for (final row in triage) row.status], ['error', 'retry']);
      expect(triage.last.detail['attempts'], 1);
      expect(triage.last.detail['error'], contains('not JSON'));
      expect(triage.first.detail['attempts'], 2);
    });
  });

  group('AiWorker', () {
    test("a handler's facts and status land on the item's row", () async {
      store.enqueueWork('extract', 'email', 'm1');
      final handler = ScriptedHandler('extract', (_) async {
        log
          ..noteStatus('skipped')
          ..note({'reason': 'gated'});
      });

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      final row = rows('extract').single;
      expect(row.status, 'skipped');
      expect(row.source, 'email');
      expect(row.entityId, 'm1');
      expect(row.detail['reason'], 'gated');
      expect(row.durationMs, isNotNull);
      // The work row is done either way — `skipped` is about what the handler
      // did, not about whether the item still needs doing.
      expect(store.workCounts('extract'), {'done': 1});
    });

    test('a handler that says nothing gets a plain ok row', () async {
      store.enqueueWork('draft', 'email', 'conv-1');
      final handler = ScriptedHandler('draft', (_) async {});

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      final row = rows('draft').single;
      expect(row.status, 'ok');
      expect(row.detail, isEmpty);
    });

    test('a park is a park, not an error', () async {
      store.enqueueWork('extract', 'email', 'm1');
      final handler = ScriptedHandler(
        'extract',
        (_) async => throw const LlmUnavailableException('not reachable'),
      );

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      final row = rows('extract').single;
      expect(row.status, 'parked');
      expect(row.detail['reason'], 'model_unavailable');
      expect(store.workCounts('extract'), {'pending': 1});
    });

    test('the session ending parks with its own reason', () async {
      store.enqueueWork('extract', 'email', 'm1');
      final handler = ScriptedHandler(
        'extract',
        (_) async => throw const NotSignedIn(),
      );

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      expect(rows('extract').single.detail['reason'], 'session');
    });

    test('a second failure is an error, and says how many attempts it took',
        () async {
      store.enqueueWork('extract', 'email', 'm1');
      final handler = ScriptedHandler(
        'extract',
        (_) async => throw const LlmException('rejected', 400),
      );

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      // A 400 is this app's schema being wrong: fatal on the first attempt.
      final row = rows('extract').single;
      expect(row.status, 'error');
      expect(row.detail['attempts'], 1);
      expect(row.detail['status_code'], 400);
    });

    test('one row per item, not one per handler pass', () async {
      for (final id in ['m1', 'm2', 'm3']) {
        store.enqueueWork('extract', 'email', id);
      }
      final handler = ScriptedHandler('extract', (_) async {});

      await AiWorker(store, handlers: [handler], activityLog: log).pump();

      expect(rows('extract'), hasLength(3));
      expect(
        [for (final row in rows('extract')) row.entityId],
        unorderedEquals(['m1', 'm2', 'm3']),
      );
    });
  });
}
