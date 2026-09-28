import 'dart:convert';

// `hide Message, Attachment`: drift generates row classes of those names, and
// the ones this file reads stored rows through are the app's models.
import 'package:bond_inbox/data/database.dart' hide Message, Attachment;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `DecisionInput.fromRows` from what the store really returns: the thread as
/// `loadThread` reads it, the message as `getMessageRow` does, and its
/// attachment rows. Plus G7 — what the stored `addressed_me` means on each
/// source, since the decision model reads it as the training data meant it.
/// Every name and address is invented.

const String _owner = 'Rivera, Sam <sam.rivera@example.org>';
const String _me = 'sam.rivera@example.org';

/// The fixture's clock: Pacific daylight time, as the training Mac was in
/// September.
DateTime _pacific(DateTime utc) => utc.add(const Duration(hours: -7));

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });
  tearDown(() async => db.close());

  Future<void> put({
    required String id,
    String source = 'email',
    required String key,
    String direction = 'inbound',
    String? fromName,
    String? fromAddress,
    String? subject,
    List<String> to = const [],
    required String receivedAt,
    String? bodyText,
    String? bodyPreview,
    int addressedMe = 0,
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': direction,
        'from_name': fromName,
        'from_address': fromAddress,
        'subject': subject,
        'to_json': jsonEncode(to),
        'received_at': receivedAt,
        'body_text': bodyText,
        'body_preview': bodyPreview,
        'addressed_me': addressedMe,
      });

  Future<DecisionInput> inputFor(String source, String id, String key) async {
    final message = Message.fromRow((await store.getMessageRow(source, id))!);
    return DecisionInput.fromRows(
      message: message,
      thread: await store.loadThread(key, sources: [source]),
      attachments: [
        for (final row in await store.attachmentsForMessage(source, id))
          AttachmentRef.fromRow(row),
      ],
      owner: _owner,
    );
  }

  group('a mail message in a thread', () {
    const key = 'conv-offsite';
    // 19 code points of prefix, one of them outside the BMP, so the 300 cap
    // is 301 UTF-16 units here.
    const longPrefix = 'Venue \u{1F4CD} shortlist: ';

    setUp(() async {
      await put(
        id: 't1',
        key: key,
        fromName: 'Dana Whitfield',
        fromAddress: 'dana@example.com',
        subject: 'Offsite venues',
        to: const [_me],
        receivedAt: '2026-09-14T15:00:00Z',
        bodyText: 'Starting the venue hunt.',
      );
      await put(
        id: 't2',
        key: key,
        direction: 'outbound',
        fromName: 'Sam Rivera',
        fromAddress: _me,
        subject: 'RE: Offsite venues',
        to: const ['dana@example.com'],
        receivedAt: '2026-09-14T16:00:00Z',
        bodyText: 'Thanks, on it.',
      );
      await put(
        id: 't3',
        key: key,
        fromName: 'Lee Park',
        fromAddress: 'lee@example.com',
        subject: 'RE: Offsite venues',
        to: const [_me],
        receivedAt: '2026-09-14T17:00:00Z',
        bodyText: 'See [[att:AAMk1]]  the draft\n\n\n\nThanks',
      );
      await put(
        id: 't4',
        key: key,
        fromName: 'Dana Whitfield',
        fromAddress: 'dana@example.com',
        subject: 'RE: Offsite venues',
        to: const [_me],
        receivedAt: '2026-09-15T09:00:00Z',
        bodyText: '$longPrefix${'ab' * 200}',
      );
      await put(
        id: 't5',
        key: key,
        direction: 'outbound',
        fromName: 'Sam Rivera',
        fromAddress: _me,
        subject: 'RE: Offsite venues',
        to: const ['dana@example.com'],
        receivedAt: '2026-09-15T12:00:00Z',
        // No body yet: the preview is what the tail falls back to.
        bodyPreview: 'Will do.',
      );
      await put(
        id: 'm',
        key: key,
        fromName: 'Dana Whitfield',
        fromAddress: 'dana@example.com',
        subject: 'Offsite venues',
        to: const [_me, 'lee@example.com'],
        receivedAt: '2026-09-15T17:05:00Z',
        bodyText: 'Could you confirm the venue by Thursday?',
      );
      // After the message: never context for it.
      await put(
        id: 'later',
        key: key,
        fromName: 'Lee Park',
        fromAddress: 'lee@example.com',
        to: const [_me],
        receivedAt: '2026-09-15T18:00:00Z',
        bodyText: 'Booked it.',
      );
      // Inserted out of ordinal order, so the input's order is the store's.
      await store.upsertAttachments('email', 'm', [
        {
          'attachment_id': 'a2',
          'ordinal': 1,
          'name': 'venues.xlsx',
          'card_text': 'Three venues, prices attached',
        },
        {'attachment_id': 'a1', 'ordinal': 0, 'name': 'image001.png', 'is_inline': 1},
      ]);
    });

    test('renders the state a hand-built expectation says', () async {
      final input = await inputFor('email', 'm', key);
      expect(
        renderDecisionState(input, toLocal: _pacific),
        'The reader, the owner of this inbox, is Rivera, Sam '
        '<sam.rivera@example.org>. Any mention of that name or address refers '
        'to the reader.\n'
        '\n'
        'Today is 2026-09-15 (Tuesday).\n'
        '\n'
        'Addressed to: you and 1 others.\n'
        '\n'
        'Recent thread before this message, oldest first, for context only:\n'
        'Lee Park: See the draft\n'
        '\n'
        'Thanks\n'
        '---\n'
        'Dana Whitfield: $longPrefix${('ab' * 200).substring(0, 281)}\n'
        '---\n'
        'You: Will do.\n'
        '\n'
        'The message to judge:\n'
        'From: Dana Whitfield <dana@example.com>\n'
        'Subject: Offsite venues\n'
        'Received: 2026-09-15T17:05:00Z\n'
        '\n'
        'Body:\n'
        'Could you confirm the venue by Thursday?',
      );
    });

    test('the tail is the last three earlier messages, oldest first', () async {
      final input = await inputFor('email', 'm', key);
      expect(input.tail.map((t) => t.who),
          ['Lee Park', 'Dana Whitfield', 'You']);
      // Markers out and the gap tidied; the rest untouched.
      expect(input.tail[0].text, 'See the draft\n\nThanks');
      expect(input.tail[1].text.runes.length, 300);
      expect(input.tail[1].text.length, 301);
      expect(input.tail[2].text, 'Will do.');
    });

    test('the fields come off the row as stored', () async {
      final input = await inputFor('email', 'm', key);
      expect(input.source, 'email');
      expect(input.toCount, 2);
      expect(input.addressedMe, false);
      expect(input.owner, _owner);
      expect(
        [
          for (final a in input.attachments)
            (a.name, a.isInline, a.cardText),
        ],
        [
          ('image001.png', true, null),
          ('venues.xlsx', false, 'Three venues, prices attached'),
        ],
      );
    });

    test('a malformed to_json counts no recipients', () async {
      await db.customStatement(
          "UPDATE messages SET to_json = 'not json' WHERE source_message_id = 'm'");
      expect((await inputFor('email', 'm', key)).toCount, 0);
    });

    test('the first message of a thread has no tail', () async {
      final input = await inputFor('email', 't1', key);
      expect(input.tail, isEmpty);
      expect(renderDecisionState(input, toLocal: _pacific),
          isNot(contains('Recent thread')));
    });
  });

  test('a Teams message: stand-in body, no subject, img markers kept',
      () async {
    const key = 'chat-19:abc@thread.v2';
    await put(
      id: 'c1',
      source: 'teams',
      key: key,
      direction: 'outbound',
      fromName: 'Sam Rivera',
      fromAddress: 'teams:u-sam',
      receivedAt: '2026-09-16T06:00:00Z',
      // An image marker is NOT stripped: training only stripped `att`.
      bodyText: 'Sending the numbers now [[img:i1]]',
    );
    await put(
      id: 'c2',
      source: 'teams',
      key: key,
      fromName: 'Lee Park',
      fromAddress: 'teams:u-lee',
      receivedAt: '2026-09-16T06:30:00Z',
      bodyText: '[[att:f1]]',
      bodyPreview: '',
      addressedMe: 1,
    );
    await store.upsertAttachments('teams', 'c2', [
      {'attachment_id': 'i0', 'ordinal': 0, 'name': 'image.png', 'is_inline': 1},
      {
        'attachment_id': 'f1',
        'ordinal': 1,
        'name': 'budget.xlsx',
        'card_text': '  Q3 budget summary: travel over by 4%  ',
      },
    ]);

    final input = await inputFor('teams', 'c2', key);
    expect(input.toCount, 0);
    expect(input.addressedMe, true);
    expect(
      renderDecisionState(input, toLocal: _pacific),
      'The reader, the owner of this inbox, is Rivera, Sam '
      '<sam.rivera@example.org>. Any mention of that name or address refers '
      'to the reader.\n'
      '\n'
      // 06:30 UTC is 23:30 the evening before in Pacific time.
      'Today is 2026-09-15 (Tuesday).\n'
      '\n'
      'Addressed to: you directly (a 1:1 chat, or you are @mentioned).\n'
      '\n'
      'Recent thread before this message, oldest first, for context only:\n'
      'You: Sending the numbers now [[img:i1]]\n'
      '\n'
      'The message to judge:\n'
      'From: Lee Park\n'
      'Received: 2026-09-16T06:30:00Z\n'
      '\n'
      'Body:\n'
      'Q3 budget summary: travel over by 4%',
    );
  });

  group('decisionOwnerString', () {
    test('composes what it knows', () {
      expect(
        decisionOwnerString((name: 'Rivera, Sam', address: _me)),
        _owner,
      );
      expect(decisionOwnerString((name: null, address: _me)), _me);
      expect(decisionOwnerString((name: 'Sam Rivera', address: ' ')),
          'Sam Rivera');
      expect(decisionOwnerString((name: '', address: null)), isNull);
      expect(decisionOwnerString(null), isNull);
    });
  });

  // G7. Training's rule: mail = the owner is in To AND To has exactly one
  // recipient; Teams = the owner is @mentioned OR the chat is 1:1. The model
  // reads `messages.addressed_me`, so these pin that ingest writes that rule.
  group('G7: what addressed_me means at ingest', () {
    test('Teams: a 1:1 chat or an @mention of the reader, inbound only', () {
      Map<String, dynamic> chat({List<String> mentioning = const []}) => {
            'id': 'x1',
            'messageType': 'message',
            'createdDateTime': '2026-09-15T17:05:00Z',
            'from': {
              'user': {'id': 'u-lee', 'displayName': 'Lee Park'},
            },
            'body': {'contentType': 'text', 'content': 'Numbers?'},
            'mentions': [
              for (final id in mentioning)
                {
                  'id': 0,
                  'mentionText': 'Someone',
                  'mentioned': {
                    'user': {'id': id, 'displayName': 'Someone'},
                  },
                },
            ],
          };
      int? flag(
        Map<String, dynamic> message, {
        bool outbound = false,
        bool oneOnOne = false,
      }) =>
          TeamsSync.messageRow(
            message,
            'chat-1',
            outbound: outbound,
            oneOnOne: oneOnOne,
            mentions: TeamsSync.mentionedUserIds(message['mentions']),
            myId: 'u-sam',
          )!['addressed_me'] as int?;

      expect(flag(chat(), oneOnOne: true), 1, reason: '1:1');
      expect(flag(chat(mentioning: const ['u-sam'])), 1, reason: 'mentioned');
      expect(flag(chat()), 0, reason: 'group, not mentioned');
      expect(flag(chat(mentioning: const ['u-dana'])), 0,
          reason: 'someone else mentioned');
      expect(flag(chat(), outbound: true, oneOnOne: true), 0,
          reason: 'the reader’s own message');
    });

    test('mail: the reader is the ONLY To recipient', () async {
      // Ingest computes this inline in `SyncService` (`soleRecipient`) and
      // `delta_paging_test` drives it through a full sync; the one-time
      // backfill applies the same rule to stored rows, and is callable here.
      Future<void> mail(String id, List<String> to) => put(
            id: id,
            key: 'k-$id',
            fromName: 'Dana Whitfield',
            fromAddress: 'dana@example.com',
            to: to,
            receivedAt: '2026-09-15T17:05:00Z',
            bodyText: 'Hello',
          );
      await mail('sole', const [_me]);
      await mail('shouty', const ['Sam.Rivera@Example.org']);
      await mail('two', const [_me, 'lee@example.com']);
      await mail('other', const ['lee@example.com']);

      await store.backfillEmailAddressedMe(
        userAddress: _me,
        sinceIso: '2026-09-01T00:00:00Z',
      );

      Future<Object?> flag(String id) async =>
          (await store.getMessageRow('email', id))!['addressed_me'];
      expect(await flag('sole'), 1);
      expect(await flag('shouty'), 1);
      expect(await flag('two'), 0);
      expect(await flag('other'), 0);

      // And the decision input reads the column as it stands.
      final sole = await inputFor('email', 'sole', 'k-sole');
      expect(sole.addressedMe, true);
      expect(sole.toCount, 1);
      expect(renderDecisionState(sole, toLocal: _pacific),
          contains('Addressed to: only you.'));
    });
  });
}
