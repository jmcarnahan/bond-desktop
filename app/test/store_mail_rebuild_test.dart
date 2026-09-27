import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two repairs behind the mail bodies a server converted for us.
///
/// The detail fetch asks Graph for HTML now and this app converts it, so every
/// body stored before that switch carries what Graph's own conversion wrote:
/// `label <href>` for every anchor, `[alt]` for every image. There is no way
/// to recover the message from that text, so [MessageStore
/// .clearLegacyMailBodies] forgets those bodies and lets the lazy fetch bring
/// them back — and there is no HTML part behind a PREVIEW at all, so
/// [MessageStore.tidyMailPreviews] rewrites those in place instead.
///
/// The load-bearing claim is the one nothing about the text shows: a message
/// row's `updated_at` must not move, in EITHER repair. It is the keyword
/// index's watermark, and a NULL body offered to the index is a message indexed
/// as having no words. The two run in the same pass over largely the same rows,
/// so a stamp from the preview rewrite would undo the clear's guarantee just as
/// surely as a stamp from the clear itself — which is what the last group is
/// for. The conversation row is the exception and keeps its stamp.

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

  group('clearLegacyMailBodies', () {
    test('forgets the converted bodies and nothing else', () async {
      await mail(id: 'm-anchor', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm-mailto', bodyText: mailtoTail, receivedAt: ago(const Duration(hours: 3)));
      await mail(id: 'm-cid', bodyText: inlineImage, receivedAt: ago(const Duration(hours: 4)));
      await mail(id: 'm-clean', bodyText: clean, receivedAt: ago(const Duration(hours: 5)));
      // Behind the floor: outside the window this pass ran with, so outside
      // what it is allowed to forget.
      await mail(
        id: 'm-old',
        bodyText: anchorTail,
        receivedAt: ago(const Duration(days: 30)),
      );
      // A chat body was never converted by anybody — Teams hands over the
      // message whole — so the source is part of the match.
      await chat(id: 'c1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      final cleared = await store.clearLegacyMailBodies(
        sinceIso: ago(const Duration(days: 1)),
      );

      expect(cleared, 3);
      expect((await row('email', 'm-anchor'))['body_text'], isNull);
      expect((await row('email', 'm-mailto'))['body_text'], isNull);
      expect((await row('email', 'm-cid'))['body_text'], isNull);
      expect((await row('email', 'm-clean'))['body_text'], clean);
      expect((await row('email', 'm-old'))['body_text'], anchorTail);
      expect((await row('teams', 'c1'))['body_text'], anchorTail);
    });

    test('leaves every updated_at byte-identical', () async {
      // The keyword index resyncs from `MAX(indexed_updated_at)` against this
      // column. A row restamped here would be offered to the index with a NULL
      // body and indexed as a message with no words in it, until somebody
      // happened to open its thread; left alone, the row keeps the text it has
      // and the refill's own stamp hands over the converted body once.
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm2', bodyText: clean, receivedAt: ago(const Duration(hours: 3)));

      final before = {
        for (final id in ['m1', 'm2'])
          id: (await row('email', id))['updated_at'],
      };
      expect(before.values, everyElement(isNotNull));

      await store.clearLegacyMailBodies(sinceIso: ago(const Duration(days: 1)));

      for (final id in before.keys) {
        expect((await row('email', id))['updated_at'], before[id], reason: id);
      }
    });

    test('a second pass finds nothing left to forget', () async {
      await mail(id: 'm1', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      final since = ago(const Duration(days: 1));
      expect(await store.clearLegacyMailBodies(sinceIso: since), 1);
      expect(await store.clearLegacyMailBodies(sinceIso: since), 0);
    });
  });

  group('clearDoubleSpacedMailBodies', () {
    // What the branch's first converter wrote for Exchange plain-text mail:
    // the `<br>` newline and the source's own CR/LF, one blank line per line.
    const doubled = 'Hi Dana,\n\nThe renewal is attached.\n\nThanks';
    const single = 'Hi Dana,\nThe renewal is attached.\nThanks';

    test('forgets an in-window email body with a blank line and nothing else',
        () async {
      await mail(id: 'm-doubled', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm-single', bodyText: single, receivedAt: ago(const Duration(hours: 3)));
      // Behind the floor: outside the window this pass ran with.
      await mail(
        id: 'm-old',
        bodyText: doubled,
        receivedAt: ago(const Duration(days: 30)),
      );
      // A chat body never went through the mail converter.
      await chat(id: 'c1', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));

      final cleared = await store.clearDoubleSpacedMailBodies(
        sinceIso: ago(const Duration(days: 1)),
      );

      expect(cleared, 1);
      expect((await row('email', 'm-doubled'))['body_text'], isNull);
      expect((await row('email', 'm-single'))['body_text'], single);
      expect((await row('email', 'm-old'))['body_text'], doubled);
      expect((await row('teams', 'c1'))['body_text'], doubled);
    });

    test('leaves every updated_at byte-identical', () async {
      // The same keyword-index watermark `clearLegacyMailBodies` protects.
      await mail(id: 'm1', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm2', bodyText: single, receivedAt: ago(const Duration(hours: 3)));

      final before = {
        for (final id in ['m1', 'm2'])
          id: (await row('email', id))['updated_at'],
      };
      expect(before.values, everyElement(isNotNull));

      await store.clearDoubleSpacedMailBodies(
        sinceIso: ago(const Duration(days: 1)),
      );

      expect((await row('email', 'm1'))['body_text'], isNull);
      for (final id in before.keys) {
        expect((await row('email', id))['updated_at'], before[id], reason: id);
      }
    });
  });

  group('what neither clear may touch', () {
    const doubled = 'Hi Dana,\n\nThanks for the numbers.';

    test('a local echo keeps the body the owner typed', () async {
      // The detail fetch refuses a `local:` id, so a nulled echo would never
      // be refilled. A typed reply nearly always has a blank line, and one
      // with a link in it matches the legacy patterns as well.
      await mail(id: 'local:d1', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'local:d2', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));

      final since = ago(const Duration(days: 1));
      expect(await store.clearDoubleSpacedMailBodies(sinceIso: since), 0);
      expect(await store.clearLegacyMailBodies(sinceIso: since), 0);

      expect((await row('email', 'local:d1'))['body_text'], doubled);
      expect((await row('email', 'local:d2'))['body_text'], anchorTail);
    });

    test('a row with a pending work item keeps its body', () async {
      // Needs-you, extraction and the embedding read the body, or else the
      // 255-character preview; a verdict from the preview is final.
      await mail(id: 'm-doubled', bodyText: doubled, receivedAt: ago(const Duration(hours: 2)));
      await mail(id: 'm-anchor', bodyText: anchorTail, receivedAt: ago(const Duration(hours: 2)));
      await store.enqueueWork('needs_you', 'email', 'm-doubled');
      await store.enqueueWork('extract', 'email', 'm-anchor');

      final since = ago(const Duration(days: 1));
      expect(await store.clearDoubleSpacedMailBodies(sinceIso: since), 0);
      expect(await store.clearLegacyMailBodies(sinceIso: since), 0);

      expect((await row('email', 'm-doubled'))['body_text'], doubled);
      expect((await row('email', 'm-anchor'))['body_text'], anchorTail);
    });

    test('a row triage is still processing keeps its body', () async {
      await mail(
        id: 'm-busy',
        bodyText: doubled,
        receivedAt: ago(const Duration(hours: 2)),
        triageStatus: 'processing',
      );
      await mail(
        id: 'm-pending',
        bodyText: anchorTail,
        receivedAt: ago(const Duration(hours: 2)),
        triageStatus: 'pending',
      );

      final since = ago(const Duration(days: 1));
      expect(await store.clearDoubleSpacedMailBodies(sinceIso: since), 0);
      expect(await store.clearLegacyMailBodies(sinceIso: since), 0);

      expect((await row('email', 'm-busy'))['body_text'], doubled);
      expect((await row('email', 'm-pending'))['body_text'], anchorTail);
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
    test('a forgotten body and a tidied preview move no watermark at all',
        () async {
      // The order the sync runs them in, over the row they both match — which
      // is most of them, because a message whose body carries a converted link
      // run usually carries one in its snippet too.
      //
      // The collision this pins: if the preview rewrite restamped, the keyword
      // index would resume over a row whose body had just been nulled and file
      // it from the snippet, which is 255 characters of a message it already
      // held whole. The body would come back on the next thread open and the
      // index would never hear about it, because its mark is now above the
      // row. So the first repair's still column is only a guarantee if the
      // second one honours it.
      await mail(
        id: 'm1',
        bodyText: anchorTail,
        bodyPreview: 'View comment <https://requests.example.com/r/42#c7>',
        receivedAt: ago(const Duration(hours: 2)),
      );
      final before = (await row('email', 'm1'))['updated_at'];
      expect(before, isNotNull);

      await store.clearLegacyMailBodies(sinceIso: ago(const Duration(days: 1)));
      await store.tidyMailPreviews();

      final after = await row('email', 'm1');
      expect(after['body_text'], isNull);
      expect(after['body_preview'], 'View comment');
      expect(
        after['updated_at'],
        before,
        reason: 'a bodyless row must not be offered to the index',
      );
    });
  });
}
