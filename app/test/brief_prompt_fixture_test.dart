// The one place a person can read exactly what the model is shown for a
// large meeting, test/fixtures/briefs/large_meeting_prompt.txt, and for a
// small one, test/fixtures/briefs/small_meeting_prompt.txt. On a mismatch
// the test prints the actual text between two marker lines; copy it over.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/home_models.dart' show RelatedConversation;
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/brief_path.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/llm/meeting_brief_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/test_db.dart';

/// A fictional twelve-person topical meeting and a three-person one, each
/// gathered in full over a real in-memory store with a scripted search and a
/// FIXED clock, and laid out as the brief task's user message. Every stamp
/// below is derived from [now], so the text is the same on every run.
void main() {
  setUpAll(initCalendarZones);

  const golden = 'test/fixtures/briefs/large_meeting_prompt.txt';
  const owner = 'me@contoso.com';
  const organiser = 'orla@northwind.com';
  final now = DateTime.utc(2026, 10, 7, 16); // 09:00 in Los Angeles.

  late BondDatabase db;
  late _RelatedStore store;
  late CalendarStore calendar;

  setUp(() {
    db = testDb();
    store = _RelatedStore(db);
    calendar = CalendarStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  String at(Duration ago) => MessageStore.isoStamp(now.subtract(ago));

  Future<void> conversation(String key, String source, String subject,
          {required List<String> people,
          required Duration last,
          required int count}) =>
      store.upsertConversation({
        'source': source,
        'conversation_key': key,
        'subject': subject,
        'participants_json': jsonEncode([
          for (final p in people) {'name': null, 'email': p},
          {'name': 'Me', 'email': owner},
        ]),
        'state': 'waiting',
        'message_count': count,
        'last_message_at': at(last),
      });

  Future<void> message(String id, String key, String source, String subject,
          {required String fromName,
          required String from,
          required Duration ago,
          required String body,
          String? eventId,
          String? gateReason,
          bool outbound = false}) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': outbound ? 'outbound' : 'inbound',
        'subject': subject,
        'from_name': fromName,
        'from_address': from,
        'received_at': at(ago),
        'body_text': body,
        'triage_status': gateReason == null ? 'done' : 'skipped',
        'gate_reason': ?gateReason,
        if (eventId != null)
          'source_meta_json':
              jsonEncode({'meeting': 'meetingRequest', 'event_id': eventId}),
      });

  test('a large topical meeting: the whole user message', () async {
    final zone = CalendarZone.tryNamed('America/Los_Angeles')!;

    // The invite, sent by the organiser, with the plan attached and read.
    const invite = 'Falcon launch readiness';
    await conversation('c-invite', 'email', invite,
        people: const [organiser], last: const Duration(hours: 20), count: 1);
    await message('m-invite', 'c-invite', 'email', invite,
        fromName: 'Orla Grant',
        from: organiser,
        ago: const Duration(hours: 20),
        body: 'Go or no-go for the Falcon launch on 14 October. Please read '
            'the readiness plan before we meet.',
        eventId: 'evt-falcon');
    await store.upsertAttachments('email', 'm-invite', [
      {
        'attachment_id': 'a-plan',
        'ordinal': 0,
        'kind': 'file',
        'name': 'Falcon readiness plan.pdf',
        'content_type': 'application/pdf',
      },
    ]);
    await store.setAttachmentText('email', 'm-invite', 'a-plan',
        status: 'done',
        text: 'Readiness: support staffing at 80 percent. Open risk: the '
            'payment provider has not signed off on the new checkout.');
    await store.setAttachmentDigest('email', 'm-invite', 'a-plan',
        status: 'done',
        digestJson: jsonEncode(const AttachmentDigest(
          kind: 'document',
          summary: 'The plan for a go or no-go on the Falcon launch.',
          facts: [
            'Support staffing is at 80 percent.',
            'Payment sign-off is still open.',
          ],
        ).toJson()));

    // A related mail thread of four; the match is its first message.
    const pricing = 'Falcon checkout pricing';
    await conversation('c-pricing', 'email', pricing,
        people: const ['kim@contoso.com', 'g3@northwind.com'],
        last: const Duration(hours: 3),
        count: 4);
    for (final (id, name, from, ago, body) in [
      ('m-p1', 'Kim Park', 'kim@contoso.com', const Duration(days: 3),
          'Proposal: the Falcon checkout launches at the old price for two weeks.'),
      ('m-p2', 'Kim Park', 'kim@contoso.com', const Duration(days: 2),
          'Finance asked for the discount table.'),
      ('m-p3', 'Ben Okafor', 'g3@northwind.com', const Duration(hours: 9),
          'Finance approved the two-week price hold.'),
      ('m-p4', 'Kim Park', 'kim@contoso.com', const Duration(hours: 3),
          'Then pricing is ready for launch.'),
    ]) {
      await message(id, 'c-pricing', 'email', pricing,
          fromName: name, from: from, ago: ago, body: body);
    }
    await store.insertStoryline(
      id: 's-checkout',
      title: 'Falcon checkout',
      summary: 'Pricing held for two weeks; payment sign-off outstanding.',
      status: 'active',
      createdBy: 'user',
    );
    await store.addStorylineMember('s-checkout', 'email', 'c-pricing',
        addedBy: 'user');

    // A related Teams chat: the match, a bot's post, a person's reply; the
    // room's lunch talk ten hours before and its chatter a day on are not
    // part of the exchange.
    await conversation('t-ops', 'teams', 'Ops room',
        people: const ['teams:kai'], last: const Duration(hours: 1), count: 5);
    await message('t-old', 't-ops', 'teams', 'Ops room',
        fromName: 'Kai Lund',
        from: 'teams:kai',
        ago: const Duration(hours: 40),
        body: 'Lunch order is in.');
    await message('t-match', 't-ops', 'teams', 'Ops room',
        fromName: 'Kai Lund',
        from: 'teams:kai',
        ago: const Duration(hours: 30),
        body: 'The Falcon status page is ready for launch day.');
    await message('t-bot', 't-ops', 'teams', 'Ops room',
        fromName: 'Build Bot',
        from: 'teams:bot',
        ago: const Duration(hours: 29, minutes: 30),
        body: 'Build 412 passed.',
        gateReason: 'auto_generated');
    await message('t-reply', 't-ops', 'teams', 'Ops room',
        fromName: 'Ivy Chen',
        from: 'teams:ivy',
        ago: const Duration(hours: 29),
        body: 'Support has the launch-day rota.');
    await message('t-late', 't-ops', 'teams', 'Ops room',
        fromName: 'Kai Lund',
        from: 'teams:kai',
        ago: const Duration(hours: 1),
        body: 'Who has the spare charger?');

    store.hits = [
      (
        source: 'email',
        conversationKey: 'c-pricing',
        cosine: 0.82,
        messageId: 'm-p1',
        receivedAt: at(const Duration(days: 3)),
      ),
      (
        source: 'teams',
        conversationKey: 't-ops',
        cosine: 0.71,
        messageId: 't-match',
        receivedAt: at(const Duration(hours: 30)),
      ),
    ];

    // An attendee's copy: the organiser is not among the attendees, so
    // `briefOthers` lists them last; eleven attendees and the organiser.
    final start = DateTime.utc(2026, 10, 7, 20); // 1 PM in Los Angeles.
    final event = CalendarEvent(
      id: 'evt-falcon',
      subject: invite,
      startUtc: start,
      endUtc: start.add(const Duration(minutes: 45)),
      responseStatus: 'accepted',
      organizerName: 'Orla Grant',
      organizerAddress: organiser,
      changeKey: 'ck-1',
      bodyPreview: 'Go or no-go for the Falcon launch on 14 October.',
      attendees: const [
        Attendee(name: 'Me', address: owner),
        Attendee(name: 'Ana Ruiz', address: 'g1@northwind.com'),
        Attendee(name: 'Cy Park', address: 'g2@northwind.com'),
        Attendee(name: 'Ben Okafor', address: 'g3@northwind.com'),
        Attendee(name: 'Di Moss', address: 'g4@northwind.com'),
        Attendee(name: 'Ed Vance', address: 'g5@northwind.com'),
        Attendee(name: 'Flo Hart', address: 'g6@northwind.com'),
        Attendee(name: 'Gus Hale', address: 'g7@northwind.com'),
        Attendee(name: 'Hal Moro', address: 'g8@northwind.com'),
        Attendee(name: 'Jo Tate', address: 'g9@northwind.com'),
        Attendee(name: 'Lu Vega', address: 'g10@northwind.com'),
        Attendee(name: 'Ivy Chen', address: 'g11@fabrikam.com'),
      ],
    );

    final gathered = await BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => owner,
      zone: () => zone,
      embeddings: FakeEmbedServer().client,
    ).gather(event, now: now);
    final input = (gathered as BriefEligible).input;
    expect(input.path, BriefPath.related);
    final actual = MeetingBriefTask(
      threadCount: input.threads.length,
      materialCount: input.materials.length,
    ).buildUserMessage(input);

    // The lines a regenerated golden must not lose.
    expect(
        actual,
        contains('Threads related to this meeting, numbered (found by their '
            'text, not by their people):'));
    expect(actual, contains("this meeting's own invite"));
    expect(actual, contains('part of a Teams chat · the latest message shown '
        'is from'));
    const header = 'People who wrote in the threads below (mail or Teams '
        'chat), numbered:\n';
    const tail = '+9 more in the meeting who wrote nothing in these threads\n';
    expect(actual,
        contains('$header[1] <untrusted_data source="person">\nOrla Grant · northwind\n'));
    expect(actual, contains(tail));
    // The block lists only who wrote: the organiser (the invite), Ben (the
    // mail thread) and Ivy (the chat). The rest are on the With: line only.
    final block = actual.substring(
        actual.indexOf(header), actual.indexOf(tail) + tail.length);
    for (final name in ['Orla Grant', 'Ben Okafor', 'Ivy Chen']) {
      expect(block, contains('$name · '), reason: name);
    }
    for (final name in [
      'Ana Ruiz',
      'Cy Park',
      'Di Moss',
      'Ed Vance',
      'Flo Hart',
      'Gus Hale',
      'Hal Moro',
      'Jo Tate',
      'Lu Vega',
    ]) {
      expect(block, isNot(contains(name)), reason: '$name wrote nothing');
      expect(actual, contains(name), reason: '$name is still on With:');
    }
    expect(actual, contains('<untrusted_data source="attendees">\nOrla Grant, '));
    expect(actual, isNot(contains('Build 412 passed.')));
    expect(actual, isNot(contains('spare charger')));
    expect(actual, isNot(contains('Lunch order')));

    final file = File(golden);
    final expected = file.existsSync() ? file.readAsStringSync() : null;
    if (actual != expected) {
      // ignore: avoid_print
      print('----- BEGIN $golden -----\n$actual----- END $golden -----');
    }
    expect(actual, expected, reason: 'regenerate $golden from the output');
  });

  test('a small topical meeting: the whole user message', () async {
    const smallGolden = 'test/fixtures/briefs/small_meeting_prompt.txt';
    const dana = 'dana@fabrikam.com';
    const sam = 'sam@contoso.com';
    final zone = CalendarZone.tryNamed('America/Los_Angeles')!;

    // The invite, sent by Dana, who organised it.
    const invite = 'Fabrikam renewal terms';
    await conversation('c-invite', 'email', invite,
        people: const [dana, sam], last: const Duration(hours: 20), count: 1);
    await message('m-invite', 'c-invite', 'email', invite,
        fromName: 'Dana Lopez',
        from: dana,
        ago: const Duration(hours: 20),
        body: 'Let us agree the renewal terms and the support tier.',
        eventId: 'evt-renewal');

    // Dana's 1:1 chat with the owner, matched by her name: the match and
    // the owner's reply; her note a day on is not part of the exchange.
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': 't-dana',
      'subject': 'Dana Lopez',
      'participants_json': jsonEncode([
        {'name': 'Dana Lopez', 'email': 'teams:dana-id'},
        {'name': 'Me', 'email': 'teams:me-id'},
      ]),
      'state': 'waiting',
      'message_count': 3,
      'last_message_at': at(const Duration(hours: 2)),
    });
    await message('t-match', 't-dana', 'teams', 'Dana Lopez',
        fromName: 'Dana Lopez',
        from: 'teams:dana-id',
        ago: const Duration(hours: 30),
        body: 'The renewal draft caps the price rise at 4 percent.');
    await message('t-reply', 't-dana', 'teams', 'Dana Lopez',
        fromName: 'Me',
        from: 'teams:me-id',
        ago: const Duration(hours: 29),
        body: 'Good. Send me the redline when legal is done.',
        outbound: true);
    await message('t-late', 't-dana', 'teams', 'Dana Lopez',
        fromName: 'Dana Lopez',
        from: 'teams:dana-id',
        ago: const Duration(hours: 2),
        body: 'Running five minutes late.');

    // A mail thread Sam wrote in.
    const support = 'Support tier for the renewal';
    await conversation('c-support', 'email', support,
        people: const [sam], last: const Duration(days: 1), count: 2);
    await message('m-s1', 'c-support', 'email', support,
        fromName: 'Sam Ortiz',
        from: sam,
        ago: const Duration(days: 3),
        body: 'Support stays on the premium tier at the current rate.');
    await message('m-s2', 'c-support', 'email', support,
        fromName: 'Sam Ortiz',
        from: sam,
        ago: const Duration(days: 1),
        body: 'Procurement confirmed the premium tier.');

    // A thread they are only ON: the owner's quote, unanswered.
    const quote = 'Renewal quote';
    await conversation('c-quote', 'email', quote,
        people: const [dana, sam], last: const Duration(hours: 5), count: 1);
    await message('m-quote', 'c-quote', 'email', quote,
        fromName: 'Me',
        from: owner,
        ago: const Duration(hours: 5),
        body: 'The updated quote is attached.',
        outbound: true);

    store.senderHits = [
      (
        source: 'teams',
        conversationKey: 't-dana',
        cosine: 0.78,
        messageId: 't-match',
        receivedAt: at(const Duration(hours: 30)),
      ),
      (
        source: 'email',
        conversationKey: 'c-support',
        cosine: 0.64,
        messageId: 'm-s1',
        receivedAt: at(const Duration(days: 3)),
      ),
    ];

    final start = DateTime.utc(2026, 10, 7, 22); // 3 PM in Los Angeles.
    final event = CalendarEvent(
      id: 'evt-renewal',
      subject: invite,
      startUtc: start,
      endUtc: start.add(const Duration(minutes: 30)),
      responseStatus: 'accepted',
      organizerName: 'Dana Lopez',
      organizerAddress: dana,
      changeKey: 'ck-1',
      bodyPreview: 'Agree the renewal terms and the support tier.',
      attendees: const [
        Attendee(name: 'Me', address: owner),
        Attendee(name: 'Sam Ortiz', address: sam),
        Attendee(name: 'Dana Lopez', address: dana),
      ],
    );

    final gathered = await BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => owner,
      zone: () => zone,
      embeddings: FakeEmbedServer().client,
    ).gather(event, now: now);
    final input = (gathered as BriefEligible).input;
    expect(input.path, BriefPath.people);
    expect(input.search, 'ok');
    expect([for (final t in input.threads) t.conversationKey],
        ['c-invite', 't-dana', 'c-support', 'c-quote']);
    final actual = MeetingBriefTask(
      threadCount: input.threads.length,
      materialCount: input.materials.length,
    ).buildUserMessage(input);

    // The lines a regenerated golden must not lose.
    expect(actual,
        contains('Threads with these people (mail and Teams chats), '
            'numbered:'));
    expect(actual, contains("this meeting's own invite"));
    expect(actual, contains('[2] part of a Teams chat · the latest message '
        'shown is from'));
    expect(actual, contains('People, numbered, the organiser first:'));
    expect(actual, isNot(contains('Running five minutes late.')));

    final file = File(smallGolden);
    final expected = file.existsSync() ? file.readAsStringSync() : null;
    if (actual != expected) {
      // ignore: avoid_print
      print('----- BEGIN $smallGolden -----\n$actual----- END $smallGolden '
          '-----');
    }
    expect(actual, expected, reason: 'regenerate $smallGolden from the output');
  });
}

/// A store whose related search answers [hits], and whose people search
/// ordered by meaning answers [senderHits]: the test is about what the
/// prompt shows, and `message_search_test.dart` tests the real reads.
class _RelatedStore extends MessageStore {
  _RelatedStore(super.db);

  List<RelatedConversation> hits = const [];
  List<RelatedConversation> senderHits = const [];

  @override
  Future<List<RelatedConversation>?> conversationsFromSenders({
    Uint8List? queryEmbedding,
    required String embedModel,
    required Set<String> addresses,
    required Set<String> names,
    required String sinceIso,
    int limit = 12,
  }) async =>
      queryEmbedding == null
          ? super.conversationsFromSenders(
              embedModel: embedModel,
              addresses: addresses,
              names: names,
              sinceIso: sinceIso,
              limit: limit,
            )
          : senderHits.take(limit).toList();

  @override
  Future<List<RelatedConversation>?> relatedConversations(
    Uint8List queryEmbedding, {
    required String embedModel,
    required String sinceIso,
    required double floor,
    int limit = 12,
  }) async =>
      hits.take(limit).toList();
}
