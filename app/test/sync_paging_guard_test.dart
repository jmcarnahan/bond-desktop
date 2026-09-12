import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Two guards on [SyncService]'s drain that the backend-specific suites cannot
/// see: that the floor is resent on EVERY page (delta_paging_test drives the
/// direct-Graph backend, which ignores the floor on continuations, so it can
/// never observe this), and that a re-entrant [syncNow] is a no-op.
///
/// A recording [MailBackend] with empty message pages keeps the focus on the
/// drain loop's control flow rather than the ingest.

/// UTC midnight [days] back — [SyncService]'s floor shape (mirrored, not
/// imported, since the helper is private).
String _floor(int days) {
  final t = DateTime.now().toUtc().subtract(Duration(days: days));
  return DateTime.utc(t.year, t.month, t.day)
      .toIso8601String()
      .replaceFirst('.000Z', 'Z');
}

class _RecordingMail implements MailBackend {
  final Map<String, List<DeltaPage>> pages;
  final List<({String folder, String? link, String? minReceivedIso})> calls =
      [];

  _RecordingMail(this.pages);

  @override
  Future<DeltaPage> deltaPage(String folder,
      {String? link, String? minReceivedIso}) async {
    calls.add((folder: folder, link: link, minReceivedIso: minReceivedIso));
    final queue = pages[folder];
    if (queue == null || queue.isEmpty) {
      throw StateError('unscripted deltaPage("$folder") — call ${calls.length}');
    }
    return queue.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> updateDraftBody(String draftId, String text) =>
      throw UnimplementedError();
  @override
  Future<SentDraft> sendDraft(String draftId) => throw UnimplementedError();
  @override
  Future<List<String>> markRead(List<String> messageIds,
          {bool isRead = true}) =>
      throw UnimplementedError();
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// Skips the reconcile so a pass's only drains are the two folders — the
  /// reconcile re-enumerates from scratch and would add its own deltaPage calls.
  Future<void> skipReconcile() => store.setPref(
      mailLastReconcileKey, DateTime.now().toUtc().toIso8601String());

  test('a first-run drain resends the floor on every page, not just the first',
      () async {
    // The guarantee the deployed server's per-page hard cap depends on: drop
    // the floor on a continuation and the server walks past the window.
    final backend = _RecordingMail({
      'inbox': [
        const DeltaPage(nextLink: 'in-p2'),
        const DeltaPage(deltaLink: 'in-d'),
      ],
      'sentitems': [const DeltaPage(deltaLink: 'sent-d')],
    });
    final sync = SyncService(backend, store, lookbackDays: () => 7);
    await skipReconcile();

    final before = _floor(7);
    await sync.syncNow();
    final after = _floor(7);
    final floor = anyOf(before, after);

    final inbox = backend.calls.where((c) => c.folder == 'inbox').toList();
    expect(inbox.length, 2, reason: 'page 1 then its continuation');
    expect(inbox[0].link, isNull, reason: 'a first run starts cursorless');
    expect(inbox[0].minReceivedIso, floor);
    expect(inbox[1].link, 'in-p2', reason: 'the continuation follows the cursor');
    expect(inbox[1].minReceivedIso, floor,
        reason: 'the floor rides the continuation too — the server hard-caps '
            'only the pages it is told the floor for');
  });

  test('a re-entrant syncNow joins the pass in flight instead of starting one',
      () async {
    // The inbox polls every 60s; a pass over a deep window can outlast that. A
    // second syncNow firing over the same session is what dropped connections
    // mid-write (`Broken pipe`). Each folder is scripted for exactly ONE drain,
    // so a second concurrent pass would pop an empty queue and throw — which is
    // what the latch prevents.
    final backend = _RecordingMail({
      'inbox': [const DeltaPage(deltaLink: 'in-d')],
      'sentitems': [const DeltaPage(deltaLink: 'sent-d')],
    });
    final sync = SyncService(backend, store, lookbackDays: () => 7);
    await skipReconcile();

    // The latch is set synchronously, before syncNow's first await, so the
    // second call sees it without any pumping.
    final first = sync.syncNow();
    final second = sync.syncNow();

    // JOINED, not turned away: when the second call comes back the pass has
    // actually drained. A no-op return would resolve here before a single
    // page was fetched — and `load` would arm notifications on the strength
    // of a sync that had not happened.
    await second;
    expect(backend.calls.where((c) => c.folder == 'inbox').length, 1,
        reason: 'one drain per folder, and it is finished by the time the '
            'joined caller is released');
    expect(backend.calls.where((c) => c.folder == 'sentitems').length, 1);
    await first;
    expect(backend.calls.length, 2, reason: 'the first call started no second pass');

    // The latch is per-pass, not permanent: a later pass runs normally.
    backend.calls.clear();
    backend.pages['inbox'] = [const DeltaPage(deltaLink: 'in-d2')];
    backend.pages['sentitems'] = [const DeltaPage(deltaLink: 'sent-d2')];
    await sync.syncNow();
    expect(backend.calls, isNotEmpty);
  });

  test('a pass that throws releases the latch and fails its joiner too',
      () async {
    // Nothing scripted for 'inbox', so the first drain throws. The joined
    // caller must see the same failure — it was told the sync it waited on
    // did not happen — and the next call must run a fresh pass rather than
    // find the latch stuck on the dead one.
    final backend = _RecordingMail({});
    final sync = SyncService(backend, store, lookbackDays: () => 7);
    await skipReconcile();

    final first = sync.syncNow();
    final second = sync.syncNow();
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);

    backend.pages['inbox'] = [const DeltaPage(deltaLink: 'in-d')];
    backend.pages['sentitems'] = [const DeltaPage(deltaLink: 'sent-d')];
    await sync.syncNow();
    expect(backend.calls.where((c) => c.folder == 'sentitems').length, 1,
        reason: 'the latch cleared with the failure');
  });
}
