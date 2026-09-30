import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/db.dart' show databaseFileName;
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/sample/sample_backends.dart';
import 'package:bond_inbox/services/sample/sample_data.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sample sandbox's five backends over a tiny FICTIONAL sample written to
/// a temp dir: example.com addresses, invented names. The real recording this
/// build is pointed at never enters the repo, a test or a log.
///
/// The stamps are literal: the backends judge no window of their own, only the
/// floor a test passes, so nothing here rots with the clock.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bond_sample_test_');
    _writeFixture(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  SampleMailBackend mail({int pageSize = 100}) =>
      SampleMailBackend(SampleData.load(dir.path), pageSize: pageSize);
  SampleTeamsBackend teams() => SampleTeamsBackend(SampleData.load(dir.path));

  test('mail drain filters by the floor, carries the delta keys, and stays '
      'drained', () async {
    final backend = mail();
    final page = await backend.deltaPage(
      'inbox',
      minReceivedIso: '2026-01-10T12:00:00Z',
    );
    expect(page.messages.map((m) => m['id']), ['g-in-2']);
    final m = page.messages.single;
    expect(m['isDraft'], false);
    expect(m['receivedDateTime'], '2026-01-11T09:00:00Z');
    expect((m['from'] as Map)['emailAddress']['address'], 'pat@example.com');
    expect(
      [for (final r in m['toRecipients'] as List) r['emailAddress']['address']],
      ['owner@example.com'],
    );
    expect(m['isRead'], true);
    expect(m['hasAttachments'], false);
    expect(m['internetMessageId'], '<in-2@example.com>');
    expect(m['conversationId'], 'conv-b');
    expect(m.containsKey('@removed'), false);
    expect(page.nextLink, isNull);
    expect(page.deltaLink, isNotNull);
    expect(page.hasMore, false);

    final again = await backend.deltaPage('inbox', link: page.deltaLink);
    expect(again.messages, isEmpty);
    expect(again.deltaLink, page.deltaLink);
    expect(again.nextLink, isNull);

    final sent = await backend.deltaPage('sentitems');
    expect(sent.messages.map((m) => m['id']), ['g-out-1']);

    // A folder the sandbox does not serve answers an empty, drained page.
    final junk = await backend.deltaPage('junkemail');
    expect(junk.messages, isEmpty);
    expect(junk.nextLink, isNull);
    expect(junk.deltaLink, isNotNull);
    expect(junk.hasMore, false);

    // A cursor this backend never wrote asks for a clean drain.
    expect(
      () => backend.deltaPage('inbox', link: 'https://example.com/delta'),
      throwsA(isA<DeltaResyncRequired>()),
    );
  });

  test('a cursor from another folder asks for a clean drain', () async {
    final backend = mail(pageSize: 1);
    final first = await backend.deltaPage('inbox');
    expect(first.nextLink, isNotNull);
    expect(
      () => backend.deltaPage('sentitems', link: first.nextLink),
      throwsA(isA<DeltaResyncRequired>()),
    );
  });

  test('the floor rides in the cursor and wins over a later argument',
      () async {
    final backend = mail(pageSize: 1);
    // Below the two newer inbox records, above the oldest.
    var page = await backend.deltaPage(
      'inbox',
      minReceivedIso: '2026-01-09T12:00:00Z',
    );
    final ids = [for (final m in page.messages) m['id'] as String];
    page = await backend.deltaPage('inbox', link: page.nextLink);
    ids.addAll([for (final m in page.messages) m['id'] as String]);
    expect(page.nextLink, isNull);
    expect(page.deltaLink, isNotNull);
    expect(ids, ['g-in-1', 'g-in-2']);

    // The same walk again, now handing a different floor on the next page:
    // the cursor's floor is the drain's, and the argument is ignored.
    final again = await backend.deltaPage(
      'inbox',
      minReceivedIso: '2026-01-09T12:00:00Z',
    );
    final next = await backend.deltaPage(
      'inbox',
      link: again.nextLink,
      minReceivedIso: '2026-01-12T00:00:00Z',
    );
    expect(
      [
        for (final m in [...again.messages, ...next.messages]) m['id'],
      ],
      ['g-in-1', 'g-in-2'],
    );
  });

  test('mail paging walks the folder oldest first through nextLink', () async {
    final backend = mail(pageSize: 1);
    final ids = <String>[];
    DeltaPage page = await backend.deltaPage('inbox');
    var pages = 1;
    while (true) {
      ids.addAll([for (final m in page.messages) m['id'] as String]);
      if (page.nextLink == null) break;
      expect(page.hasMore, true);
      expect(page.deltaLink, isNull);
      page = await backend.deltaPage('inbox', link: page.nextLink);
      pages++;
    }
    expect(pages, 3);
    expect(ids, ['g-in-0', 'g-in-1', 'g-in-2']);
    expect(page.deltaLink, isNotNull);
    expect(page.hasMore, false);
  });

  test('mail detail serves the recorded HTML, headers, meeting type and '
      'attachments in the shape the sync reads', () async {
    final backend = mail();
    final detail = await backend.getMessageDetail('g-in-1');
    // The exact check `_fetchDetailInto` makes before it reads the body.
    expect(detail['uniqueBody'], isA<Map<String, dynamic>>());
    final body = detail['uniqueBody'] as Map;
    expect(body['contentType'], 'html');
    expect(body['content'], '<p>The agenda is attached.</p>');
    final headers = detail['internetMessageHeaders'] as List;
    expect(headers, [
      {'name': 'x-mailer', 'value': 'Example Mail'},
    ]);
    expect(detail['meetingMessageType'], 'meetingRequest');
    expect(detail['hasAttachments'], true);
    final attachments = detail['attachments'] as List;
    expect(attachments.map((a) => a['id']), ['att-1', 'att-2']);
    expect(attachments.first['kind'], 'file');
    expect(attachments.first['size'], 2048);
    expect(attachments.first.containsKey('attachment_id'), false);
    expect(attachments[1]['is_inline'], true);

    // The recording's EVENT type is not Graph's message type; it is left out
    // so the gates' subject fallbacks still run.
    final other = await backend.getMessageDetail('g-in-2');
    expect(other.containsKey('meetingMessageType'), false);
    // No unique body recorded: the full body stands in.
    expect((other['uniqueBody'] as Map)['content'], '<p>Thanks, see you.</p>');

    expect(
      () => backend.getMessageDetail('nope'),
      throwsA(isA<GraphMailException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('Teams serves the chat, never the channel, newest first', () async {
    final backend = teams();
    final chats = await backend.listChats();
    // Newest activity first; the channel is still skipped.
    expect(chats.map((c) => c['id']), ['chat-2', 'chat-1']);
    final chat1 = chats[1];
    expect(
      (chat1['lastMessagePreview'] as Map)['createdDateTime'],
      '2026-01-10T11:00:00Z',
    );
    expect(chat1['viewpoint'], isNull);
    expect(chat1['topic'], isNull);

    final members = await backend.chatMembers('chat-1');
    expect(members, [
      {'displayName': 'Olive Owner', 'userId': 'u-owner'},
      {'displayName': 'Pat Example', 'userId': 'u-pat'},
    ]);

    final all = await backend.chatMessagesSince('chat-1', null);
    expect(all.map((m) => m['id']), ['t-3', 't-2', 't-1']);
    final bot = all.first;
    expect(bot['messageType'], 'message');
    expect((bot['from'] as Map).containsKey('user'), false);
    expect(((bot['from'] as Map)['application'] as Map)['id'], 'app-1');
    expect((bot['body'] as Map)['contentType'], 'text');
    final mention = all[1];
    expect((mention['body'] as Map)['contentType'], 'html');
    expect(mention['mentions'], [
      {
        'mentioned': {
          'user': {'id': 'u-owner'},
        },
      },
    ]);
    final attachments = mention['attachments'] as List;
    expect(attachments.single['id'], 'tatt-1');
    expect(attachments.single['kind'], 'file');
    expect(attachments.single['content_url'], 'https://example.com/f/1');
    expect(((all[2]['from'] as Map)['user'] as Map)['id'], 'u-owner');

    // The cursor is the OLDER message's stamp; the one at a finer precision
    // just after it must still count as newer.
    final since = await backend.chatMessagesSince(
      'chat-1',
      '2026-01-10T10:00:00Z',
    );
    expect(since.map((m) => m['id']), ['t-3', 't-2']);

    expect(await backend.chatMessagesSince('chat-chan', null), isEmpty);
    expect(await backend.myUserId(), 'u-owner');
  });

  test('auth is signed in as the manifest owner', () async {
    final auth = SampleAuthSession(SampleOwner.load(dir.path));
    expect(await auth.isSignedIn, true);
    expect(await auth.needsReconsent, false);
    expect(await auth.hasScope('chat.read'), true);
    final account = await auth.storedAccount;
    expect(account!.mail, 'owner@example.com');
    expect(account.displayName, 'Olive Owner');
    expect((await auth.signIn()).mail, 'owner@example.com');
  });

  test('attachments: recorded text, mapped skip reasons, no bytes', () async {
    final backend = SampleAttachmentBackend(SampleData.load(dir.path));
    expect(backend.maxPreviewBytes, 0);

    final done = await backend.extractText(const AttachmentRef(
      source: 'email',
      messageId: 'g-in-1',
      attachmentId: 'att-1',
    ));
    expect(done.status, 'ok');
    expect(done.text, 'Quarterly plan, draft two.');
    expect(done.truncated, false);

    final inline = await backend.extractText(const AttachmentRef(
      source: 'email',
      messageId: 'g-in-1',
      attachmentId: 'att-2',
    ));
    expect(inline.status, 'skipped');
    expect(inline.reason, 'unsupported');

    final chat = await backend.extractText(const AttachmentRef(
      source: 'teams',
      messageId: 't-2',
      attachmentId: 'tatt-1',
    ));
    expect(chat.status, 'ok');
    expect(chat.text, 'Meeting notes, fictional.');

    final unknown = await backend.extractText(const AttachmentRef(
      source: 'email',
      messageId: 'g-in-2',
      attachmentId: 'missing',
    ));
    expect(unknown.status, 'skipped');
    expect(unknown.reason, 'unavailable');

    expect(
      () => backend.fetchBytes(const AttachmentRef(
        source: 'email',
        messageId: 'g-in-1',
        attachmentId: 'att-1',
      )),
      throwsA(isA<AttachmentUnavailable>()),
    );
  });

  test('skip reasons map into the closed vocabulary', () {
    String r(String? status, String? reason) =>
        SampleAttachmentBackend.skipReasonFor(status, reason);
    expect(r('skipped', 'too_large'), 'too_large');
    expect(r('unsupported', 'no_extractor'), 'no_extractor');
    expect(r('skipped', 'inline'), 'unsupported');
    expect(r('skipped', 'per_message_cap'), 'unsupported');
    expect(r('skipped', 'kind_message_reference'), 'unsupported');
    expect(r('empty', 'no_text'), 'empty');
    expect(r('empty', null), 'empty');
    // A failure's reason is an error body; it never reaches the chip.
    expect(r('failed', 'HTTP 403 {"error": "denied"}'), 'unavailable');
    expect(r('skipped', 'not_fetched'), 'unavailable');
    expect(r('skipped', 'reference'), 'reference');
    expect(r('skipped', 'something new'), 'unsupported');
  });

  test('people: substring search, blank query empty', () async {
    final backend = SamplePeopleBackend(SampleData.load(dir.path));
    final hits = await backend.searchPeople('quin');
    expect(hits.single.displayName, 'Quinn Sample');
    expect(hits.single.id, 'mail:quinn@example.com');
    final byAddress = await backend.searchPeople('PAT@EXAMPLE');
    expect(byAddress.single.id, 'u-pat');
    expect(await backend.searchPeople('   '), isEmpty);
    expect(await backend.profilePhoto('u-pat'), isNull);
  });

  test('writes refuse; read acks answer without a throw', () async {
    final m = mail();
    final t = teams();
    await expectLater(
      m.createReplyDraft('g-in-1'),
      throwsA(isA<GraphMailException>()
          .having((e) => e.message, 'message', contains('sandbox'))),
    );
    await expectLater(
      m.createDraft(to: const ['pat@example.com'], subject: 's', body: 'b'),
      throwsA(isA<GraphMailException>()),
    );
    await expectLater(m.sendDraft('d'), throwsA(isA<GraphMailException>()));
    await expectLater(
      m.updateDraftBody('d', 'x'),
      throwsA(isA<GraphMailException>()),
    );
    await expectLater(
      t.sendChatMessage('chat-1', 'hi'),
      throwsA(isA<GraphTeamsException>()
          .having((e) => e.message, 'message', contains('sandbox'))),
    );
    await expectLater(
      t.ensureChat(const ['u-pat']),
      throwsA(isA<GraphTeamsException>()),
    );
    expect(await m.markRead(const ['g-in-1']), isEmpty);
    await t.markChatRead('chat-1');
  });

  test('a malformed line is skipped and the records around it still load',
      () async {
    final other = Directory.systemTemp.createTempSync('bond_sample_bad_');
    addTearDown(() => other.deleteSync(recursive: true));
    File('${other.path}/manifest.json').writeAsStringSync(jsonEncode({
      'owners': {
        'o': {'primary_address': 'owner@example.com', 'display_name': 'O'},
      },
    }));
    final owner = _person('Olive Owner', 'owner@example.com');
    final pat = _person('Pat Example', 'pat@example.com');
    Map<String, Object?> rec(String id, String at) => _mail(
          sampleId: 's-$id',
          graphId: 'g-$id',
          family: 'inbox',
          direction: 'inbound',
          receivedAt: at,
          conversationId: 'conv-$id',
          from: pat,
          to: [owner],
          body: '<p>Body of $id.</p>',
        );
    final text = [
      jsonEncode(rec('a', '2026-01-01T09:00:00Z')),
      '{"this is not": json',
      jsonEncode(rec('b', '2026-01-02T09:00:00Z')),
    ].join('\n');
    final shard = File('${other.path}/messages/mail-000.jsonl.gz');
    shard.parent.createSync(recursive: true);
    shard.writeAsBytesSync(gzip.encode(utf8.encode(text)));

    final backend = SampleMailBackend(SampleData.load(other.path));
    final page = await backend.deltaPage('inbox');
    expect(page.messages.map((m) => m['id']), ['g-a', 'g-b']);
    // The record after the bad line still re-reads from its own line.
    final detail = await backend.getMessageDetail('g-b');
    expect((detail['uniqueBody'] as Map)['content'], '<p>Body of b.</p>');
  });

  test('the sandbox has its own database file name', () {
    expect(databaseFileName(sampleMode: false), 'bond_inbox.db');
    expect(databaseFileName(sampleMode: true), 'bond_inbox-sample.db');
  });
}

// ---------------------------------------------------------------------------
// The fictional fixture.
// ---------------------------------------------------------------------------

void _writeGz(File file, List<Map<String, Object?>> records) {
  file.parent.createSync(recursive: true);
  // A blank line between records, as a hand-edited shard might carry: the
  // loader and the detail re-read must both skip it the same way.
  final text = records.map(jsonEncode).join('\n\n');
  file.writeAsBytesSync(gzip.encode(utf8.encode('$text\n')));
}

Map<String, Object?> _person(String name, String address) =>
    {'name': name, 'address': address};

Map<String, Object?> _mail({
  required String sampleId,
  required String graphId,
  required String family,
  required String direction,
  required String receivedAt,
  required String conversationId,
  required Map<String, Object?> from,
  required List<Map<String, Object?>> to,
  String? uniqueBody,
  String body = '',
  Map<String, Object?>? meeting,
  List<Map<String, Object?>> attachments = const [],
  Map<String, Object?> headers = const {},
}) =>
    {
      'sample_id': sampleId,
      'source': 'email',
      'graph': {
        'id': graphId,
        'internet_message_id': '<${graphId.substring(2)}@example.com>',
        'conversation_id': conversationId,
      },
      'folder_family': family,
      'direction': direction,
      'received_at': receivedAt,
      'from': from,
      'to': to,
      'subject': 'Subject of $graphId',
      'body_preview': 'Preview of $graphId',
      'body_html': body,
      'unique_body_html': uniqueBody,
      'is_read': true,
      'headers': headers,
      'meeting': meeting,
      'has_attachments': attachments.isNotEmpty,
      'attachments': attachments,
    };

Map<String, Object?> _chatMessage({
  required String sampleId,
  required String id,
  required String chatId,
  required String type,
  required String createdAt,
  required Map<String, Object?> from,
  String? html,
  String text = '',
  List<Map<String, Object?>> mentions = const [],
  List<Map<String, Object?>> attachments = const [],
}) =>
    {
      'sample_id': sampleId,
      'source': 'teams',
      'graph': {'id': id, 'chat_id': chatId},
      'chat': {
        'type': type,
        'topic': null,
        'members': type == 'channel'
            ? const []
            : [
                {'user_id': 'u-owner', 'name': 'Olive Owner'},
                {'user_id': 'u-pat', 'name': 'Pat Example'},
              ],
      },
      'channel': type == 'channel' ? {'id': 'ch-1'} : null,
      'message_type': 'message',
      'received_at': createdAt,
      'modified_at': createdAt,
      'from': from,
      'mentions': mentions,
      'body_content_type': html == null ? 'text' : 'html',
      'body_html': html,
      'body_text': text,
      'attachments': attachments,
    };

void _writeFixture(Directory dir) {
  File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
    'owners': {
      'owner-1': {
        'primary_address': 'owner@example.com',
        'display_name': 'Olive Owner',
        'teams_user_id': 'u-owner',
      },
    },
  }));

  final owner = _person('Olive Owner', 'owner@example.com');
  final pat = _person('Pat Example', 'pat@example.com');
  // Written out of order: the loader sorts each folder by time.
  _writeGz(File('${dir.path}/messages/mail-000.jsonl.gz'), [
    _mail(
      sampleId: 's-in-2',
      graphId: 'g-in-2',
      family: 'inbox',
      direction: 'inbound',
      receivedAt: '2026-01-11T09:00:00Z',
      conversationId: 'conv-b',
      from: pat,
      to: [owner],
      body: '<p>Thanks, see you.</p>',
      meeting: {'type': 'singleInstance'},
    ),
    _mail(
      sampleId: 's-in-1',
      graphId: 'g-in-1',
      family: 'inbox',
      direction: 'inbound',
      receivedAt: '2026-01-10T09:00:00Z',
      conversationId: 'conv-a',
      from: pat,
      to: [owner],
      uniqueBody: '<p>The agenda is attached.</p>',
      body: '<p>The agenda is attached.</p><p>Earlier text.</p>',
      meeting: {'type': 'meetingRequest'},
      headers: {'x-mailer': 'Example Mail', 'x-empty': null},
      attachments: [
        {
          'attachment_id': 'att-1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'plan.docx',
          'content_type': 'application/octet-stream',
          'size': 2048,
          'is_inline': false,
          'content_id': null,
        },
        {
          'attachment_id': 'att-2',
          'ordinal': 1,
          'kind': 'file',
          'name': 'logo.png',
          'content_type': 'image/png',
          'size': 100,
          'is_inline': true,
          'content_id': 'logo@example',
        },
      ],
    ),
    _mail(
      sampleId: 's-out-1',
      graphId: 'g-out-1',
      family: 'sentitems',
      direction: 'outbound',
      receivedAt: '2026-01-10T12:00:00Z',
      conversationId: 'conv-a',
      from: owner,
      to: [pat],
      body: '<p>Got it.</p>',
    ),
    _mail(
      sampleId: 's-in-0',
      graphId: 'g-in-0',
      family: 'inbox',
      direction: 'inbound',
      receivedAt: '2026-01-09T09:00:00Z',
      conversationId: 'conv-c',
      from: pat,
      to: [owner],
      body: '<p>Hello.</p>',
    ),
    _mail(
      sampleId: 's-junk-1',
      graphId: 'g-junk-1',
      family: 'junkemail',
      direction: 'inbound',
      receivedAt: '2026-01-10T15:00:00Z',
      conversationId: 'conv-j',
      from: pat,
      to: [owner],
    ),
  ]);

  _writeGz(File('${dir.path}/messages/teams-000.jsonl.gz'), [
    _chatMessage(
      sampleId: 's-ch-1',
      id: 'ch-msg-1',
      chatId: 'chat-chan',
      type: 'channel',
      createdAt: '2026-01-10T12:00:00Z',
      from: {'user_id': 'u-pat', 'name': 'Pat Example'},
      text: 'Channel post.',
    ),
    _chatMessage(
      sampleId: 's-t-1',
      id: 't-1',
      chatId: 'chat-1',
      type: 'oneOnOne',
      createdAt: '2026-01-10T10:00:00Z',
      from: {'user_id': 'u-owner', 'name': 'Olive Owner'},
      text: 'Morning.',
    ),
    _chatMessage(
      sampleId: 's-t-2',
      id: 't-2',
      chatId: 'chat-1',
      type: 'oneOnOne',
      createdAt: '2026-01-10T10:00:00.5Z',
      from: {'user_id': 'u-pat', 'name': 'Pat Example'},
      html: '<p><at id="0">Olive</at> can you look?</p>',
      mentions: [
        {'user_id': 'u-owner', 'name': 'Olive', 'is_owner': true},
        {'user_id': null, 'name': 'Everyone', 'is_owner': false},
      ],
      attachments: [
        {
          'attachment_id': 'tatt-1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'notes.txt',
          'content_type': 'reference',
          'content_url': 'https://example.com/f/1',
        },
      ],
    ),
    _chatMessage(
      sampleId: 's-g-1',
      id: 'g-1',
      chatId: 'chat-2',
      type: 'group',
      createdAt: '2026-01-10T13:00:00Z',
      from: {'user_id': 'u-pat', 'name': 'Pat Example'},
      text: 'Group hello.',
    ),
    _chatMessage(
      sampleId: 's-t-3',
      id: 't-3',
      chatId: 'chat-1',
      type: 'oneOnOne',
      createdAt: '2026-01-10T11:00:00Z',
      from: {'application_id': 'app-1', 'name': 'Build Bot', 'is_bot': true},
      text: 'Build passed.',
    ),
  ]);

  _writeGz(File('${dir.path}/attachments.jsonl.gz'), [
    {
      'sample_id': 's-in-1',
      'source': 'email',
      'attachment_id': 'att-1',
      'text_status': 'done',
      'text': 'Quarterly plan, draft two.',
      'truncated': false,
    },
    {
      'sample_id': 's-t-2',
      'source': 'teams',
      'attachment_id': 'tatt-1',
      'text_status': 'done',
      'text': 'Meeting notes, fictional.',
    },
    {
      'sample_id': 's-in-1',
      'source': 'email',
      'attachment_id': 'att-2',
      'text_status': 'skipped',
      'text_reason': 'inline',
    },
  ]);

  _writeGz(File('${dir.path}/people.jsonl.gz'), [
    {
      'name': 'Pat Example',
      'address': 'pat@example.com',
      'teams_user_id': 'u-pat',
      'internal': true,
    },
    {
      'name': 'Quinn Sample',
      'address': 'quinn@example.com',
      'teams_user_id': null,
      'internal': false,
    },
  ]);
}
