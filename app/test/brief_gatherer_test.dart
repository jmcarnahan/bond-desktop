import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/meeting_brief_task.dart';
import 'package:bond_inbox/services/llm/prompt_guard.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/fake_embed_server.dart';
import 'fixtures/test_db.dart';

/// The brief's inputs, gathered over a real in-memory store: who counts as
/// someone else, which meetings are eligible (D6), how threads rank, what an
/// open ask is, the caps, the fencing, and the inputs hash. Fixture times are
/// derived from the clock, so the 30-day window never rots; the today-and-
/// tomorrow edge is pinned to a fixed instant in a named zone.
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
    String seriesMasterId = '',
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
      seriesMasterId: seriesMasterId,
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
    String? eventId,
    bool hasAttachments = false,
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
        if (hasAttachments) 'has_attachments': 1,
        if (eventId != null)
          'source_meta_json':
              jsonEncode({'meeting': 'meetingRequest', 'event_id': eventId}),
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

  Future<BriefInput> eligible(CalendarEvent e, {bool asked = false}) async {
    final g = await gatherer.gather(e, now: now, asked: asked);
    expect(g, isA<BriefEligible>());
    return (g as BriefEligible).input;
  }

  Future<BriefIneligibility> ineligible(CalendarEvent e,
      {bool asked = false}) async {
    final g = await gatherer.gather(e, now: now, asked: asked);
    expect(g, isA<BriefIneligible>());
    return (g as BriefIneligible).why;
  }

  /// Pins [now] to Tue 6 Oct 2026 09:00 in Los Angeles — never the wall
  /// clock, so the end-of-tomorrow edge cannot flake at 23:59 — and gives
  /// Dana mail two hours before it.
  Future<void> atFixedNow() async {
    now = la.localDateTime(const CalendarDate(2026, 10, 6), 9, 0).toUtc();
    await thread('c-1');
  }

  /// [startsIn] for a meeting at [hour]:[minute] local on [date].
  Duration untilLocal(CalendarDate date, int hour, int minute) =>
      la.localDateTime(date, hour, minute).toUtc().difference(now);

  group('eligibility', () {
    setUp(() async => thread('c-1'));

    test('a meeting soon, with Dana, with mail: eligible', () async {
      await eligible(meeting());
    });

    test('started, too far off, cancelled, declined', () async {
      await atFixedNow();
      expect(await ineligible(meeting(startsIn: const Duration(hours: -1))),
          BriefIneligibility.past);
      // The day after tomorrow, 09:00 local.
      expect(
          await ineligible(meeting(
              startsIn: untilLocal(const CalendarDate(2026, 10, 8), 9, 0))),
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

    test('the end-of-tomorrow edge: 23:59 tomorrow is in, 00:00 the day '
        'after is out', () async {
      await atFixedNow();
      await eligible(meeting(
          startsIn: untilLocal(const CalendarDate(2026, 10, 7), 23, 59)));
      expect(
        await ineligible(meeting(
            startsIn: untilLocal(const CalendarDate(2026, 10, 8), 0, 0))),
        BriefIneligibility.tooFar,
      );
      expect(briefHorizonEnd(now, la),
          la.localDateTime(const CalendarDate(2026, 10, 8), 0, 0).toUtc());
    });

    test('ahead of UTC, tomorrow is the local one, not UTC\'s', () {
      // Wed 7 Oct 2026 08:00 in Auckland is still Tue 6 Oct in UTC; local
      // tomorrow is Thu 8 Oct, so the box ends at Fri 9 Oct 00:00 NZDT —
      // where UTC's own tomorrow would have ended it a day sooner.
      final nz = CalendarZone.tryNamed('Pacific/Auckland')!;
      final at = nz.localDateTime(const CalendarDate(2026, 10, 7), 8, 0).toUtc();
      expect(at.day, 6, reason: 'the fixture: UTC is still the day before');
      final end = nz.localDateTime(const CalendarDate(2026, 10, 9), 0, 0).toUtc();
      expect(briefHorizonEnd(at, nz), end);
      CalendarEvent at8(CalendarDate d) => CalendarEvent(
            id: 'evt-nz',
            subject: 'Fabrikam sync',
            startUtc: nz.localDateTime(d, 8, 0).toUtc(),
            endUtc: nz.localDateTime(d, 8, 30).toUtc(),
            responseStatus: 'accepted',
            attendees: const [Attendee(name: 'Dana Lee', address: dana)],
          );
      expect(
          briefQuickCheck(at8(const CalendarDate(2026, 10, 8)),
              owner: owner, now: at, zone: nz),
          isNull,
          reason: 'Thursday 08:00 is local tomorrow');
      expect(
          briefQuickCheck(at8(const CalendarDate(2026, 10, 9)),
              owner: owner, now: at, zone: nz),
          BriefIneligibility.tooFar);
    });

    test('the quick check: asked lifts the horizon, nothing else', () async {
      await atFixedNow();
      final nextWeek = meeting(
          startsIn: untilLocal(const CalendarDate(2026, 10, 13), 9, 0));
      expect(briefQuickCheck(nextWeek, owner: owner, now: now, zone: la),
          BriefIneligibility.tooFar);
      expect(
          briefQuickCheck(nextWeek,
              owner: owner, now: now, zone: la, asked: true),
          isNull);
      BriefIneligibility? asked(CalendarEvent e) =>
          briefQuickCheck(e, owner: owner, now: now, zone: la, asked: true);
      expect(asked(meeting(startsIn: const Duration(hours: -1))),
          BriefIneligibility.past);
      expect(asked(meeting(isCancelled: true)), BriefIneligibility.cancelled);
      expect(asked(meeting(responseStatus: 'declined')),
          BriefIneligibility.declined);
      expect(asked(meeting(attendees: const [], isOrganizer: true)),
          BriefIneligibility.noOthers);
      expect(
          asked(meeting(attendees: [
            for (var i = 0; i <= briefMaxOthers; i++)
              Attendee(name: 'Guest $i', address: 'guest$i@fabrikam.com'),
          ])),
          BriefIneligibility.tooMany);
    });

    test('asked: too far off and no mail are gathered anyway; started, '
        'cancelled, declined and nobody else are not', () async {
      await atFixedNow();
      // Next week, with Dana's mail: a person asked, so the horizon is off.
      final far = await eligible(
          meeting(
              startsIn: untilLocal(const CalendarDate(2026, 10, 13), 9, 0)),
          asked: true);
      expect(far.threads, hasLength(1));
      // Soon, with Sam, who has written nothing: briefed from the invite
      // and its people alone.
      final quiet = await eligible(
          meeting(
            attendees: const [Attendee(name: 'Sam', address: sam)],
            bodyPreview: 'Agenda: the renewal.',
          ),
          asked: true);
      expect(quiet.threads, isEmpty);
      expect(quiet.openAsks, isEmpty);
      expect(quiet.materials, isEmpty);
      expect(quiet.attendees, ['Sam']);
      expect(quiet.people.map((p) => p.address), [sam]);
      expect(quiet.inputsHash, isNotEmpty);
      // The light gather takes it too.
      final light = await gatherer.gather(
          meeting(attendees: const [Attendee(name: 'Sam', address: sam)]),
          now: now,
          passages: false,
          asked: true);
      expect(light, isA<BriefEligible>());

      expect(
          await ineligible(meeting(startsIn: const Duration(hours: -1)),
              asked: true),
          BriefIneligibility.past);
      expect(await ineligible(meeting(isCancelled: true), asked: true),
          BriefIneligibility.cancelled);
      expect(await ineligible(meeting(responseStatus: 'declined'), asked: true),
          BriefIneligibility.declined);
      expect(
          await ineligible(meeting(attendees: const [], isOrganizer: true),
              asked: true),
          BriefIneligibility.noOthers);
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
    test('seven threads → six; five asks → four; ten materials → six', () async {
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
      expect(input.materials, hasLength(BriefGatherer.maxMaterials));
      expect([for (final m in input.materials) m.name],
          isNot(contains('logo.png')));
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

  group("the meeting's own mail", () {
    const assistant = 'assistant@fabrikam.com';

    test("the invite's own mail is a thread, first, even without an address "
        'match', () async {
      // Sent by an assistant who is not in the meeting: no attendee's
      // address matches it, and Sam has no other mail.
      await conversation('c-invite', people: const [assistant],
          ago: const Duration(days: 3));
      await message('m-invite', 'c-invite',
          from: assistant,
          fromName: 'Assistant',
          ago: const Duration(days: 3),
          eventId: 'evt-1');
      final withSam = meeting(attendees: const [
        Attendee(name: 'Sam Ortiz', address: sam),
      ]);
      final alone = await eligible(withSam);
      expect([for (final t in alone.threads) t.conversationKey], ['c-invite'],
          reason: 'an invite thread alone makes the meeting eligible');

      // A newer, urgent thread with Sam still comes after the invite.
      await conversation('c-sam', people: const [sam], ago: const Duration(hours: 1));
      await message('m-sam', 'c-sam', from: sam, ago: const Duration(hours: 1));
      await decide('m-sam', urgency: 'high');
      final both = await eligible(withSam);
      expect([for (final t in both.threads) t.conversationKey],
          ['c-invite', 'c-sam']);
    });

    test("an occurrence reads its series' invite too, after its own, and a "
        'thread found both ways is listed once', () async {
      await conversation('c-own', people: const [assistant]);
      await message('m-own', 'c-own', from: assistant, eventId: 'evt-1');
      await conversation('c-series', people: const [assistant],
          ago: const Duration(days: 20));
      await message('m-series', 'c-series',
          from: assistant, ago: const Duration(days: 20), eventId: 'master-1');
      // Dana's thread carries the invite too: found by address AND by event.
      await thread('c-dana', ago: const Duration(minutes: 30));
      await message('m-dana-invite', 'c-dana',
          ago: const Duration(hours: 4), eventId: 'evt-1');

      final input = await eligible(meeting(seriesMasterId: 'master-1'));
      final keys = [for (final t in input.threads) t.conversationKey];
      // The occurrence's own invites newest first, then the series'; Dana's
      // thread is an invite thread now, and not listed again by address.
      expect(keys, ['c-own', 'c-dana', 'c-series']);
    });

    test('invite threads take at most three of the six, so a long series '
        'leaves room for the mail with the people', () async {
      for (var i = 0; i < 5; i++) {
        await conversation('c-inv-$i', people: const [assistant],
            ago: Duration(days: i + 1));
        await message('m-inv-$i', 'c-inv-$i',
            from: assistant, ago: Duration(days: i + 1), eventId: 'evt-1');
      }
      await thread('c-dana', ago: const Duration(days: 9));

      final input = await eligible(meeting());
      expect([for (final t in input.threads) t.conversationKey],
          ['c-inv-0', 'c-inv-1', 'c-inv-2', 'c-dana']);
      expect(BriefGatherer.maxInviteThreads, 3);
    });

    test('no invite thread and no address match is still no mail', () async {
      expect(
        await ineligible(meeting(attendees: const [
          Attendee(name: 'Sam', address: sam),
        ])),
        BriefIneligibility.noMail,
      );
    });
  });

  group('materials', () {
    Future<void> attach(
      String messageId,
      String attachmentId, {
      String name = 'deck.pptx',
      String kind = 'file',
      String? contentType =
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      bool inline = false,
      int ordinal = 0,
    }) =>
        store.upsertAttachments('email', messageId, [
          {
            'attachment_id': attachmentId,
            'ordinal': ordinal,
            'kind': kind,
            'name': name,
            'content_type': contentType,
            'is_inline': inline ? 1 : 0,
          },
        ]);

    Future<void> read(String messageId, String attachmentId) =>
        store.setAttachmentText('email', messageId, attachmentId,
            status: 'done', text: 'The words of the deck.');

    Future<void> digest(String messageId, String attachmentId, String summary) =>
        store.setAttachmentDigest('email', messageId, attachmentId,
            status: 'done',
            digestJson: jsonEncode(AttachmentDigest(
              kind: 'slides',
              summary: summary,
              facts: const ['Two tiers.'],
            ).toJson()));

    String dayOf(Duration ago) => la.dateOf(now.subtract(ago)).toIso();

    test('materials carry the ref, the sender, the day, the digest and the '
        'read state, newest first', () async {
      await conversation('c-1', count: 3, ago: const Duration(hours: 1));
      await message('m-old', 'c-1', ago: const Duration(hours: 30));
      await message('m-mine', 'c-1', outbound: true, ago: const Duration(hours: 5));
      await message('m-new', 'c-1', ago: const Duration(hours: 1));
      await attach('m-old', 'a-old', name: 'terms.pdf',
          contentType: 'application/pdf');
      await attach('m-mine', 'a-mine', name: 'my reply.pdf');
      await attach('m-new', 'a-deck', name: 'Q3 plan.pptx');
      await read('m-new', 'a-deck');
      await digest('m-new', 'a-deck', 'The Q3 plan proposes two tiers.');

      final input = await eligible(meeting());
      expect([for (final m in input.materials) m.name],
          ['Q3 plan.pptx', 'my reply.pdf', 'terms.pdf'],
          reason: "newest mail first, the owner's own file among them");
      expect(input.materials[1].sender, 'you');
      final deck = input.materials.first;
      expect((deck.source, deck.messageId, deck.attachmentId),
          ('email', 'm-new', 'a-deck'));
      expect(deck.sender, 'Dana Lee', reason: "the invite's name for her");
      expect(deck.date, dayOf(const Duration(hours: 1)));
      expect(deck.contentType, contains('presentation'));
      expect(deck.textStatus, 'done');
      expect(deck.digest?.summary, 'The Q3 plan proposes two tiers.');
      expect(deck.passages, isEmpty, reason: 'no embeddings client, no passages');
      final terms = input.materials.last;
      expect(terms.date, dayOf(const Duration(hours: 30)));
      expect(terms.textStatus, 'pending');
      expect(terms.digest, isNull);
    });

    test("the owner's own attachment on the invite they sent is a material, "
        'sender you', () async {
      // The owner organised it: the invite in this mailbox is their Sent
      // Items copy, outbound, with the agenda on it.
      await conversation('c-invite', ago: const Duration(hours: 3));
      await message('m-invite', 'c-invite',
          outbound: true,
          ago: const Duration(hours: 3),
          eventId: 'evt-1',
          hasAttachments: true);
      await attach('m-invite', 'a-agenda', name: 'Agenda.pdf',
          contentType: 'application/pdf');

      final g = await gatherer.gather(meeting(), now: now);
      expect(g, isA<BriefEligible>());
      final eligible = g as BriefEligible;
      final agenda = eligible.input.materials.single;
      expect((agenda.messageId, agenda.attachmentId, agenda.name),
          ('m-invite', 'a-agenda', 'Agenda.pdf'));
      expect(agenda.sender, 'you');
      expect(eligible.unlisted, isEmpty, reason: 'its file is listed');
      expect(
          const MeetingBriefTask().buildUserMessage(eligible.input),
          contains('[1] (unread) ${wrapUntrusted('material', 'Agenda.pdf · '
              'you · ${dayOf(const Duration(hours: 3))}')}'));
    });

    test('a mail with attachments not yet listed is reported as unlisted',
        () async {
      await conversation('c-invite', count: 2, ago: const Duration(hours: 1));
      await message('m-invite', 'c-invite',
          outbound: true,
          ago: const Duration(hours: 3),
          eventId: 'evt-1',
          hasAttachments: true);
      await message('m-reply', 'c-invite',
          ago: const Duration(hours: 1), hasAttachments: true);
      await message('m-plain', 'c-invite', ago: const Duration(hours: 2));

      final g = await gatherer.gather(meeting(), now: now, passages: false);
      expect(g, isA<BriefEligible>());
      final eligible = g as BriefEligible;
      expect(eligible.input.materials, isEmpty);
      expect([for (final u in eligible.unlisted) (u.source, u.messageId)],
          [('email', 'm-reply'), ('email', 'm-invite')],
          reason: 'newest first, both directions, never a mail with no files');

      // Listed, it is a material and no longer unlisted.
      await attach('m-reply', 'a-1', name: 'notes.docx');
      final again = await gatherer.gather(meeting(), now: now) as BriefEligible;
      expect([for (final u in again.unlisted) u.messageId], ['m-invite']);
      expect(again.input.materials.single.name, 'notes.docx');
    });

    test('an unread deck is listed as arrived, with no digest', () async {
      await thread('c-1');
      await attach('m-c-1', 'a-deck', name: 'Board deck.pptx');

      final input = await eligible(meeting());
      final deck = input.materials.single;
      expect(deck.name, 'Board deck.pptx');
      expect(deck.textStatus, 'pending');
      expect(deck.digest, isNull);
      expect(deck.passages, isEmpty);
      expect(
          const MeetingBriefTask().buildUserMessage(input),
          contains('[1] (unread) ${wrapUntrusted('material', 'Board deck.pptx · '
              'Dana Lee · ${dayOf(const Duration(hours: 2))}')}'));
    });

    test('images and inline files are not materials', () async {
      await thread('c-1');
      await attach('m-c-1', 'a-inline', name: 'inline.pdf', inline: true,
          ordinal: 0);
      await attach('m-c-1', 'a-photo', name: 'photo.jpg',
          contentType: 'image/jpeg', ordinal: 1);
      await attach('m-c-1', 'a-image', name: 'pasted.png', kind: 'image',
          contentType: null, ordinal: 2);
      await attach('m-c-1', 'a-card', name: 'card', kind: 'card', ordinal: 3);
      await attach('m-c-1', 'a-quote', name: 'quoted',
          kind: 'message_reference', ordinal: 4);
      await attach('m-c-1', 'a-noname', name: '  ', ordinal: 5);
      await attach('m-c-1', 'a-link', name: 'Shared plan', kind: 'reference',
          contentType: null, ordinal: 6);
      await attach('m-c-1', 'a-deck', name: 'deck.pptx', ordinal: 7);

      final input = await eligible(meeting());
      expect({for (final m in input.materials) m.attachmentId},
          {'a-link', 'a-deck'});
    });

    test('the same deck re-attached on every reply is one material, the '
        'newest copy', () async {
      await conversation('c-1', count: 3, ago: const Duration(hours: 1));
      await message('m-1', 'c-1', ago: const Duration(hours: 9));
      await message('m-2', 'c-1', ago: const Duration(hours: 5));
      await message('m-3', 'c-1', ago: const Duration(hours: 1));
      await attach('m-1', 'a-1', name: 'Q3 Plan.pptx');
      await attach('m-2', 'a-2', name: 'q3 plan.pptx');
      await attach('m-3', 'a-3', name: 'Q3 plan.pptx');
      await attach('m-2', 'a-other', name: 'terms.pdf', ordinal: 1);

      final input = await eligible(meeting());
      expect([for (final m in input.materials) (m.messageId, m.name)],
          [('m-3', 'Q3 plan.pptx'), ('m-2', 'terms.pdf')]);
    });

    test('a digest landing moves the hash; a renamed file does not', () async {
      await thread('c-1');
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      final first = (await eligible(meeting())).inputsHash;

      await attach('m-c-1', 'a-deck', name: 'deck (final).pptx');
      final renamed = await eligible(meeting());
      expect(renamed.materials.single.name, 'deck (final).pptx');
      expect(renamed.inputsHash, first);

      await read('m-c-1', 'a-deck');
      final textLanded = (await eligible(meeting())).inputsHash;
      expect(textLanded, isNot(first));

      await digest('m-c-1', 'a-deck', 'What the deck says.');
      final digested = (await eligible(meeting())).inputsHash;
      expect(digested, isNot(textLanded));
    });

    test("a read file carries its text, cut at a word to the cap; the "
        "planner's gather reads none, and the hash is the same", () async {
      await thread('c-1');
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      final words = List.filled(2000, 'word').join(' ');
      await store.setAttachmentText('email', 'm-c-1', 'a-deck',
          status: 'done', text: 'Tier B   is 12k.\n\n\n\n$words');

      final input = await eligible(meeting());
      final text = input.materials.single.text;
      expect(text, startsWith('Tier B is 12k.\n\nword'),
          reason: 'runs of spaces and blank lines closed up');
      expect(text.length, lessThanOrEqualTo(BriefGatherer.materialTextCap));
      expect(text.length, greaterThan(BriefGatherer.materialTextCap - 5));
      expect(text, endsWith('word'), reason: 'cut at a word');
      expect(input.materials.single.textCut, isTrue);
      expect(BriefGatherer.materialTextCap, 6000);

      // A short file is whole, and says so.
      await store.setAttachmentText('email', 'm-c-1', 'a-deck',
          status: 'done', text: 'Tier B is 12k.');
      expect((await eligible(meeting())).materials.single.textCut, isFalse);

      final light =
          await gatherer.gather(meeting(), now: now, passages: false)
              as BriefEligible;
      expect(light.input.materials.single.text, '');
      expect(light.input.people, isEmpty);
      expect(light.input.inputsHash, input.inputsHash);
    });

    Future<void> queueText(String messageId, String attachmentId) =>
        store.enqueueWork('attachment_text', 'email',
            attachmentEntityId(messageId, attachmentId));

    test('a file still being read is pending; a skipped or read one is not',
        () async {
      // An hour old: inside the wait's age cap.
      await thread('c-1', ago: const Duration(hours: 1));
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      await queueText('m-c-1', 'a-deck');
      final pending = await eligible(meeting());
      expect(pending.materialsPending, isTrue);
      expect(pending.materials.single.text, '');
      final light =
          await gatherer.gather(meeting(), now: now, passages: false)
              as BriefEligible;
      expect(light.input.materialsPending, isTrue,
          reason: 'the planner reads the same stored state');

      await store.setAttachmentText('email', 'm-c-1', 'a-deck',
          status: 'skipped', reason: 'too_large');
      expect((await eligible(meeting())).materialsPending, isFalse);

      await read('m-c-1', 'a-deck');
      expect((await eligible(meeting())).materialsPending, isFalse);
    });

    test('a file whose text work gave up is not pending', () async {
      // An hour old: inside the wait's age cap.
      await thread('c-1', ago: const Duration(hours: 1));
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      await queueText('m-c-1', 'a-deck');
      // The worker's give-up: the WORK row says error, and nothing touches
      // the attachment row, which still says pending.
      await db.customStatement(
          "UPDATE work_items SET status = 'error' "
          "WHERE task_kind = 'attachment_text'");
      final input = await eligible(meeting());
      expect(input.materials.single.textStatus, 'pending');
      expect(input.materialsPending, isFalse);
      final g = await gatherer.gather(meeting(), now: now) as BriefEligible;
      expect(g.unqueued, isEmpty, reason: 'it was queued; it gave up');
    });

    test('a file read for more than two hours is not waited for', () async {
      await conversation('c-1', ago: const Duration(hours: 3));
      await message('m-c-1', 'c-1', ago: const Duration(hours: 3));
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      await queueText('m-c-1', 'a-deck');
      // Mail three hours old whose text work was only just asked for: the
      // reading is young, so it is waited for.
      expect((await eligible(meeting())).materialsPending, isTrue);
      // Its text work asked for three hours ago as well: not any more.
      await db.customStatement(
          "UPDATE work_items SET created_at = ? "
          "WHERE task_kind = 'attachment_text'",
          [stampAgo(const Duration(hours: 3))]);
      expect((await eligible(meeting())).materialsPending, isFalse);
      expect(BriefGatherer.pendingMaxAge, const Duration(hours: 2));

      // The same file on mail an hour old is waited for.
      await conversation('c-2', ago: const Duration(hours: 1));
      await message('m-c-2', 'c-2', ago: const Duration(hours: 1));
      await attach('m-c-2', 'a-memo', name: 'memo.pdf');
      await queueText('m-c-2', 'a-memo');
      expect((await eligible(meeting())).materialsPending, isTrue);
    });

    test('a listed file with no text work is reported unqueued, not pending',
        () async {
      // An hour old: inside the wait's age cap.
      await thread('c-1', ago: const Duration(hours: 1));
      await attach('m-c-1', 'a-deck', name: 'deck.pptx');
      for (final passages in [true, false]) {
        final g = await gatherer.gather(meeting(), now: now,
            passages: passages) as BriefEligible;
        expect(g.input.materialsPending, isFalse);
        expect([for (final u in g.unqueued) u.material.attachmentId],
            ['a-deck']);
        expect(g.unqueued.single.young, isTrue);
      }

      expect(await gatherer.queueText([
        for (final u
            in ((await gatherer.gather(meeting(), now: now)) as BriefEligible)
                .unqueued)
          u.material,
      ]), 1);
      final after = await gatherer.gather(meeting(), now: now) as BriefEligible;
      expect(after.unqueued, isEmpty);
      expect(after.input.materialsPending, isTrue);
    });

    BriefGatherer withChunks(_ChunkStore chunks, FakeEmbedServer server) =>
        BriefGatherer(
          chunks,
          calendar,
          ownerAddress: () async => owner,
          zone: () => la,
          embeddings: server.client,
        );

    AttachmentChunkHit hit(String messageId, String attachmentId, int seq,
            String locator, String text) =>
        AttachmentChunkHit(
          ref: AttachmentRef(
              source: 'email', messageId: messageId, attachmentId: attachmentId),
          chunkId: seq,
          seq: seq,
          locator: locator,
          text: text,
          outbound: false,
        );

    test('passages come from the chunks nearest the meeting, two per file at '
        'most', () async {
      final chunks = _ChunkStore(db);
      await thread('c-1');
      await attach('m-c-1', 'a-deck', name: 'deck.pptx', ordinal: 0);
      await attach('m-c-1', 'a-sheet', name: 'numbers.xlsx',
          contentType: 'application/vnd.ms-excel', ordinal: 1);
      chunks.hits = [
        hit('m-c-1', 'a-deck', 0, 'digest', 'A model summary.'),
        hit('m-c-1', 'a-deck', 3, 'slide 3', 'Pricing: two tiers.'),
        hit('other-message', 'a-deck', 9, 'slide 1', 'Same id, other mail.'),
        hit('m-c-1', 'a-sheet', 1, 'Sheet Q3 rows 1-40', 'x' * 600),
        hit('m-c-1', 'a-deck', 5, 'slide 5', 'Timeline: November.'),
        hit('m-c-1', 'a-deck', 7, 'slide 7', 'A third deck passage.'),
      ];
      final server = FakeEmbedServer();

      final input = await withChunks(chunks, server)
          .gather(meeting(bodyPreview: 'Agenda: pricing.'), now: now);
      final materials = (input as BriefEligible).input.materials;
      final deck = materials.firstWhere((m) => m.attachmentId == 'a-deck');
      final sheet = materials.firstWhere((m) => m.attachmentId == 'a-sheet');
      expect(deck.passages, [
        wrapUntrusted('passage', '[slide 3] Pricing: two tiers.'),
        wrapUntrusted('passage', '[slide 5] Timeline: November.'),
      ], reason: 'the digest chunk out, another mail out, two at most');
      expect(sheet.passages.single,
          startsWith('<untrusted_data source="passage">'));
      expect(sheet.passages.single, contains('[Sheet Q3 rows 1-40] x'));
      expect(sheet.passages.single, contains('x' * (BriefGatherer.passageCap - 30)));
      expect(sheet.passages.single, isNot(contains('x' * BriefGatherer.passageCap)));

      expect(server.inputs, ['Fabrikam sync\nAgenda: pricing.'],
          reason: 'the meeting, embedded once, under the document prefix');
      // One scoped search per file, never one shared shortlist.
      expect([for (final c in chunks.knnCalls) c.attachmentIds],
          unorderedEquals([
            ['a-deck'],
            ['a-sheet'],
          ]));
      for (final c in chunks.knnCalls) {
        expect(c.messageIds, isEmpty);
        expect(c.embedModel, EmbeddingsClient.documentModelTag);
        expect(c.limit, BriefGatherer.passageLimit);
      }

      // Passages are not hashed: the same materials without them hash alike,
      // and a gather asked for no passages makes no embedding call.
      final quiet = await withChunks(chunks, server).gather(
          meeting(bodyPreview: 'Agenda: pricing.'),
          now: now,
          passages: false);
      expect((quiet as BriefEligible).input.inputsHash, input.input.inputsHash);
      expect(quiet.input.materials.every((m) => m.passages.isEmpty), isTrue);
      expect(server.calls, 1, reason: 'still only the first gather embedded');
    });

    test('a long deck cannot starve the other files of passages', () async {
      final chunks = _ChunkStore(db);
      await thread('c-1');
      await attach('m-c-1', 'a-deck', name: 'deck.pptx', ordinal: 0);
      await attach('m-c-1', 'a-memo', name: 'memo.docx', ordinal: 1);
      chunks.hits = [
        // Forty slides nearer the meeting than anything in the memo.
        for (var i = 0; i < 40; i++)
          hit('m-c-1', 'a-deck', i, 'slide $i', 'Slide $i.'),
        hit('m-c-1', 'a-memo', 100, 'part 1', 'The memo.'),
      ];
      final server = FakeEmbedServer();
      final input =
          await withChunks(chunks, server).gather(meeting(), now: now);
      final materials = (input as BriefEligible).input.materials;
      expect(
          materials.firstWhere((m) => m.attachmentId == 'a-memo').passages,
          [wrapUntrusted('passage', '[part 1] The memo.')]);
      expect(
          materials.firstWhere((m) => m.attachmentId == 'a-deck').passages,
          hasLength(BriefGatherer.passagesPerMaterial));
      expect(server.calls, 1, reason: 'the meeting is still embedded once');
    });

    test('no chunks, no embedding call', () async {
      final chunks = _ChunkStore(db)..hasChunks = false;
      await thread('c-1');
      await attach('m-c-1', 'a-deck');
      final server = FakeEmbedServer();
      final input = await withChunks(chunks, server).gather(meeting(), now: now);
      expect((input as BriefEligible).input.materials.single.passages, isEmpty);
      expect(server.calls, 0);
      expect(chunks.knnCalls, isEmpty);
    });

    test('a passage failure costs no brief', () async {
      await thread('c-1');
      await attach('m-c-1', 'a-deck');

      final throwing = _ChunkStore(db)..throwOnKnn = true;
      final thrown =
          await withChunks(throwing, FakeEmbedServer()).gather(meeting(), now: now);
      expect((thrown as BriefEligible).input.materials.single.passages, isEmpty);

      final down = _ChunkStore(db)
        ..hits = [hit('m-c-1', 'a-deck', 1, 'slide 1', 'Words.')];
      final offline = await withChunks(down, FakeEmbedServer(status: null))
          .gather(meeting(), now: now);
      expect((offline as BriefEligible).input.materials.single.passages,
          isEmpty);
      expect(down.knnCalls, isEmpty, reason: 'no vector, no search');

      final noIndex = _ChunkStore(db)..indexMissing = true;
      final missing = await withChunks(noIndex, FakeEmbedServer())
          .gather(meeting(), now: now);
      expect((missing as BriefEligible).input.materials.single.passages,
          isEmpty);
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

  test('a rewritten storyline recap moves the inputs hash', () async {
    await thread('c-1');
    await store.insertStoryline(
      id: 's-1',
      title: 'Renewal',
      summary: 'Where it stands.',
      status: 'active',
      createdBy: 'user',
    );
    await store.addStorylineMember('s-1', 'email', 'c-1', addedBy: 'user');
    await store.updateStoryline('s-1', recapText: 'The quote is out.');
    final first = (await eligible(meeting())).inputsHash;

    await store.updateStoryline('s-1', recapText: 'The quote was signed.');
    final rewritten = await eligible(meeting());
    expect(rewritten.storylines.single.summary, contains('signed'));
    expect(rewritten.inputsHash, isNot(first));
  });

  test('a room is left out whatever the case of its type', () async {
    expect(
      briefOthers(
        meeting(
          attendees: const [
            Attendee(
                name: 'Room 4', address: 'room4@contoso.com', type: 'Resource'),
            Attendee(name: 'Dana', address: dana),
          ],
          isOrganizer: true,
        ),
        owner: owner,
      ).map((p) => p.address),
      [dana],
    );
  });

  test('with the owner unknown, gather throws for a retry rather than '
      'counting the owner as someone else', () async {
    await thread('c-1');
    final unknown = BriefGatherer(
      store,
      calendar,
      ownerAddress: () async => null,
      zone: () => la,
    );
    await expectLater(unknown.gather(meeting(), now: now),
        throwsA(isA<BriefOwnerUnknown>()));
  });

  test('capRunes never ends on half of a surrogate pair', () {
    const s = 'ab\u{1F600}cd'; // the emoji is two code units, at 2 and 3
    expect(capRunes(s, 3), 'ab');
    expect(capRunes(s, 4), 'ab\u{1F600}');
    expect(capRunes(s, 2), 'ab');
    expect(capRunes(s, 99), s);
    expect(capRunes(s, 0), '');
  });

  group('people', () {
    test('the people block: org, organiser, last met, threads, last words, '
        'open ask', () async {
      await conversation('c-1', state: 'needs_reply', count: 2);
      await message('m-old', 'c-1',
          body: 'Earlier note.', ago: const Duration(hours: 5));
      await message('m-new', 'c-1',
          body: 'Can you confirm the 12k tier before Thursday?\n\n'
              'On Mon, Sep 28, 2026 at 3:15 PM Me <me@contoso.com> wrote:\n'
              '> the quoted history',
          ago: const Duration(hours: 2));
      await decide('m-new', needsYou: 0.9, intent: 'request');
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

      final input = await eligible(meeting(
        organizerAddress: dana,
        attendees: const [
          Attendee(name: 'Me', address: owner),
          Attendee(name: 'Dana Lee', address: dana, response: 'accepted'),
          Attendee(name: 'Kim', address: 'kim@gmail.example'),
        ],
      ));
      expect([for (final p in input.people) p.name], ['Dana Lee', 'Kim'],
          reason: "the attendees' order, the owner left out");
      final d = input.people.first;
      expect(d.org, 'fabrikam');
      expect(d.isOrganizer, isTrue);
      expect(d.response, 'response not known',
          reason: "an attendee's copy does not track answers");
      expect(d.lastMet, startsWith('Last met'));
      expect(d.threadCount, 1);
      expect(d.lastInboundAgo, '2 hours ago');
      expect(d.lastSubject, 'Thread c-1');
      expect(d.lastWords,
          wrapUntrusted('last_words',
              'Can you confirm the 12k tier before Thursday?'),
          reason: 'her newest message, the quoted history cut off');
      expect(d.openAsk, input.openAsks.single.ask);
      final k = input.people.last;
      expect(k.org, '', reason: 'a consumer mailbox names no organisation');
      expect(k.isOrganizer, isFalse);
      expect(k.threadCount, 0);
      expect(k.lastInboundAgo, '');
      expect(k.lastWords, '');
      expect(k.openAsk, '');
      expect(k.lastMet, isNull);
      expect(input.peopleMore, 0);
    });

    test("the owner's organiser copy reads each answer", () async {
      await thread('c-1');
      final input = await eligible(meeting(
        isOrganizer: true,
        organizerAddress: owner,
        attendees: const [
          Attendee(name: 'Dana Lee', address: dana, response: 'accepted'),
          Attendee(name: 'Sam', address: sam, response: 'tentativelyAccepted'),
          Attendee(name: 'Kim', address: 'kim@northwind.com', response: 'none'),
        ],
      ));
      expect([for (final p in input.people) p.response],
          ['accepted', 'tentative', 'no answer yet']);
      expect(input.people.every((p) => !p.isOrganizer), isTrue);
    });

    test('eight people at most, the rest counted', () async {
      await thread('c-1');
      final input = await eligible(meeting(attendees: [
        const Attendee(name: 'Dana Lee', address: dana),
        for (var i = 0; i < 10; i++)
          Attendee(name: 'P$i', address: 'p$i@northwind.com'),
      ]));
      expect(input.people, hasLength(BriefGatherer.maxPeople));
      expect(input.people.first.name, 'Dana Lee');
      expect(input.peopleMore, 3);
    });

    test('the organiser is never cut past eight', () async {
      await thread('c-1');
      // A Graph attendee copy: the organiser is not among the attendees,
      // so `briefOthers` lists them last.
      final input = await eligible(meeting(
        organizerAddress: 'olu@northwind.com',
        attendees: [
          const Attendee(name: 'Me', address: owner),
          const Attendee(name: 'Dana Lee', address: dana),
          for (var i = 0; i < 9; i++)
            Attendee(name: 'P$i', address: 'p$i@northwind.com'),
        ],
      ));
      expect(input.people, hasLength(BriefGatherer.maxPeople));
      expect(input.people.first.address, 'olu@northwind.com');
      expect(input.people.first.isOrganizer, isTrue);
      expect(input.people[1].name, 'Dana Lee',
          reason: 'then the invite\'s order');
      expect(input.peopleMore, 3);
    });

    test('the organisation of an address', () {
      expect(briefOrgOf('guest@contoso.onmicrosoft.com'), 'contoso');
      expect(briefOrgOf('a@10.0.0.1'), '');
      expect(briefOrgOf('dana@fabrikam.com'), 'fabrikam');
      expect(briefOrgOf('dana@mail.fabrikam.com'), 'fabrikam');
      expect(briefOrgOf('sam@contoso.co.uk'), 'contoso');
      expect(briefOrgOf('sam@eu.contoso.com.au'), 'contoso');
      // M365's routing domain names the tenant before its `mail`.
      expect(briefOrgOf('x@contoso.mail.onmicrosoft.com'), 'contoso');
      // Only the org label is read, so `.example` hosts reach the consumer
      // branch as the real ones do.
      for (final address in [
        'a@gmail.example',
        'a@googlemail.example',
        'a@outlook.example',
        'a@hotmail.example',
        'a@live.example',
        'a@yahoo.example',
        'a@icloud.example',
        'a@me.example',
        'a@proton.example',
        'a@protonmail.example',
        'a@aol.example',
      ]) {
        expect(briefOrgOf(address), '', reason: address);
      }
      const googleCalendar = 'group.calendar.google.com';
      expect(briefOrgOf('c_123@$googleCalendar'), '');
      expect(briefOrgOf('no-at-sign'), '');
      expect(briefOrgOf('a@localhost'), '');
    });
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

/// A store whose chunk reads are scripted, so the passage step is tested
/// without seeding the vec0 index: [hits] is what the scoped KNN answers,
/// and every call is recorded. `brief_planner_test.dart` has a smaller one.
class _ChunkStore extends MessageStore {
  _ChunkStore(super.db);

  bool hasChunks = true;
  bool throwOnKnn = false;
  bool indexMissing = false;
  List<AttachmentChunkHit> hits = const [];
  final List<
      ({
        String embedModel,
        List<String> messageIds,
        List<String> attachmentIds,
        int limit
      })> knnCalls = [];

  @override
  Future<bool> hasAttachmentChunks(
    String source, {
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
  }) async =>
      hasChunks;

  @override
  Future<List<AttachmentChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required String source,
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
    int limit = 6,
  }) async {
    knnCalls.add((
      embedModel: embedModel,
      messageIds: messageIds,
      attachmentIds: attachmentIds,
      limit: limit,
    ));
    if (throwOnKnn) throw StateError('the index broke');
    if (indexMissing) return null;
    // Scoped and limited the way the real read is: the nearest [limit]
    // within these attachment ids, in [hits] order.
    return [
      for (final h in hits)
        if (attachmentIds.contains(h.ref.attachmentId)) h,
    ].take(limit).toList();
  }
}
