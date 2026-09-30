import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The brief's inputs, gathered over a real in-memory store: who counts as
/// someone else, which meetings are eligible (D6), how threads rank, what an
/// open ask is, the caps, the fencing, and the inputs hash. Fixture times are
/// derived from the clock, so the 36-hour and 30-day windows never rot.
void main() {
  setUpAll(initCalendarZones);

  const owner = 'me@contoso.com';
  const dana = 'dana@fabrikam.com';
  const sam = 'sam@fabrikam.com';

  late BondDatabase db;
  late MessageStore store;
  late CalendarStore calendar;
  late CalendarZone la;
  late BriefGatherer gatherer;
  late DateTime now;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    calendar = CalendarStore(db);
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    gatherer = BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => owner,
      zone: () => la,
    );
    now = DateTime.now().toUtc();
  });

  tearDown(() async {
    await db.close();
  });

  String stampAgo(Duration d) => MessageStore.isoStamp(now.subtract(d));

  CalendarEvent meeting({
    String id = 'evt-1',
    Duration startsIn = const Duration(hours: 3),
    List<Attendee>? attendees,
    bool isCancelled = false,
    bool isOrganizer = false,
    String responseStatus = 'accepted',
    String organizerAddress = '',
    String bodyPreview = '',
    String changeKey = 'ck-1',
  }) {
    final start = now.add(startsIn);
    return CalendarEvent(
      id: id,
      subject: 'Fabrikam sync',
      startUtc: start,
      endUtc: start.add(const Duration(minutes: 30)),
      isCancelled: isCancelled,
      isOrganizer: isOrganizer,
      responseStatus: responseStatus,
      organizerAddress: organizerAddress,
      bodyPreview: bodyPreview,
      changeKey: changeKey,
      attendees: attendees ??
          const [
            Attendee(name: 'Me', address: owner),
            Attendee(name: 'Dana Lee', address: dana),
          ],
    );
  }

  Future<void> conversation(
    String key, {
    String state = 'waiting',
    List<String> people = const [dana],
    Duration ago = const Duration(hours: 2),
    int count = 1,
    String? subject,
  }) =>
      store.upsertConversation({
        'source': 'email',
        'conversation_key': key,
        'subject': subject ?? 'Thread $key',
        'participants_json': jsonEncode([
          for (final p in people) {'name': null, 'email': p},
          {'name': 'Me', 'email': owner},
        ]),
        'state': state,
        'message_count': count,
        'last_message_at': stampAgo(ago),
      });

  Future<void> message(
    String id,
    String key, {
    bool outbound = false,
    String from = dana,
    String fromName = 'Dana',
    String body = 'Hello there.',
    Duration ago = const Duration(hours: 2),
  }) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': outbound ? 'outbound' : 'inbound',
        'subject': 'Thread $key',
        'from_name': outbound ? 'Me' : fromName,
        'from_address': outbound ? owner : from,
        'received_at': stampAgo(ago),
        'body_text': body,
        'triage_status': 'done',
      });

  Future<void> decide(
    String id, {
    String urgency = 'normal',
    String importance = 'normal',
    double needsYou = 0.2,
    double reply = 0.2,
    String intent = 'fyi',
  }) =>
      store.writeDecision(
        'email',
        id,
        fakeDecision(fakeAnswers(
          urgency: urgency,
          importance: importance,
          needsYou: needsYou,
          replyExpected: reply,
          intent: intent,
        )),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );

  /// A thread with Dana: a conversation row and one inbound message.
  Future<void> thread(
    String key, {
    String state = 'waiting',
    Duration ago = const Duration(hours: 2),
    String body = 'Hello there.',
  }) async {
    await conversation(key, state: state, ago: ago);
    await message('m-$key', key, body: body, ago: ago);
  }

  Future<BriefInput> eligible(CalendarEvent e) async {
    final g = await gatherer.gather(e, now: now);
    expect(g, isA<BriefEligible>());
    return (g as BriefEligible).input;
  }

  Future<BriefIneligibility> ineligible(CalendarEvent e) async {
    final g = await gatherer.gather(e, now: now);
    expect(g, isA<BriefIneligible>());
    return (g as BriefIneligible).why;
  }

  group('eligibility', () {
    setUp(() async => thread('c-1'));

    test('a meeting soon, with Dana, with mail: eligible', () async {
      await eligible(meeting());
    });

    test('started, too far off, cancelled, declined', () async {
      expect(await ineligible(meeting(startsIn: const Duration(hours: -1))),
          BriefIneligibility.past);
      expect(await ineligible(meeting(startsIn: const Duration(hours: 40))),
          BriefIneligibility.tooFar);
      expect(await ineligible(meeting(isCancelled: true)),
          BriefIneligibility.cancelled);
      expect(await ineligible(meeting(responseStatus: 'declined')),
          BriefIneligibility.declined);
    });

    test('nobody else: no attendees, only the owner, only a room', () async {
      expect(
          await ineligible(meeting(attendees: const [], isOrganizer: true)),
          BriefIneligibility.noOthers);
      expect(
        await ineligible(meeting(
          attendees: const [Attendee(name: 'Me', address: 'ME@contoso.com')],
          isOrganizer: true,
        )),
        BriefIneligibility.noOthers,
        reason: 'the owner is matched case-insensitively',
      );
      expect(
        await ineligible(meeting(
          attendees: const [
            Attendee(name: 'Room 4', address: 'room4@contoso.com', type: 'resource'),
          ],
          isOrganizer: true,
        )),
        BriefIneligibility.noOthers,
      );
    });

    test("an attendee's copy with a hidden guest list still has its "
        'organiser', () async {
      final input = await eligible(meeting(
        attendees: const [],
        organizerAddress: dana,
      ));
      expect(input.attendees, [dana]);
    });

    test('no mail with them in thirty days', () async {
      expect(
        await ineligible(meeting(attendees: const [
          Attendee(name: 'Sam', address: sam),
        ])),
        BriefIneligibility.noMail,
      );
      await conversation('c-old', people: const [sam], ago: const Duration(days: 40));
      expect(
        await ineligible(meeting(attendees: const [
          Attendee(name: 'Sam', address: sam),
        ])),
        BriefIneligibility.noMail,
        reason: 'forty days is outside the window',
      );
    });

    test('the owner is never one of the attendees', () async {
      final input = await eligible(meeting());
      expect(input.attendees, ['Dana Lee']);
    });

    test('the 36-hour edge: exactly 36 hours is in, a minute past is out',
        () async {
      await eligible(meeting(startsIn: briefHorizon));
      expect(
        await ineligible(
            meeting(startsIn: briefHorizon + const Duration(minutes: 1))),
        BriefIneligibility.tooFar,
      );
    });

    test('more than fifteen other people is too many; fifteen is not',
        () async {
      List<Attendee> people(int n) => [
            const Attendee(name: 'Dana Lee', address: dana),
            for (var i = 1; i < n; i++)
              Attendee(name: 'Guest $i', address: 'guest$i@fabrikam.com'),
          ];
      await eligible(meeting(attendees: people(briefMaxOthers)));
      expect(await ineligible(meeting(attendees: people(briefMaxOthers + 1))),
          BriefIneligibility.tooMany);
      expect(BriefIneligibility.tooMany.wire, 'too_many');
    });

    test('an all-day event tomorrow with Dana and mail is eligible, and its '
        'line says All day', () async {
      final tomorrow = la.dateOf(now).addDays(1);
      final input = await eligible(CalendarEvent(
        id: 'evt-allday',
        subject: 'Offsite',
        isAllDay: true,
        startDate: tomorrow,
        endDate: tomorrow.addDays(1),
        responseStatus: 'accepted',
        attendees: const [Attendee(name: 'Dana Lee', address: dana)],
      ));
      expect(input.whenLocal, startsWith('All day · '));
      expect(input.whenLocal, contains('${tomorrow.year}'));
    });
  });

  group('the absolute lines', () {
    test('a timed meeting names its day, date, year and zone', () {
      final start = DateTime.utc(2026, 10, 7, 17);
      final line = briefWhenLine(
        CalendarEvent(
          id: 'e',
          startUtc: start,
          endUtc: start.add(const Duration(hours: 1)),
        ),
        la,
      );
      expect(line, 'Wed 7 Oct 2026 · 10:00–11:00 AM PDT');
    });

    test('an all-day meeting, one day and several', () {
      const day = CalendarDate(2026, 10, 7);
      expect(
        briefWhenLine(
          CalendarEvent(
              id: 'e', isAllDay: true, startDate: day, endDate: day.addDays(1)),
          la,
        ),
        'All day · Wed 7 Oct 2026',
      );
      expect(
        briefWhenLine(
          CalendarEvent(
              id: 'e', isAllDay: true, startDate: day, endDate: day.addDays(3)),
          la,
        ),
        'All day · Wed 7 Oct 2026 – Fri 9 Oct 2026',
      );
    });

    test('now, in the display zone', () {
      expect(briefNowLine(DateTime.utc(2026, 9, 29, 22, 5), la),
          'Tue 29 Sep 2026, 3:05 PM PDT');
      expect(briefNowLine(DateTime.utc(2026, 12, 1, 18), la),
          'Tue 1 Dec 2026, 10:00 AM PST');
    });

    test('a stamp as an age from now', () {
      final at = DateTime.utc(2026, 9, 29, 12);
      String ago(Duration d) =>
          briefAgo(MessageStore.isoStamp(at.subtract(d)), at);
      expect(ago(const Duration(seconds: 20)), 'just now');
      expect(ago(const Duration(minutes: 1)), '1 minute ago');
      expect(ago(const Duration(minutes: 45)), '45 minutes ago');
      expect(ago(const Duration(hours: 1)), '1 hour ago');
      expect(ago(const Duration(hours: 3)), '3 hours ago');
      expect(ago(const Duration(days: 2, hours: 5)), '2 days ago');
      expect(ago(const Duration(minutes: -5)), 'just now',
          reason: 'clock skew is not a negative age');
      expect(briefAgo('', at), '');
      expect(briefAgo('not a stamp', at), '');
    });

    test('the gathered input carries the clock line and the instant', () async {
      await thread('c-1');
      final input = await eligible(meeting());
      expect(input.nowLocal, briefNowLine(now, la));
      expect(input.now, now);
      expect(input.whenLocal, isNot(startsWith('Today')));
      expect(input.whenLocal, isNot(startsWith('Tomorrow')));
    });
  });

  test('ranking: an urgent or important thread first, then recency', () async {
    await thread('c-old-urgent', ago: const Duration(days: 5));
    await decide('m-c-old-urgent', urgency: 'high');
    await thread('c-mid', ago: const Duration(days: 2));
    await thread('c-new', ago: const Duration(hours: 1));
    await thread('c-important', ago: const Duration(days: 9));
    await decide('m-c-important', importance: 'high');

    final input = await eligible(meeting());
    expect([for (final t in input.threads) t.conversationKey],
        ['c-old-urgent', 'c-important', 'c-new', 'c-mid']);
    expect([for (final t in input.threads) t.ranked], [true, true, false, false]);
  });

  group('open asks', () {
    test('by the decision thresholds, labelled by intent', () async {
      await thread('c-ask', state: 'needs_reply', ago: const Duration(hours: 1));
      await decide('m-c-ask', needsYou: 0.7, intent: 'question');
      await thread('c-reply', state: 'needs_reply', ago: const Duration(hours: 2));
      await decide('m-c-reply', reply: 0.6, intent: 'approval');
      await thread('c-low', state: 'needs_reply', ago: const Duration(hours: 3));
      await decide('m-c-low', needsYou: 0.3, intent: 'question');
      await thread('c-fyi', state: 'needs_reply', ago: const Duration(hours: 4));
      await decide('m-c-fyi', needsYou: 0.9, intent: 'fyi');
      await thread('c-done', state: 'done', ago: const Duration(hours: 5));
      await decide('m-c-done', needsYou: 0.9, intent: 'request');

      final input = await eligible(meeting());
      final keys = [for (final t in input.threads) t.conversationKey];
      expect(
        [
          for (final a in input.openAsks)
            (keys[a.threadIndex], a.intent, a.person),
        ],
        [('c-ask', 'question', 'Dana Lee'), ('c-reply', 'approval', 'Dana Lee')],
      );
    });

    test('an ask the owner has since replied to is not open', () async {
      await conversation('c-1', state: 'needs_reply', count: 3);
      await message('m-1', 'c-1', ago: const Duration(hours: 5));
      await decide('m-1', needsYou: 0.9, intent: 'request');
      await message('m-2', 'c-1', outbound: true, ago: const Duration(hours: 4));
      await message('m-3', 'c-1', ago: const Duration(hours: 3));
      await decide('m-3', needsYou: 0.1, intent: 'social');

      final input = await eligible(meeting());
      expect(input.openAsks, isEmpty);
    });
  });

  test('waiting on them: state waiting and the owner wrote last', () async {
    await conversation('c-w', ago: const Duration(hours: 1), count: 2);
    await message('m-w1', 'c-w', ago: const Duration(hours: 3));
    await message('m-w2', 'c-w', outbound: true, ago: const Duration(hours: 1));
    await thread('c-theirs', ago: const Duration(hours: 2));

    final input = await eligible(meeting());
    expect([for (final t in input.waitingOn) t.conversationKey], ['c-w']);
  });

  group('caps', () {
    test('seven threads → six; five asks → four; ten files → eight', () async {
      for (var i = 0; i < 7; i++) {
        await thread('c-$i', state: 'needs_reply', ago: Duration(hours: i + 1));
        await decide('m-c-$i', needsYou: 0.9, intent: 'request');
      }
      for (var i = 0; i < 10; i++) {
        await store.upsertAttachments('email', 'm-c-${i % 6}', [
          {
            'attachment_id': 'a-$i',
            'ordinal': i,
            'kind': 'file',
            'name': 'file-$i.pdf',
            'is_inline': 0,
          },
        ]);
      }
      // Not files: an inline logo.
      await store.upsertAttachments('email', 'm-c-0', [
        {
          'attachment_id': 'logo',
          'ordinal': 99,
          'kind': 'file',
          'name': 'logo.png',
          'is_inline': 1,
        },
      ]);

      final input = await eligible(meeting());
      expect(input.threads, hasLength(BriefGatherer.maxThreads));
      expect(input.openAsks, hasLength(BriefGatherer.maxAsks));
      expect(input.files, hasLength(BriefGatherer.maxFiles));
      expect(input.files, isNot(contains('logo.png')));
    });

    test('three storylines → two, the summary fenced', () async {
      for (var i = 0; i < 3; i++) {
        await thread('c-$i', ago: Duration(hours: i + 1));
        await store.insertStoryline(
          id: 's-$i',
          title: 'Storyline $i',
          summary: 'Where $i stands.',
          status: 'active',
          createdBy: 'user',
        );
        await store.addStorylineMember('s-$i', 'email', 'c-$i', addedBy: 'user');
      }
      final input = await eligible(meeting());
      expect([for (final s in input.storylines) s.id], ['s-0', 's-1']);
      expect(input.storylines.first.summary,
          startsWith('<untrusted_data source="storyline">'));
      expect(input.storylines.first.summary, contains('Where 0 stands.'));
    });
  });

  test('every snippet, ask and the invite text arrive fenced and capped',
      () async {
    await conversation('c-1', state: 'needs_reply', count: 3);
    await message('m-1', 'c-1', body: 'First.', ago: const Duration(hours: 5));
    await message('m-2', 'c-1',
        body: 'Second <b>bold</b>.', ago: const Duration(hours: 4));
    await message('m-3', 'c-1', body: 'x' * 2000, ago: const Duration(hours: 3));
    await decide('m-3', needsYou: 0.9, intent: 'request');

    final input = await eligible(meeting(bodyPreview: 'Agenda: renewal.'));
    final snippets = input.threads.single.snippets;
    expect(snippets, hasLength(2), reason: 'the last two messages');
    for (final s in snippets) {
      expect(s, startsWith('<untrusted_data source="message">'));
      expect(s, endsWith('</untrusted_data>'));
    }
    expect(snippets.first, contains('&lt;b&gt;'), reason: 'escaped, not raw');
    // The cap holds on the text inside the fence.
    expect(snippets.last.length,
        lessThan(BriefGatherer.snippetCap + 100));
    expect(input.openAsks.single.ask, startsWith('<untrusted_data source="ask">'));
    expect(input.invitePreview, startsWith('<untrusted_data source="invite">'));
  });

  test('the inputs hash is stable, and a new message moves it', () async {
    await thread('c-1');
    final first = (await eligible(meeting())).inputsHash;
    final again = (await eligible(meeting())).inputsHash;
    expect(again, first);

    // An edit to an existing message's text alone (same stamp, same count)
    // is not a new input: the hash reads ids and stamps, never snippets.
    await message('m-c-1', 'c-1', body: 'Hello there, edited.');
    final edited = await eligible(meeting());
    expect(edited.threads.single.snippets.single, contains('edited'));
    expect(edited.inputsHash, first);

    await message('m-new', 'c-1', ago: const Duration(minutes: 5));
    await conversation('c-1', ago: const Duration(minutes: 5), count: 2);
    final moved = (await eligible(meeting())).inputsHash;
    expect(moved, isNot(first));

    final rekeyed = (await eligible(meeting(changeKey: 'ck-2'))).inputsHash;
    expect(rekeyed, isNot(moved), reason: 'the event changing moves it too');
  });

  test('last met: the latest meeting with them that ended', () async {
    await thread('c-1');
    final past = now.subtract(const Duration(days: 3));
    await calendar.upsertEvents([
      CalendarEvent(
        id: 'evt-past',
        subject: 'Earlier',
        startUtc: past,
        endUtc: past.add(const Duration(minutes: 30)),
        responseStatus: 'accepted',
        attendees: const [Attendee(name: 'Dana Lee', address: dana)],
      ),
    ], syncRun: 'run-1');
    final input = await eligible(meeting());
    expect(input.lastMet, startsWith('Last met'));
  });
}
