import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What the sync tail leaves on the queue for the registered directories.
///
/// The one thing this file exists to pin: **the enqueue is per REGISTERED
/// directory, linked or not, on every sync.** That is what makes a directory
/// a living context rather than a snapshot — the folder keeps changing after
/// it is linked, and the index has to follow it without anyone asking.
/// Linked-only would mean a directory the user links mid-conversation cannot
/// answer for the first minute of it.
///
/// The stub is duplicated from the other sync tests rather than shared, so
/// neither file can break the other by editing it.
class FakeMail implements MailBackend {
  /// Only ever the inbox's, so a second drain does not re-ingest the same
  /// ids as outbound.
  final List<Map<String, dynamic>> messages;

  int pages = 0;

  FakeMail({this.messages = const []});

  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async {
    pages++;
    return DeltaPage(
      messages: folder == 'inbox' ? messages : const [],
      deltaLink: 'delta-$folder',
    );
  }

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async => {};

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async => {};

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) async =>
      {};

  @override
  Future<void> updateDraftBody(String draftId, String text) async {}

  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      SentDraft(draftId: draftId);

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ContextStore context;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    context = ContextStore(db);
  });

  tearDown(() async => db.close());

  Future<List<Map<String, Object?>>> pendingReconciles() async {
    final rows = await db
        .customSelect(
          "SELECT * FROM work_items WHERE task_kind = 'context_reconcile' "
          'ORDER BY entity_id',
        )
        .get();
    return [for (final row in rows) row.data];
  }

  test('every registered directory gets one item under source local',
      () async {
    final atlas =
        await context.registerDirectory(path: '/w/atlas', displayName: 'a');
    final ridge =
        await context.registerDirectory(path: '/w/ridge', displayName: 'r');

    await SyncService(FakeMail(), store, contextStore: context).syncNow();

    final items = await pendingReconciles();
    expect(
      [for (final item in items) item['entity_id']],
      unorderedEquals([atlas, ridge]),
    );
    for (final item in items) {
      // `local` is not a connector, and `AiWorker._sources` has to name it or
      // nothing here ever runs.
      expect(item['source'], 'local');
      expect(item['status'], 'pending');
    }
  });

  test('a directory nobody linked is enqueued all the same', () async {
    await context.registerDirectory(path: '/w/atlas', displayName: 'a');

    await SyncService(FakeMail(), store, contextStore: context).syncNow();

    expect(await pendingReconciles(), hasLength(1));
  });

  test('a second sync leaves one item and not two', () async {
    await context.registerDirectory(path: '/w/atlas', displayName: 'a');

    await SyncService(FakeMail(), store, contextStore: context).syncNow();
    await SyncService(FakeMail(), store, contextStore: context).syncNow();

    // `requeueWork` leaves a PENDING row alone: a row still waiting from the
    // last sync stays one item. The handler's own freshness rung is what
    // stops a hurried minute walking the same folder three times.
    final items = await pendingReconciles();
    expect(items, hasLength(1));
    expect(items.single['status'], 'pending');
  });

  test('a finished directory is queued again by the next sync', () async {
    final atlas =
        await context.registerDirectory(path: '/w/atlas', displayName: 'a');

    await SyncService(FakeMail(), store, contextStore: context).syncNow();
    await store.writeWork(
      'context_reconcile',
      'local',
      atlas,
      status: 'done',
    );

    await SyncService(FakeMail(), store, contextStore: context).syncNow();

    // The whole point of the tail. `OR IGNORE` would see the finished row and
    // do nothing, so the folder would be read once on the first sync of a
    // launch and never again — a snapshot, which is the opposite of what this
    // feature is.
    final items = await pendingReconciles();
    expect(items, hasLength(1));
    expect(items.single['status'], 'pending');
  });

  test('a sync wired without a context store enqueues nothing', () async {
    await context.registerDirectory(path: '/w/atlas', displayName: 'a');

    // Every caller that predates the feature, and every test that does not
    // care, passes nothing — and must not start queueing work.
    await SyncService(FakeMail(), store).syncNow();

    expect(await pendingReconciles(), isEmpty);
  });

  /// A sync that did nothing at all is suppressed by [ActivityLog], so both
  /// halves of the next test hand the drain one message to make the row
  /// exist. What it is asserting is the DETAIL, not the row.
  Map<String, dynamic> oneMessage(String id) => {
        'id': id,
        'conversationId': 'conv-1',
        'subject': 'The renewal',
        'from': {
          'emailAddress': {'name': 'Wren Calloway', 'address': 'wren@example.com'}
        },
        'toRecipients': [
          {
            'emailAddress': {'name': null, 'address': 'me@example.com'}
          }
        ],
        'receivedDateTime': DateTime.now().toUtc().toIso8601String(),
        'isRead': false,
        'isDraft': false,
        'bodyPreview': 'Preview text',
      };

  Future<String?> syncDetail(SyncService sync) async {
    await sync.syncNow();
    final row = await db
        .customSelect("SELECT detail_json FROM activity_events "
            "WHERE kind = 'sync_mail' ORDER BY id DESC LIMIT 1")
        .getSingle();
    return row.data['detail_json'] as String?;
  }

  test('the count rides on the sync row', () async {
    await context.registerDirectory(path: '/w/atlas', displayName: 'a');
    await context.registerDirectory(path: '/w/ridge', displayName: 'r');

    final detail = await syncDetail(SyncService(
      FakeMail(messages: [oneMessage('m-1')]),
      store,
      contextStore: context,
      activityLog: ActivityLog(store),
    ));

    expect(detail, contains('"context_dirs":2'));
  });

  test('a sync with no directories says nothing about them', () async {
    final detail = await syncDetail(SyncService(
      FakeMail(messages: [oneMessage('m-1')]),
      store,
      contextStore: context,
      activityLog: ActivityLog(store),
    ));

    // A zero would read as an event where there was none.
    expect(detail, isNot(contains('context_dirs')));
  });
}
