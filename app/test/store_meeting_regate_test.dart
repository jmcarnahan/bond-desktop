import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The meeting-response regate: responses already in the mailbox when the
/// meeting-response gate arrived, gated after the fact. Exchange stores an
/// empty response body as a CRLF, and "nothing in it" must read that as empty
/// too, or the rail keeps every real `Accepted:`.

void main() {
  late BondDatabase db;
  late MessageStore store;

  /// A stamp [hours] back. Derived from now rather than written out, because a
  /// literal date in a fixture rots the day a window walks past it.
  String ago(int hours) => MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(Duration(hours: hours)));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String source = 'email',
    String subject = 'Quarterly planning',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'needs_reply',
      'last_message_at': ago(2),
    });
  }

  /// One inbound message, with only the fields the regate reads spelled out.
  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String from = 'alerts@tracker.example.com',
    String fromName = 'Tracker',
    String subject = 'Quarterly planning',
    int hoursAgo = 2,
    int addressedMe = 0,
    String? bodyText = 'Please take a look when you get a chance.',
    String? bodyPreview = 'Please take a look',
    String? meta,
    String direction = 'inbound',
    int hasAttachments = 0,
  }) async {
    await seedConversation(conversationKey, source: source, subject: subject);
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': fromName,
      'from_address': from,
      'received_at': ago(hoursAgo),
      'is_read': 0,
      'body_text': bodyText,
      'body_preview': bodyPreview,
      'addressed_me': addressedMe,
      'source_meta_json': meta,
      'has_attachments': hasAttachments,
    });
  }

  group('regateMeetingResponses', () {
    test('gates the four response words Graph sends', () async {
      const words = [
        'meetingAccepted',
        'meetingDeclined',
        'meetingCancelled',
        'meetingTenativelyAccepted',
      ];
      for (var i = 0; i < words.length; i++) {
        await seedMessage(
          'm$i',
          conversationKey: 'c$i',
          subject: 'Accepted: Quarterly planning',
          meta: '{"meeting":"${words[i]}"}',
        );
      }

      expect(await store.regateMeetingResponses(), 4);

      for (var i = 0; i < words.length; i++) {
        final row = (await store.getMessageRow('email', 'm$i'))!;
        expect(row['triage_status'], 'skipped', reason: words[i]);
        expect(row['gate_reason'], 'meeting_response', reason: words[i]);
      }
    });

    test('an empty-bodied Accepted: with a file on it is not a response',
        () async {
      // A calendar response carries no attachment; this is somebody sending a
      // signed document with a response-shaped subject.
      await seedMessage(
        'm1',
        subject: 'Accepted: signed offer letter',
        bodyText: null,
        bodyPreview: null,
        hasAttachments: 1,
      );

      expect(await store.regateMeetingResponses(), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['triage_status'],
        'pending',
      );
    });

    test('an invitation is never touched', () async {
      await seedMessage(
        'm1',
        subject: 'Quarterly planning',
        meta: '{"meeting":"meetingRequest"}',
      );

      expect(await store.regateMeetingResponses(), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['triage_status'],
        'pending',
      );
    });

    test('an empty-bodied Accepted: with no meeting field is a response',
        () async {
      await seedMessage(
        'm1',
        subject: 'Tentative: Quarterly planning',
        bodyText: '   ',
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 1);
      expect(
        (await store.getMessageRow('email', 'm1'))!['gate_reason'],
        'meeting_response',
      );
    });

    test('an Exchange-empty body, a bare CRLF, is still nothing in it',
        () async {
      // What the mailbox actually stores for an empty Accepted: — sqlite's
      // one-argument TRIM strips spaces only and kept all of these.
      await seedMessage(
        'm1',
        conversationKey: 'c1',
        subject: 'Accepted: Quarterly planning',
        bodyText: '\r\n',
        bodyPreview: '',
      );
      await seedMessage(
        'm2',
        conversationKey: 'c2',
        subject: 'Canceled: Weekly review',
        bodyText: ' \t\r\n ',
        bodyPreview: '\n',
      );

      expect(await store.regateMeetingResponses(), 2);
      for (final id in ['m1', 'm2']) {
        expect(
          (await store.getMessageRow('email', id))!['gate_reason'],
          'meeting_response',
          reason: id,
        );
      }
    });

    test('a CRLF around real words is still somebody talking', () async {
      await seedMessage(
        'm1',
        subject: 'Canceled: 1:1',
        bodyText: 'PTO\r\n',
        bodyPreview: 'PTO',
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('the same subject with something written in it is somebody talking',
        () async {
      await seedMessage(
        'm1',
        subject: 'Declined: Quarterly planning',
        bodyText: "Sorry, I'm out that week — can we move it?",
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('a reply quoting the prefix is not a response', () async {
      await seedMessage(
        'm1',
        subject: 'Re: Accepted: Quarterly planning',
        bodyText: null,
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('leaves a row the owner restored by hand', () async {
      await seedMessage(
        'm1',
        subject: 'Accepted: Quarterly planning',
        meta: '{"meeting":"meetingAccepted"}',
      );
      await db.customUpdate(
        "UPDATE messages SET gate_override = 'user' WHERE source_message_id = ?",
        variables: [Variable('m1')],
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('a row already gated keeps the reason it has', () async {
      await seedConversation('c1');
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Accepted: Quarterly planning',
        'from_address': 'alex@example.com',
        'received_at': ago(2),
        'is_read': 0,
        'triage_status': 'skipped',
        'gate_reason': 'outbound',
        'source_meta_json': '{"meeting":"meetingAccepted"}',
      });

      expect(await store.regateMeetingResponses(), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['gate_reason'],
        'outbound',
      );
    });

    test('a malformed meta blob costs one row, not the statement', () async {
      await seedMessage(
        'm1',
        conversationKey: 'c1',
        subject: 'Accepted: Quarterly planning',
        meta: 'not json at all',
        bodyText: null,
        bodyPreview: null,
      );
      await seedMessage(
        'm2',
        conversationKey: 'c2',
        subject: 'Accepted: Quarterly planning',
        meta: '{"meeting":"meetingAccepted"}',
      );

      // The unreadable row falls through to the fallback shape, which it also
      // satisfies; what matters is that the good row is still gated.
      expect(await store.regateMeetingResponses(), 2);
      expect(
        (await store.getMessageRow('email', 'm2'))!['gate_reason'],
        'meeting_response',
      );
    });

    test('a chat is not mail', () async {
      await seedMessage(
        'm1',
        source: 'teams',
        conversationKey: 'chat1',
        from: 'teams:19:alex',
        subject: 'Accepted: Quarterly planning',
        bodyText: null,
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 0);
    });
  });
}
