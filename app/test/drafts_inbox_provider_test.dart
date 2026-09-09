// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/drafts_models.dart';
import 'package:bond_inbox/providers/drafts_inbox_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A store whose draft reads the test completes by hand, so two reads can be
/// made to land in the wrong order.
class _SlowStore extends MessageStore {
  final List<Completer<List<PendingDraft>>> pending = [];

  _SlowStore(super.db);

  @override
  Future<List<PendingDraft>> pendingDrafts({
    List<String> sources = const ['email', 'teams'],
  }) {
    final completer = Completer<List<PendingDraft>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<List<SentRow>> recentOutbound({
    List<String> sources = const ['email', 'teams'],
    int limit = 50,
  }) async =>
      const [];
}

PendingDraft _draft(String body) => PendingDraft(
      source: 'email',
      conversationKey: 'c1',
      replyToMessageId: 'm1',
      body: body,
      status: 'suggested',
      updatedAt: '2026-09-03T10:00:00Z',
      subject: 'Homepage copy',
      who: 'Dana Whitfield',
    );

/// The notifier behind the Drafts & sent pane: what a read puts in the state,
/// what a dismiss writes through, and what a failure does NOT do to the list
/// already on screen.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  // Tolerant: one test closes the database on purpose, to make a read fail.
  tearDown(() async {
    try {
      await db.close();
    } on Object {
      // Already closed.
    }
  });

  Future<void> seedDraft({
    String key = 'c1',
    String messageId = 'm1',
    String body = 'Friday works.',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': messageId,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': '2026-09-03T10:00:00Z',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Homepage copy',
      'state': 'needs_reply',
      'last_message_at': '2026-09-03T10:00:00Z',
    });
    await store.upsertDraft(
      source: 'email',
      conversationKey: key,
      replyToMessageId: messageId,
      body: body,
    );
  }

  Future<void> seedSent({String id = 'o1', String key = 'c1'}) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'outbound',
        'subject': 'Homepage copy',
        'to_json': '["dana@example.com"]',
        'received_at': '2026-09-03T11:00:00Z',
        'body_text': 'On it.',
      });

  DraftsInboxNotifier build() {
    final notifier = DraftsInboxNotifier(
      store,
      sources: const ['email', 'teams'],
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  test('nothing is loaded before the first read', () {
    final notifier = build();

    // The distinction the flag exists for: "nothing has been read yet" and
    // "nothing is waiting" are the same empty list and very different
    // sentences.
    expect(notifier.state.loaded, isFalse);
    expect(notifier.state.drafts, isEmpty);
    expect(notifier.state.sent, isEmpty);
  });

  test('one load fills both lists', () async {
    await seedDraft();
    await seedSent();

    final notifier = build();
    await notifier.load();

    expect(notifier.state.loaded, isTrue);
    expect([for (final d in notifier.state.drafts) d.body], ['Friday works.']);
    expect([for (final s in notifier.state.sent) s.messageId], ['o1']);
    expect(notifier.state.error, isNull);
  });

  test('a dismiss writes through and the row is gone on the reload', () async {
    await seedDraft();
    final notifier = build();
    await notifier.load();
    expect(notifier.state.drafts, hasLength(1));

    await notifier.dismiss('email', 'm1');

    expect(notifier.state.drafts, isEmpty);
    // Written through rather than merely dropped from the list: the row
    // survives as `dismissed` so the next enqueue does not write the identical
    // suggestion straight back.
    expect(await store.pendingDrafts(), isEmpty);
    final row = await store.getDraftForMessage('email', 'm1');
    expect(row!['status'], 'dismissed');
  });

  test('a read that fails becomes a sentence, not a throw', () async {
    await seedDraft();
    final notifier = build();
    await notifier.load();
    expect(notifier.state.drafts, hasLength(1));

    // The database goes out from under it — the closest a unit test gets to
    // the disk failing mid-session.
    await db.close();
    await notifier.load();

    expect(notifier.state.error, isNotNull);
    // And the list already on screen survives: a pane that blanked on a failed
    // re-read would throw away rows that are still perfectly true.
    expect(notifier.state.drafts, hasLength(1));
  });

  test('an empty source set reads nothing rather than everything', () async {
    await seedDraft();
    await seedSent();

    final notifier = DraftsInboxNotifier(store, sources: const []);
    addTearDown(notifier.dispose);
    await notifier.load();

    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.drafts, isEmpty);
    expect(notifier.state.sent, isEmpty);
  });

  test('a slow first read never overwrites a fast second one', () async {
    // Five call sites reload this list — a section change, the tick, the end
    // of a send, both send-epoch listeners — so a read that was already out
    // when a newer one started is the ordinary case, not the odd one.
    final slow = _SlowStore(db);
    final notifier = DraftsInboxNotifier(slow, sources: const ['email']);
    final first = notifier.load();
    final second = notifier.load();

    slow.pending[1].complete([_draft('After the send.')]);
    await second;
    slow.pending[0].complete([_draft('Before the send.')]);
    await first;

    expect(notifier.state.drafts.map((d) => d.body), ['After the send.']);
    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.error, isNull);
  });

}
