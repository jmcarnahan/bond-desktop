import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two repairs behind the mail bodies an older converter wrote.
///
/// The detail fetch asks Graph for HTML now and this app converts it, so every
/// body stored before that switch carries what Graph's own conversion wrote:
/// `label <href>` for every anchor, `[alt]` for every image. The branch's
/// first converter left its own marks, a blank line and literal entities.
/// [MessageStore.markStaleMailBodies] MARKS those bodies stale and keeps their
/// text, so the lazy fetch brings them back and a message whose id no longer
/// answers keeps what it had. There is no HTML part behind a PREVIEW at all,
/// so [MessageStore.tidyMailPreviews] rewrites those in place instead.
///
/// The load-bearing claim is the one nothing about the text shows: a message
/// row's `updated_at` must not move, in EITHER repair. It is the keyword
/// index's watermark. The conversation row is the exception and keeps its
/// stamp.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// Hours rather than days, and off the clock rather than written out: the
  /// lookback floor these methods take is a short window, and a literal date
  /// walks out of it at midnight.
  String ago(Duration d) =>
      DateTime.now().toUtc().subtract(d).toIso8601String();

  Future<void> mail({
    required String id,
    String? bodyText,
    String? bodyPreview,
    required String receivedAt,
    String conversationKey = 'conv-1',
    String triageStatus = 'done',
  }) =>
      store.upsertMessage(SyncService.mailRow(
        id: id,
        conversationKey: conversationKey,
        direction: 'inbound',
        fromName: 'Dana Whitlock',
        fromAddress: 'dana@notify.example.com',
        to: const ['owner@example.com'],
        receivedAt: receivedAt,
        isRead: true,
        bodyText: bodyText,
        bodyPreview: bodyPreview,
        triageStatus: triageStatus,
      ));

  Future<void> chat({
    required String id,
    String? bodyText,
    String? bodyPreview,
    required String receivedAt,
  }) =>
      store.upsertMessage({
        'source': 'teams',
        'source_message_id': id,
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Ravi Patel',
        'from_address': 'teams:u-ravi',
        'received_at': receivedAt,
        'is_read': 1,
        'body_text': bodyText,
        'body_preview': bodyPreview,
        'triage_status': 'done',
      });

  Future<Map<String, Object?>> row(String source, String id) async =>
      (await store.getMessageRow(source, id))!;

  Future<Map<String, Object?>> conversationRow(String source, String key) async =>
      (await store.getConversationRow(source, key))!;

  // The three shapes a server's own conversion leaves behind, and the fourth
  // that a person wrote.
  const anchorTail = 'View comment '
      '<https://requests.example.com/r/42#c7>\n\nWhy am I receiving this?';
  const mailtoTail = 'Write to the team <mailto:renewals@example.com>';
  const inlineImage = 'Signed and scanned.\n[cid:image001@example]';
  const clean = 'Could you look at the renewal before Thursday?';

  /// Whether the row carries the stale-body mark, as the model reads it.
  Future<bool> stale(String source, String id) async =>
      Message.fromRow(await row(source, id)).bodyStale;

  // What the branch's first converter wrote for Exchange plain-text mail:
  // the `<br>` newline and the source's own CR/LF, one blank line per line.
  const doubled = 'Hi Dana,\n\nThe renewal is attached.\n\nThanks';
  const single = 'Hi Dana,\nThe renewal is attached.\nThanks';
  // And the entities it did not decode.
  const entity = 'We&rsquo;re glad &mdash; see you Thursday.';

  group('markStaleMailBodies', () {
    test('marks every old shape in window, keeps the text, and nothing else',
        () async {
      await mail(id: 'm-anchor', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm-mailto', bodyText: mailtoTail, receivedAt: ago(const Duration(hours: 3)));
      await mail(id: 'm-cid', bodyText: inlineImage, receivedAt: ago(const Duration(hours: 4)));
      await mail(id: 'm-doubled', bodyText: doubled, receivedAt: ago(const Duration(hours: 4)));
      await mail(id: 'm-entity', bodyText: entity, receivedAt: ago(const Duration(hours: 4)));
      await mail(id: 'm-clean', bodyText: clean, receivedAt: ago(const Duration(hours: 5)));
      await mail(id: 'm-single', bodyText: single, receivedAt: ago(const Duration(hours: 5)));
      // A bare ampersand is a person's own punctuation, not an entity.
      await mail(
        id: 'm-amp',
        bodyText: 'Tom & Jerry are in.',
        receivedAt: ago(const Duration(hours: 5)),
      );
      // Behind the floor: outside the window this pass ran with.
      await mail(
        id: 'm-old',
        bodyText: anchorTail,
        receivedAt: ago(const Duration(days: 30)),
      );
      // A chat body was never converted by anybody — Teams hands over the
      // message whole — so the source is part of the match.
      await chat(id: 'c1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      final marked = await store.markStaleMailBodies(
        sinceIso: ago(const Duration(days: 1)),
      );

      expect(marked, 5);
      for (final id in ['m-anchor', 'm-mailto', 'm-cid', 'm-doubled', 'm-entity']) {
        expect(await stale('email', id), isTrue, reason: id);
      }
      for (final id in ['m-clean', 'm-single', 'm-amp', 'm-old']) {
        expect(await stale('email', id), isFalse, reason: id);
      }
      expect(await stale('teams', 'c1'), isFalse);
      // Nothing loses its text.
      expect((await row('email', 'm-anchor'))['body_text'], anchorTail);
      expect((await row('email', 'm-doubled'))['body_text'], doubled);
      expect((await row('email', 'm-entity'))['body_text'], entity);
    });

    test('keeps the blob a detail fetch wrote beside the mark', () async {
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await store.updateMessageDetail('email', 'm1',
          sourceMetaJson: '{"headers":{"list-id":"team.example.com"}}');
      // An invalid blob is replaced by one holding the mark alone.
      await mail(id: 'm2', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await db.customUpdate(
        "UPDATE messages SET source_meta_json = 'not json' "
        "WHERE source_message_id = 'm2'",
      );

      await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1)));

      final m1 = Message.fromRow(await row('email', 'm1'));
      expect(m1.bodyStale, isTrue);
      expect(m1.headers['list-id'], 'team.example.com');
      expect(await stale('email', 'm2'), isTrue);
    });

    test('leaves every updated_at byte-identical', () async {
      // The keyword index resyncs from `MAX(indexed_updated_at)` against this
      // column, and the mark changes no text it files. The refill's own stamp
      // hands over the converted body once.
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm2', bodyText: doubled, receivedAt: ago(const Duration(hours: 3)));
      await mail(id: 'm3', bodyText: clean, receivedAt: ago(const Duration(hours: 3)));

      final before = {
        for (final id in ['m1', 'm2', 'm3'])
          id: (await row('email', id))['updated_at'],
      };
      expect(before.values, everyElement(isNotNull));

      await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1)));

      expect(await stale('email', 'm1'), isTrue);
      for (final id in before.keys) {
        expect((await row('email', id))['updated_at'], before[id], reason: id);
      }
    });

    test('a second pass finds nothing left to mark', () async {
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      final since = ago(const Duration(days: 1));
      expect(await store.markStaleMailBodies(sinceIso: since), 1);
      expect(await store.markStaleMailBodies(sinceIso: since), 0);
    });

    test('a row the pipeline still owes work on is marked too', () async {
      // Nothing loses text now, so there is nothing to protect a stage from:
      // needs-you, extraction and the embedding read the old body, never the
      // preview, including on a row whose work the paced backlog has not
      // queued yet.
      await mail(id: 'm-queued', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await store.enqueueWork('needs_you', 'email', 'm-queued');
      await mail(
        id: 'm-pending',
        bodyText: anchorTail,
        receivedAt: ago(const Duration(hours: 2)),
        triageStatus: 'pending',
      );
      // Triaged, with its extract owed on the progress row and no work item.
      await mail(id: 'm-owed', bodyText: entity, receivedAt: ago(const Duration(hours: 2)));

      expect(
        await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1))),
        3,
      );
      expect((await row('email', 'm-queued'))['body_text'], doubled);
      expect((await row('email', 'm-pending'))['body_text'], anchorTail);
      expect((await row('email', 'm-owed'))['body_text'], entity);
    });

    test('a local echo is never marked', () async {
      // The detail fetch refuses a `local:` id, so its mark could never clear.
      await mail(id: 'local:d1', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'local:d2', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      expect(
        await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1))),
        0,
      );
      expect(await stale('email', 'local:d1'), isFalse);
      expect(await stale('email', 'local:d2'), isFalse);
    });
  });

  group('clearing the mark', () {
    setUp(() async {
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await store.updateMessageDetail('email', 'm1',
          sourceMetaJson: '{"meeting":"meetingAccepted"}');
      await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1)));
      expect(await stale('email', 'm1'), isTrue);
    });

    test('clearBodyStale keeps the text, the blob and the stamp', () async {
      final before = await row('email', 'm1');

      await store.clearBodyStale('email', 'm1');

      final after = Message.fromRow(await row('email', 'm1'));
      expect(after.bodyStale, isFalse);
      expect(after.bodyText, anchorTail);
      expect(after.meetingMessageType, 'meetingAccepted');
      expect((await row('email', 'm1'))['updated_at'], before['updated_at']);
    });

    test('a detail write with no blob keeps the old one, minus the mark',
        () async {
      await store.updateMessageDetail('email', 'm1', bodyText: 'New text.');

      final after = Message.fromRow(await row('email', 'm1'));
      expect(after.bodyStale, isFalse);
      expect(after.bodyText, 'New text.');
      expect(after.meetingMessageType, 'meetingAccepted');
    });

    test('a detail write with no body keeps the text and drops the mark',
        () async {
      await store.updateMessageDetail('email', 'm1');

      final after = Message.fromRow(await row('email', 'm1'));
      expect(after.bodyStale, isFalse);
      expect(after.bodyText, anchorTail);
    });
  });

  group('tidyMailPreviews', () {
    test('rewrites the preview on the message and on its thread', () async {
      await mail(
        id: 'm1',
        bodyPreview: 'View comment <https://requests.example.com/r/42#c7>',
        receivedAt: ago(const Duration(hours: 2)),
      );
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-1',
        'subject': 'Renewal approval',
        'state': 'needs_reply',
        'last_message_at': ago(const Duration(hours: 2)),
        'last_message_preview':
            'View comment <https://requests.example.com/r/42#c7>',
      });
      // Nobody converted a chat preview either.
      await chat(
        id: 'c1',
        bodyPreview: 'Ping me <https://chat.example.com/t/9>',
        receivedAt: ago(const Duration(hours: 2)),
      );

      final tidied = await store.tidyMailPreviews();

      expect(tidied, 2, reason: 'the message row and the conversation row');
      expect((await row('email', 'm1'))['body_preview'], 'View comment');
      expect(
        (await conversationRow('email', 'conv-1'))['last_message_preview'],
        'View comment',
      );
      expect((await row('teams', 'c1'))['body_preview'],
          'Ping me <https://chat.example.com/t/9>');
    });

    test("leaves the message row's watermark alone, and moves the thread's",
        () async {
      // A preview rewrite changes nothing the keyword index would file. The
      // index takes `COALESCE(NULLIF(body_text, ''), body_preview, '')`, so it
      // reaches for a preview only on a row with no body — and those are the
      // rows the clear above just emptied, whose index entry still holds the
      // whole body's words. Restamping either kind is wrong for its own
      // reason, so this is the one writer of a message text column in the
      // store that leaves the stamp where it found it.
      await mail(
        id: 'm-body',
        bodyText: clean,
        bodyPreview: 'View comment <https://requests.example.com/r/42#c7>',
        receivedAt: ago(const Duration(hours: 2)),
      );
      await mail(
        id: 'm-nobody',
        bodyPreview: mailtoTail,
        receivedAt: ago(const Duration(hours: 3)),
      );
      // Written back in time so that "this moved" is a fact about the write
      // and not about how fine the clock is between two round trips. The
      // message rows take the store's own stamp, which its doc forbids
      // backdating.
      final threadStamp = ago(const Duration(hours: 2));
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-1',
        'subject': 'Renewal approval',
        'state': 'needs_reply',
        'last_message_at': ago(const Duration(hours: 2)),
        'last_message_preview':
            'View comment <https://requests.example.com/r/42#c7>',
        'updated_at': threadStamp,
      });

      final before = {
        for (final id in ['m-body', 'm-nobody'])
          id: (await row('email', id))['updated_at'],
      };
      expect(before.values, everyElement(isNotNull));

      await store.tidyMailPreviews();

      // Both of them: the row that has a body to index and the row that has
      // none.
      for (final id in before.keys) {
        expect((await row('email', id))['updated_at'], before[id], reason: id);
      }
      expect((await row('email', 'm-body'))['body_preview'], 'View comment');
      expect(
        (await row('email', 'm-nobody'))['body_preview'],
        'Write to the team',
      );
      // The thread row does move. No index files its preview, and a card whose
      // snippet changed is a row that changed.
      expect(
        (await conversationRow('email', 'conv-1'))['updated_at'],
        isNot(threadStamp),
      );
    });

    test('a preview with nothing to strip is left where it is', () async {
      await mail(
        id: 'm1',
        bodyPreview: 'Could you look at the renewal <before Thursday>?',
        receivedAt: ago(const Duration(hours: 2)),
      );

      // A bracket that is not a link target is a person's own punctuation, and
      // the candidate LIKE finding the row is not permission to rewrite it.
      expect(await store.tidyMailPreviews(), 0);
      expect((await row('email', 'm1'))['body_preview'],
          'Could you look at the renewal <before Thursday>?');
    });

    test('a second pass rewrites nothing', () async {
      await mail(
        id: 'm1',
        bodyPreview: 'View comment <https://requests.example.com/r/42#c7>',
        receivedAt: ago(const Duration(hours: 2)),
      );

      expect(await store.tidyMailPreviews(), 1);
      expect(await store.tidyMailPreviews(), 0);
    });
  });

  group('both repairs over one row', () {
    test('a marked body and a tidied preview move no watermark at all',
        () async {
      // The order the sync runs them in, over the row they both match — which
      // is most of them, because a message whose body carries a converted link
      // run usually carries one in its snippet too.
      await mail(
        id: 'm1',
        bodyText: anchorTail,
        bodyPreview: 'View comment <https://requests.example.com/r/42#c7>',
        receivedAt: ago(const Duration(hours: 2)),
      );
      final before = (await row('email', 'm1'))['updated_at'];
      expect(before, isNotNull);

      await store.markStaleMailBodies(sinceIso: ago(const Duration(days: 1)));
      await store.tidyMailPreviews();

      final after = await row('email', 'm1');
      expect(after['body_text'], anchorTail);
      expect(Message.fromRow(after).bodyStale, isTrue);
      expect(after['body_preview'], 'View comment');
      expect(after['updated_at'], before);
    });
  });
}
