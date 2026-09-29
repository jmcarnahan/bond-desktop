import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/storyline_state.dart';
import 'package:bond_inbox/services/decision/storyline_thread_input.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The storyline thread text built from the database: jev's corpus rules
/// (`distill/storyline_data/corpus.py`) over the app's own rows.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> conversation({
    String source = 'email',
    String key = 'c1',
    String? subject = 'Stored subject',
    List<Map<String, String?>> participants = const [],
  }) =>
      store.upsertConversation({
        'source': source,
        'conversation_key': key,
        'subject': subject,
        'participants_json': jsonEncode(participants),
      });

  Future<void> message(
    String id, {
    String source = 'email',
    String key = 'c1',
    String direction = 'inbound',
    String? subject = 'Lisbon offsite',
    String? fromName = 'Dana Whitfield',
    String? fromAddress = 'dana@example.com',
    List<String> to = const [],
    String? body,
    String? preview,
    required String at,
    String triageStatus = 'triaged',
    String? gateReason,
    int hasAttachments = 0,
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': direction,
        'subject': subject,
        'from_name': fromName,
        'from_address': fromAddress,
        'to_json': jsonEncode(to),
        'received_at': at,
        'body_text': body,
        'body_preview': preview,
        'triage_status': triageStatus,
        'gate_reason': gateReason,
        'has_attachments': hasAttachments,
      });

  Future<void> outbound(
    String id, {
    required String body,
    required String at,
    List<String> to = const [],
    String? subject = 'Re: Lisbon offsite',
  }) =>
      message(id,
          direction: 'outbound',
          subject: subject,
          fromName: 'Alex Stone',
          fromAddress: 'alex@example.org',
          to: to,
          body: body,
          at: at,
          triageStatus: 'skipped',
          gateReason: 'outbound');

  test('mail: the outbound reply is shown, a gated inbound is not', () async {
    await conversation(participants: [
      {'name': 'Sam Rivera', 'email': 'sam@example.org'},
    ]);
    await message('m1',
        body: 'Here are the three venues.', at: '2026-09-01T09:00:00Z');
    await outbound('m2',
        body: 'Riverside looks best.',
        at: '2026-09-01T10:00:00Z',
        to: ['dana@example.com', 'sam@example.org']);
    await message('m3',
        fromName: 'Venue Weekly',
        fromAddress: 'news@example.com',
        body: 'Ten venues you will love.',
        at: '2026-09-01T11:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'newsletter');

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(
      thread.text,
      'Subject: Lisbon offsite\n'
      // Over ALL the messages, as corpus.py reads them: the gated sender is
      // one of the people even though their message is not shown. Sam's
      // name comes from the stored row, since to_json holds addresses only.
      'People: Dana Whitfield, Sam Rivera, Venue Weekly\n'
      'Newest messages, oldest first:\n'
      'Dana Whitfield: Here are the three venues.\n'
      '---\n'
      'You: Riverside looks best.',
    );
    expect(thread.previewRows, 0);
  });

  test('the text is exactly renderStorylineThread over the rows, and the '
      'hash is its sha256', () async {
    await message('m1', body: 'Venues attached.', at: '2026-09-01T09:00:00Z');

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(
      thread.text,
      renderStorylineThread(
        subject: 'Lisbon offsite',
        participants: ['Dana Whitfield'],
        messages: const [
          StorylineMessage(who: 'Dana Whitfield', text: 'Venues attached.'),
        ],
      ),
    );
    expect(thread.cardHash, hasLength(16));
    expect(
      thread.cardHash,
      sha256.convert(utf8.encode(thread.text)).toString().substring(0, 16),
    );
    expect((await storylineThreadTextFor(store, 'email', 'c1')).cardHash,
        thread.cardHash);
  });

  test('Teams: the stored topic is the subject, the stored roster the people',
      () async {
    await conversation(
      source: 'teams',
      key: 'chat-1',
      subject: 'Offsite planning',
      participants: [
        {'name': 'Priya Anand', 'email': 'teams:u-2'},
        {'name': 'Sam Rivera', 'email': 'teams:u-3'},
      ],
    );
    await message('t1',
        source: 'teams',
        key: 'chat-1',
        subject: null,
        fromName: 'Priya Anand',
        fromAddress: 'teams:u-2',
        body: 'Catering quote is in.',
        at: '2026-09-02T09:00:00Z',
        // A chat stored before chats were triaged is kept.
        triageStatus: 'skipped',
        gateReason: 'teams_source');

    final thread = await storylineThreadTextFor(store, 'teams', 'chat-1');

    expect(
      thread.text,
      'Subject: Offsite planning\n'
      'People: Priya Anand, Sam Rivera\n'
      'Newest messages, oldest first:\n'
      'Priya Anand: Catering quote is in.',
    );
  });

  test('a missing name falls back to the address, then to (unknown)',
      () async {
    await message('m1',
        subject: null,
        fromName: null,
        fromAddress: 'ops@example.com',
        body: 'Invoice 4471 attached.',
        at: '2026-09-01T09:00:00Z');
    await message('m2',
        subject: '',
        fromName: '',
        fromAddress: null,
        body: 'Paid.',
        at: '2026-09-01T10:00:00Z');

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(
      thread.text,
      'Subject: (no subject)\n'
      'People: ops@example.com\n'
      'Newest messages, oldest first:\n'
      'ops@example.com: Invoice 4471 attached.\n'
      '---\n'
      '(unknown): Paid.',
    );
  });

  test('more than three shown messages: the newest three, oldest first',
      () async {
    for (var i = 1; i <= 5; i++) {
      await message('m$i', body: 'Message $i.', at: '2026-09-0${i}T09:00:00Z');
    }

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(
      thread.text,
      endsWith('Dana Whitfield: Message 3.\n---\n'
          'Dana Whitfield: Message 4.\n---\n'
          'Dana Whitfield: Message 5.'),
    );
    expect(thread.text, isNot(contains('Message 2.')));
  });

  test('the preview stands in for an empty body, and markers are stripped',
      () async {
    await message('m1',
        body: '', preview: 'From the preview.', at: '2026-09-01T09:00:00Z');
    await message('m2',
        body: 'The plan [[att:a9]]  is attached.',
        at: '2026-09-01T10:00:00Z');

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(
      thread.text,
      endsWith('Dana Whitfield: From the preview.\n---\n'
          'Dana Whitfield: The plan is attached.'),
    );
  });

  test('previewRows counts the rendered rows whose body was never fetched',
      () async {
    // Four shown; the oldest (a preview) falls outside the newest three.
    await message('m1', preview: 'Old preview.', at: '2026-09-01T09:00:00Z');
    await message('m2', body: 'Fetched body.', at: '2026-09-01T10:00:00Z');
    // An outbound reply with no fetched body: Graph's preview, quoted chain
    // and all.
    await outbound('m3',
        body: '',
        at: '2026-09-01T11:00:00Z')
        .then((_) => db.customStatement(
            "UPDATE messages SET body_text = NULL, body_preview = "
            "'Thursday works. On Mon, Dana wrote: Here are the venues' "
            "WHERE source_message_id = 'm3'"));
    await message('m4', preview: 'Pending detail fetch.',
        at: '2026-09-01T12:00:00Z');

    final thread = await storylineThreadTextFor(store, 'email', 'c1');

    expect(thread.previewRows, 2);
    expect(thread.text,
        contains('You: Thursday works. On Mon, Dana wrote: Here are the'));
  });

  group("corpus.py's rules, where the plan's first draft differed", () {
    test('mail people are rebuilt from the messages, not read off the row',
        () async {
      // The stored row lists somebody no message names; the rebuild does
      // not, and an outbound recipient's name is taken from the row.
      await conversation(participants: [
        {'name': 'Kim Lee', 'email': 'kim@example.org'},
        {'name': 'Sam Rivera', 'email': 'sam@example.org'},
      ]);
      await message('m1', body: 'Venues attached.', at: '2026-09-01T09:00:00Z');
      await outbound('m2',
          body: 'Thanks.', at: '2026-09-01T10:00:00Z', to: ['SAM@example.org']);

      final thread = await storylineThreadTextFor(store, 'email', 'c1');

      expect(thread.text, contains('People: Dana Whitfield, Sam Rivera\n'));
    });

    test('ingest order is not received order: the subject and the people '
        'follow received order', () async {
      // The later message was ingested FIRST, so the stored row was named
      // after it and lists its sender first.
      await message('m2',
          subject: 'Re: Porto instead?',
          fromName: 'Jordan Lake',
          fromAddress: 'jordan@example.com',
          body: 'Porto instead?',
          at: '2026-09-02T09:00:00Z');
      await conversation(subject: 'Porto instead?', participants: [
        {'name': 'Jordan Lake', 'email': 'jordan@example.com'},
        {'name': 'Dana Whitfield', 'email': 'dana@example.com'},
      ]);
      await message('m1',
          subject: 'RE: Lisbon offsite',
          body: 'Venues attached.',
          at: '2026-09-01T09:00:00Z');

      final thread = await storylineThreadTextFor(store, 'email', 'c1');

      expect(
        thread.text,
        startsWith('Subject: Lisbon offsite\n'
            'People: Dana Whitfield, Jordan Lake\n'),
      );
    });

    test("the subject is the oldest non-empty one, not the newest message's",
        () async {
      await message('m1',
          subject: 'Re: ', body: 'Hello.', at: '2026-09-01T08:00:00Z');
      await message('m2',
          subject: 'Lisbon offsite', body: 'Venues.', at: '2026-09-01T09:00:00Z');
      await message('m3',
          subject: 'Re: Lisbon offsite - now Porto?',
          body: 'Porto instead?',
          at: '2026-09-01T10:00:00Z');

      final thread = await storylineThreadTextFor(store, 'email', 'c1');

      expect(thread.text, startsWith('Subject: Lisbon offsite\n'));
    });

    test('an empty body shows the attachment stand-in: a card, else names',
        () async {
      await message('m1',
          body: '', at: '2026-09-01T09:00:00Z', hasAttachments: 1);
      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': 'a1', 'ordinal': 0, 'kind': 'file', 'name': 'A.pdf'},
        {'attachment_id': 'a2', 'ordinal': 1, 'kind': 'file', 'name': 'B.xlsx'},
      ]);
      await message('m2',
          body: '[[att:a3]]', at: '2026-09-01T10:00:00Z', hasAttachments: 1);
      await store.upsertAttachments('email', 'm2', [
        {
          'attachment_id': 'a3',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Quote.pdf',
          'card_text': 'Catering quote for 55 guests.',
        },
      ]);

      final thread = await storylineThreadTextFor(store, 'email', 'c1');

      expect(
        thread.text,
        endsWith('Dana Whitfield: Shared a file: A.pdf, B.xlsx\n---\n'
            'Dana Whitfield: Catering quote for 55 guests.'),
      );
    });

    test('an inline-only image with has_attachments = 0 still says so',
        () async {
      await message('m1', body: '', at: '2026-09-01T09:00:00Z');
      await store.upsertAttachments('email', 'm1', [
        {
          'attachment_id': 'i1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'image001.png',
          'is_inline': 1,
        },
      ]);
      await db.customStatement(
          "UPDATE messages SET has_attachments = 0 "
          "WHERE source_message_id = 'm1'");

      final thread = await storylineThreadTextFor(store, 'email', 'c1');

      expect(thread.text, endsWith('Dana Whitfield: Shared an image'));
    });
  });

  test('a thread with no conversation row and no messages renders empty',
      () async {
    final thread = await storylineThreadTextFor(store, 'email', 'none');
    expect(
      thread.text,
      'Subject: (no subject)\nPeople: (none)\nNewest messages, oldest first:\n'
      '(none)',
    );
    expect(thread.previewRows, 0);
  });
}
