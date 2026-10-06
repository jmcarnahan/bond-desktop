import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/home_models.dart' show RelatedConversation;
import 'package:bond_inbox/models/message_models.dart' show Message;
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/services/calendar/brief_gatherer.dart';
import 'package:bond_inbox/services/calendar/brief_path.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/meeting_brief_task.dart';
import 'package:bond_inbox/services/llm/prompt_guard.dart';
import 'package:bond_inbox/services/teams_sync.dart' show teamsBotGate;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/fake_embed_server.dart';
import 'fixtures/test_db.dart';
import 'fixtures/vec_test_db.dart';

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
    String subject = 'Fabrikam sync',
  }) {
    final start = now.add(startsIn);
    return CalendarEvent(
      id: id,
      subject: subject,
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

  /// A thread with Dana: a conversation row and one inbound message —
  /// with [eventId], that event's invite (its own mail, where materials
  /// come from).
  Future<void> thread(
    String key, {
    String state = 'waiting',
    Duration ago = const Duration(hours: 2),
    String body = 'Hello there.',
    String? eventId,
  }) async {
    await conversation(key, state: state, ago: ago);
    await message('m-$key', key, body: body, ago: ago, eventId: eventId);
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

  /// What [server] embedded as a DOCUMENT — the meeting, for the passages —
  /// leaving out the people search's query, which a topical meeting on the
  /// people path embeds too.
  List<String> documentEmbeds(FakeEmbedServer server) => [
        for (final i in server.inputs)
          if (!i.startsWith(EmbeddingsClient.searchQueryPrefix)) i,
      ];

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

    test('no meeting is refused for its size: 16, 40 and 300 other people '
        'are eligible, on the related path', () async {
      List<Attendee> people(int n) => [
            const Attendee(name: 'Dana Lee', address: dana),
            for (var i = 1; i < n; i++)
              Attendee(name: 'Guest $i', address: 'guest$i@fabrikam.com'),
          ];
      for (final n in [16, 40, 300]) {
        final e = meeting(attendees: people(n));
        expect(briefQuickCheck(e, owner: owner, now: now, zone: la), isNull,
            reason: '$n others');
        final input = await eligible(e);
        expect(input.path, BriefPath.related, reason: '$n others');
        expect(input.attendees, hasLength(n));
      }
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
        await thread('c-$i',
            state: 'needs_reply',
            ago: Duration(hours: i + 1),
            eventId: i == 0 ? 'evt-1' : null);
        await decide('m-c-$i', needsYou: 0.9, intent: 'request');
      }
      // Materials come from the invite thread only: all ten on it.
      for (var i = 0; i < 10; i++) {
        await store.upsertAttachments('email', 'm-c-0', [
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

    test('on the people path the invite thread is flagged and the address '
        'match is not', () async {
      await conversation('c-invite', people: const [assistant],
          ago: const Duration(days: 3));
      await message('m-invite', 'c-invite',
          from: assistant, ago: const Duration(days: 3), eventId: 'evt-1');
      await thread('c-dana', ago: const Duration(hours: 1));
      final input = await eligible(meeting());
      expect(input.path, BriefPath.people);
      expect([for (final t in input.threads) t.conversationKey],
          ['c-invite', 'c-dana']);
      expect([for (final t in input.threads) t.invite], [true, false]);
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
      await message('m-new', 'c-1', ago: const Duration(hours: 1), eventId: 'evt-1');
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

    test('a file on another thread with the same person is not a material '
        '— it is listed by name as another file', () async {
      // The meeting's own invite, sent by the owner, carries no file.
      await conversation('c-invite', ago: const Duration(hours: 3));
      await message('m-invite', 'c-invite',
          outbound: true, ago: const Duration(hours: 3), eventId: 'evt-1');
      // Other mail the owner sent Dana — another meeting's invite — with a
      // deck on it.
      await conversation('c-other', ago: const Duration(days: 2));
      await message('m-other', 'c-other',
          outbound: true, ago: const Duration(days: 2), eventId: 'evt-other');
      await attach('m-other', 'a-deck', name: 'northwind-deck.pdf',
          contentType: 'application/pdf');

      final input = await eligible(meeting());
      expect([for (final t in input.threads) t.conversationKey],
          ['c-invite', 'c-other'],
          reason: 'the other thread is still mail with these people');
      expect(input.materials, isEmpty);
      expect(input.otherFiles, ['northwind-deck.pdf']);
      final msg = const MeetingBriefTask().buildUserMessage(input);
      expect(msg, isNot(contains('Materials sent ahead')));
      expect(msg, contains('Files on the other threads (NOT '
          'sent for this meeting):\n- '
          '${wrapUntrusted('file', 'northwind-deck.pdf')}'));
    });

    test('other files move the hash, four at most, newest first, deduped',
        () async {
      await thread('c-invite', eventId: 'evt-1');
      await conversation('c-other', count: 6, ago: const Duration(hours: 1));
      for (var i = 0; i < 6; i++) {
        await message('m-o$i', 'c-other', ago: Duration(hours: 10 - i));
      }
      final first = await eligible(meeting());
      expect(first.otherFiles, isEmpty);

      await attach('m-o0', 'a-0', name: 'contoso-terms.pdf');
      final one = await eligible(meeting());
      expect(one.otherFiles, ['contoso-terms.pdf']);
      expect(one.materials, isEmpty);
      expect(one.inputsHash, isNot(first.inputsHash),
          reason: 'a new file with these people changes the inputs');
      final light = await gatherer.gather(meeting(), now: now, passages: false)
          as BriefEligible;
      expect(light.input.otherFiles, one.otherFiles);
      expect(light.input.inputsHash, one.inputsHash);

      // A newer copy of the same name under another case is one file.
      await attach('m-o1', 'a-1', name: 'Contoso-Terms.PDF');
      await attach('m-o2', 'a-2', name: 'photo.jpg', contentType: 'image/jpeg');
      await attach('m-o3', 'a-3', name: 'notes-3.docx');
      await attach('m-o4', 'a-4', name: 'notes-4.docx');
      await attach('m-o5', 'a-5', name: 'notes-5.docx');
      await attach('m-o5', 'a-6', name: 'notes-6.docx', ordinal: 1);
      final many = await eligible(meeting());
      expect(BriefGatherer.maxOtherFiles, 4);
      expect(many.otherFiles,
          ['notes-5.docx', 'notes-6.docx', 'notes-4.docx', 'notes-3.docx']);

      final few = await eligible(meeting());
      expect(few.inputsHash, many.inputsHash, reason: 'stable');
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
      await thread('c-1', eventId: 'evt-1');
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
      await thread('c-1', eventId: 'evt-1');
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
      await message('m-3', 'c-1', ago: const Duration(hours: 1), eventId: 'evt-1');
      await attach('m-1', 'a-1', name: 'Q3 Plan.pptx');
      await attach('m-2', 'a-2', name: 'q3 plan.pptx');
      await attach('m-3', 'a-3', name: 'Q3 plan.pptx');
      await attach('m-2', 'a-other', name: 'terms.pdf', ordinal: 1);

      final input = await eligible(meeting());
      expect([for (final m in input.materials) (m.messageId, m.name)],
          [('m-3', 'Q3 plan.pptx'), ('m-2', 'terms.pdf')]);
    });

    test('a digest landing moves the hash; a renamed file does not', () async {
      await thread('c-1', eventId: 'evt-1');
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
      await thread('c-1', eventId: 'evt-1');
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
      await thread('c-1', ago: const Duration(hours: 1), eventId: 'evt-1');
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
      await thread('c-1', ago: const Duration(hours: 1), eventId: 'evt-1');
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
      await message('m-c-1', 'c-1', ago: const Duration(hours: 3), eventId: 'evt-1');
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
      await message('m-c-2', 'c-2', ago: const Duration(hours: 1), eventId: 'evt-1');
      await attach('m-c-2', 'a-memo', name: 'memo.pdf');
      await queueText('m-c-2', 'a-memo');
      expect((await eligible(meeting())).materialsPending, isTrue);
    });

    test('a listed file with no text work is reported unqueued, not pending',
        () async {
      // An hour old: inside the wait's age cap.
      await thread('c-1', ago: const Duration(hours: 1), eventId: 'evt-1');
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
      await thread('c-1', eventId: 'evt-1');
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

      expect(documentEmbeds(server), ['Fabrikam sync\nAgenda: pricing.'],
          reason: 'the meeting, embedded once, under the document prefix');
      expect(server.inputs,
          contains('${EmbeddingsClient.searchQueryPrefix}Fabrikam sync\n'
              'Agenda: pricing.'),
          reason: "the people search's query, the only other embedding");
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
      expect(documentEmbeds(server), hasLength(1),
          reason: 'still only the first gather embedded the meeting');
      expect(
          server.inputs
              .where((i) => i.startsWith(EmbeddingsClient.searchQueryPrefix)),
          hasLength(2),
          reason: "the people search's query, once per gatherer: each "
              'caches its own');
    });

    test('a long deck cannot starve the other files of passages', () async {
      final chunks = _ChunkStore(db);
      await thread('c-1', eventId: 'evt-1');
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
      expect(documentEmbeds(server), hasLength(1),
          reason: 'the meeting is still embedded once');
    });

    test('no chunks, no embedding call', () async {
      final chunks = _ChunkStore(db)..hasChunks = false;
      await thread('c-1', eventId: 'evt-1');
      await attach('m-c-1', 'a-deck');
      final server = FakeEmbedServer();
      final input = await withChunks(chunks, server).gather(meeting(), now: now);
      expect((input as BriefEligible).input.materials.single.passages, isEmpty);
      expect(documentEmbeds(server), isEmpty);
      expect(server.inputs.single,
          startsWith(EmbeddingsClient.searchQueryPrefix),
          reason: "the one call is the people search's query");
      expect(chunks.knnCalls, isEmpty);
    });

    test('a passage failure costs no brief', () async {
      await thread('c-1', eventId: 'evt-1');
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
    // Dana wrote in it, so the people search finds it by her newest message
    // and quotes that and the newest two: all three, at the smaller cap.
    expect(snippets, hasLength(3), reason: 'the match and the newest two');
    for (final s in snippets) {
      expect(s, startsWith('<untrusted_data source="message">'));
      expect(s, endsWith('</untrusted_data>'));
    }
    expect(snippets[1], contains('&lt;b&gt;'), reason: 'escaped, not raw');
    // The cap holds on the text inside the fence.
    expect(snippets.last, contains('x' * 300));
    expect(snippets.last.length,
        lessThan(BriefGatherer.relatedSnippetCap + 100));
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
      expect(input.path, BriefPath.people,
          reason: 'the people path lists Kim, whom the threads show nothing '
              'from');
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
      // Topicless, so the people path lists the whole room up to the cap
      // (the related path lists only who wrote; tested with it).
      final input = await eligible(meeting(subject: 'Weekly sync', attendees: [
        const Attendee(name: 'Dana Lee', address: dana),
        for (var i = 0; i < 10; i++)
          Attendee(name: 'P$i', address: 'p$i@northwind.com'),
      ]));
      expect(input.path, BriefPath.people);
      expect(input.people, hasLength(BriefGatherer.maxPeople));
      expect(input.people.first.name, 'Dana Lee');
      expect(input.peopleMore, 3);
    });

    test('the organiser is never cut past eight', () async {
      await thread('c-1');
      // A Graph attendee copy: the organiser is not among the attendees,
      // so `briefOthers` lists them last.
      final input = await eligible(meeting(
        subject: 'Weekly sync',
        organizerAddress: 'olu@northwind.com',
        attendees: [
          const Attendee(name: 'Me', address: owner),
          const Attendee(name: 'Dana Lee', address: dana),
          for (var i = 0; i < 9; i++)
            Attendee(name: 'P$i', address: 'p$i@northwind.com'),
        ],
      ));
      expect(input.path, BriefPath.people);
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

  test('last met on the related path reads the people the block lists, not '
      'the whole room, however big it is', () async {
    List<Attendee> room(int n) => [
          for (var i = 0; i < n; i++)
            Attendee(name: 'Guest $i', address: 'guest$i@fabrikam.com'),
        ];
    Future<void> metWith(String id, String address) {
      final past = now.subtract(const Duration(days: 3));
      return calendar.upsertEvents([
        CalendarEvent(
          id: id,
          subject: 'Earlier',
          startUtc: past,
          endUtc: past.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          attendees: [Attendee(name: 'Someone', address: address)],
        ),
      ], syncRun: 'run-1');
    }

    // Guest 3 wrote on the meeting's own invite thread; nobody else wrote.
    await conversation('inv-1', people: const ['guest3@fabrikam.com']);
    await message('m-inv-1', 'inv-1',
        from: 'guest3@fabrikam.com', fromName: 'Guest 3', eventId: 'evt-1');

    // Five hundred others: the lookup must not bind an address each.
    final e = meeting(attendees: room(500));
    await metWith('evt-far', 'guest400@fabrikam.com');
    var input = await eligible(e);
    expect(input.path, BriefPath.related);
    expect(input.lastMet, isNull,
        reason: 'guest 400 wrote nothing, so is not listed');

    await metWith('evt-near', 'guest3@fabrikam.com');
    input = await eligible(e);
    expect(input.lastMet, startsWith('Last met'),
        reason: 'guest 3 wrote, so is listed');
  });

  group('the related path', () {
    late _RelatedStore related;
    late FakeEmbedServer server;
    late BriefGatherer relating;

    BriefGatherer gathererOver(_RelatedStore s, FakeEmbedServer embed) =>
        BriefGatherer(
          s,
          calendar,
          ownerAddress: () async => owner,
          zone: () => la,
          embeddings: embed.client,
        );

    setUp(() {
      related = _RelatedStore(db);
      server = FakeEmbedServer();
      relating = gathererOver(related, server);
    });

    /// Six other people, none of whom is on any thread below.
    const six = [
      Attendee(name: 'Me', address: owner),
      Attendee(name: 'Ana Ruiz', address: 'ana@northwind.com'),
      Attendee(name: 'Ben Okafor', address: 'ben@northwind.com'),
      Attendee(name: 'Cy Park', address: 'cy@northwind.com'),
      Attendee(name: 'Di Moss', address: 'di@northwind.com'),
      Attendee(name: 'Ed Vance', address: 'ed@northwind.com'),
      Attendee(name: 'Flo Hart', address: 'flo@northwind.com'),
    ];

    CalendarEvent big({
      String id = 'evt-1',
      String subject = 'Falcon launch plan',
      String bodyPreview = '',
      String seriesMasterId = '',
      List<Attendee> attendees = six,
    }) =>
        meeting(
          id: id,
          subject: subject,
          bodyPreview: bodyPreview,
          seriesMasterId: seriesMasterId,
          attendees: attendees,
        );

    /// A thread with someone who is not in the meeting.
    Future<void> topic(String key,
        {String? subject, Duration ago = const Duration(hours: 2), String? eventId}) async {
      await conversation(key,
          people: const ['kim@contoso.com'], ago: ago, subject: subject);
      await message('m-$key', key,
          from: 'kim@contoso.com', fromName: 'Kim', ago: ago, eventId: eventId);
    }

    Future<void> teamsChat(String key) async {
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': key,
        'subject': 'Falcon launch chat',
        'participants_json': jsonEncode([
          {'name': 'Kim', 'email': 'teams:kim'},
        ]),
        'state': 'waiting',
        'message_count': 1,
        'last_message_at': stampAgo(const Duration(hours: 1)),
      });
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'm-$key',
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Falcon launch chat',
        'from_name': 'Kim',
        'from_address': 'teams:kim',
        'received_at': stampAgo(const Duration(hours: 1)),
        'body_text': 'The launch moved a week.',
        'triage_status': 'done',
      });
    }

    /// A scripted hit on [key], matched on [messageId] (the `m-<key>` that
    /// [topic] and [teamsChat] write) received [ago] (theirs: two hours for
    /// a [topic], one for a [teamsChat]).
    RelatedConversation hit(String key, double cosine,
            {String source = 'email', String? messageId, Duration? ago}) =>
        (
          source: source,
          conversationKey: key,
          cosine: cosine,
          messageId: messageId ?? 'm-$key',
          receivedAt: stampAgo(ago ??
              (source == 'teams'
                  ? const Duration(hours: 1)
                  : const Duration(hours: 2))),
        );

    Future<BriefInput> relatedInput(CalendarEvent e,
        {bool passages = true}) async {
      final g = await relating.gather(e, now: now, passages: passages);
      expect(g, isA<BriefEligible>());
      return (g as BriefEligible).input;
    }

    test('six topical others: the nearest threads in score order, no '
        'attendee on them, a Teams chat among them', () async {
      await topic('c-a');
      await topic('c-b');
      await teamsChat('t-1');
      related.hits = [
        hit('c-b', 0.82),
        hit('t-1', 0.74, source: 'teams'),
        hit('c-a', 0.66),
      ];

      final input = await relatedInput(big());
      expect(input.path, BriefPath.related);
      expect([for (final t in input.threads) t.conversationKey],
          ['c-b', 't-1', 'c-a']);
      expect(input.threads[1].source, 'teams');
      expect([for (final t in input.threads) t.excerpt], [false, true, false]);
      expect(related.threadLoads, isNot(contains('t-1')),
          reason: "a chat's history is never read");
      expect(input.threads.every((t) => !t.invite), isTrue);
      expect(input.searchBest, closeTo(0.82, 1e-9));
      final call = related.calls.single;
      expect(call.embedModel, EmbeddingsClient.documentModelTag);
      expect(call.floor, BriefGatherer.relatedFloor);
      expect(call.limit, BriefGatherer.relatedCandidateLimit);
      expect(call.sinceIso,
          MessageStore.isoStamp(now.subtract(briefRelatedWindow)));
      expect(server.inputs.single,
          '${EmbeddingsClient.searchQueryPrefix}Falcon launch plan');
    });

    /// A Teams chat row for [key]: [count] messages, the newest [last] ago,
    /// with [roster] as the Teams sync writes it — a name and a `teams:` id.
    Future<void> chatRow(String key,
            {required Duration last,
            required int count,
            String state = 'waiting',
            String subject = 'Falcon room',
            List<Map<String, String>> roster = const [
              {'name': 'Kim', 'email': 'teams:kim'},
            ]}) =>
        store.upsertConversation({
          'source': 'teams',
          'conversation_key': key,
          'subject': subject,
          'participants_json': jsonEncode(roster),
          'state': state,
          'message_count': count,
          'last_message_at': stampAgo(last),
        });

    /// One chat message [id] in [key], [ago] old.
    Future<void> chatSays(String id, String key, Duration ago,
            {String fromName = 'Kim',
            String fromAddress = 'teams:kim',
            bool outbound = false,
            String? gateReason,
            String? body}) =>
        store.upsertMessage({
          'source': 'teams',
          'source_message_id': id,
          'conversation_key': key,
          'direction': outbound ? 'outbound' : 'inbound',
          'subject': 'Falcon room',
          'from_name': outbound ? 'Me' : fromName,
          'from_address': outbound ? owner : fromAddress,
          'received_at': stampAgo(ago),
          'body_text': body ?? 'Chat says $id.',
          // A bot's post is gated at ingest: skipped, with the reason.
          'triage_status': gateReason == null ? 'done' : 'skipped',
          'gate_reason': ?gateReason,
        });

    group('a related Teams chat is an excerpt', () {
      test('the match, what followed, then what came just before, all '
          "within a day; never the chat's newest, never its history",
          () async {
        await chatRow('t-1', last: const Duration(hours: 1), count: 5);
        await chatSays('b2', 't-1', const Duration(hours: 32));
        await chatSays('b1', 't-1', const Duration(hours: 31));
        await chatSays('match', 't-1', const Duration(hours: 30),
            body: 'Falcon launch slips ${'x' * 1000}');
        await chatSays('f1', 't-1', const Duration(hours: 29));
        // The chat's newest, a day and more after the match: another subject.
        await chatSays('late', 't-1', const Duration(hours: 1));
        related.hits = [
          hit('t-1', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 30)),
        ];

        final t = (await relatedInput(big())).threads.single;
        expect(t.source, 'teams');
        expect(t.excerpt, isTrue);
        expect(t.snippets, hasLength(3));
        expect(t.snippets[0], contains('Chat says b1.'));
        expect(t.snippets[1], contains('Falcon launch slips'));
        expect(t.snippets[2], contains('Chat says f1.'));
        expect(t.snippets.join(), isNot(contains('Chat says late.')));
        expect(t.snippets.join(), isNot(contains('Chat says b2.')));
        // Three quoted: each at the related cap, not the full one.
        expect(t.snippets[1], contains('x' * 300));
        expect(t.snippets[1], isNot(contains('x' * BriefGatherer.relatedSnippetCap)));
        // Stamped and counted by what is SHOWN, not by the room.
        expect(t.lastAt, stampAgo(const Duration(hours: 29)));
        expect(t.messageCount, 3);
        expect(related.threadLoads, isNot(contains('t-1')));
      });

      test('followers fill the excerpt before anything earlier does',
          () async {
        await chatRow('t-1', last: const Duration(hours: 6), count: 5);
        await chatSays('b1', 't-1', const Duration(hours: 11));
        await chatSays('match', 't-1', const Duration(hours: 10));
        await chatSays('f1', 't-1', const Duration(hours: 9));
        await chatSays('f2', 't-1', const Duration(hours: 8));
        await chatSays('f3', 't-1', const Duration(hours: 6));
        related.hits = [
          hit('t-1', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 10)),
        ];

        final t = (await relatedInput(big())).threads.single;
        expect(t.snippets, hasLength(3));
        expect(t.snippets[0], contains('Chat says match.'));
        expect(t.snippets[1], contains('Chat says f1.'));
        expect(t.snippets[2], contains('Chat says f2.'));
        expect(t.lastAt, stampAgo(const Duration(hours: 8)));
        expect(t.messageCount, 3);
      });

      test('the excerpt reaches three hours back and a day forward', () async {
        await chatRow('t-1', last: const Duration(hours: 30), count: 3);
        await chatSays('b5', 't-1', const Duration(hours: 35));
        await chatSays('b2', 't-1', const Duration(hours: 32));
        await chatSays('match', 't-1', const Duration(hours: 30));
        related.hits = [
          hit('t-1', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 30)),
        ];

        // Nothing followed: the fill runs backward, and only inside the
        // lead, so the excerpt is shorter than three.
        var t = (await relatedInput(big())).threads.single;
        expect(BriefGatherer.excerptLead, const Duration(hours: 3));
        expect(t.snippets, hasLength(2));
        expect(t.snippets[0], contains('Chat says b2.'));
        expect(t.snippets[1], contains('Chat says match.'));
        expect(t.snippets.join(), isNot(contains('Chat says b5.')));
        expect(t.messageCount, 2);

        // A reply 23 hours on joins; one 25 hours on does not.
        await chatSays('f23', 't-1', const Duration(hours: 7));
        await chatSays('f25', 't-1', const Duration(hours: 5));
        t = (await relatedInput(big())).threads.single;
        expect([
          for (final s in t.snippets) RegExp(r'Chat says (\w+)\.').firstMatch(s)![1]
        ], ['b2', 'match', 'f23']);
      });

      test("a bot's post is never quoted and takes no slot; a matched one "
          'still is', () async {
        await chatRow('t-1', last: const Duration(hours: 7), count: 4);
        await chatSays('match', 't-1', const Duration(hours: 10));
        await chatSays('bot', 't-1', const Duration(hours: 9),
            fromName: 'Build Bot',
            fromAddress: 'teams:bot',
            gateReason: 'auto_generated');
        await chatSays('reply', 't-1', const Duration(hours: 8));
        await chatSays('reply2', 't-1', const Duration(hours: 7));
        await chatRow('t-2', last: const Duration(hours: 4), count: 2);
        await chatSays('card', 't-2', const Duration(hours: 5),
            fromName: 'Build Bot',
            fromAddress: 'teams:bot',
            gateReason: 'auto_generated',
            body: 'Falcon build 412 is green.');
        await chatSays('ok', 't-2', const Duration(hours: 4));
        related.hits = [
          hit('t-1', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 10)),
          hit('t-2', 0.7,
              source: 'teams',
              messageId: 'card',
              ago: const Duration(hours: 5)),
        ];

        final threads = (await relatedInput(big())).threads;
        final room = threads[0];
        expect(room.snippets, hasLength(3));
        expect(room.snippets[0], contains('Chat says match.'));
        expect(room.snippets[1], contains('Chat says reply.'));
        expect(room.snippets[2], contains('Chat says reply2.'));
        expect(room.snippets.join(), isNot(contains('Chat says bot.')));
        expect(room.messageCount, 3);
        final card = threads[1];
        expect(card.snippets[0], contains('Falcon build 412 is green.'));
        expect(card.snippets[1], contains('Chat says ok.'));
      });

      test('a hit whose message is gone skips that chat and keeps the '
          'others', () async {
        await chatRow('t-1', last: const Duration(hours: 1), count: 1);
        await chatSays('other', 't-1', const Duration(hours: 1));
        await topic('c-a');
        related.hits = [
          hit('t-1', 0.9, source: 'teams', messageId: 'gone'),
          hit('c-a', 0.8),
        ];

        final input = await relatedInput(big());
        expect([for (final t in input.threads) t.conversationKey], ['c-a']);
        expect(input.searchBest, closeTo(0.8, 1e-9));
      });

      test("the room's later chatter leaves the hash alone; a reply that "
          'joins the excerpt moves it', () async {
        await chatRow('t-1', last: const Duration(hours: 29), count: 2);
        await chatSays('match', 't-1', const Duration(hours: 30));
        await chatSays('f1', 't-1', const Duration(hours: 29));
        related.hits = [
          hit('t-1', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 30)),
        ];
        final before = await relatedInput(big());
        expect(before.threads.single.messageCount, 2);

        // A new message a day on, and the conversation row bumped with it.
        await chatSays('late', 't-1', const Duration(hours: 1));
        await chatRow('t-1', last: const Duration(hours: 1), count: 3);
        final later = await relatedInput(big());
        expect(later.threads.single.messageCount, 2);
        expect(later.inputsHash, before.inputsHash);

        // A follow-up inside the span joins the two shown.
        await chatSays('f2', 't-1', const Duration(hours: 28));
        final joined = await relatedInput(big());
        expect(joined.threads.single.messageCount, 3);
        expect(joined.threads.single.lastAt, stampAgo(const Duration(hours: 28)));
        expect(joined.inputsHash, isNot(before.inputsHash));
      });

      test('an excerpt is never an open ask nor waiting on them; the same '
          'shape in mail is', () async {
        // A chat whose state says the owner owes an answer to an attendee's
        // request, and one whose last shown message is the owner's.
        await chatRow('t-ask',
            last: const Duration(hours: 3), count: 1, state: 'needs_reply');
        await chatSays('m-t-ask', 't-ask', const Duration(hours: 3),
            fromName: 'Ana Ruiz', fromAddress: 'ana@northwind.com');
        await store.writeDecision(
          'teams',
          'm-t-ask',
          fakeDecision(fakeAnswers(needsYou: 0.9, intent: 'request')),
          qhash: DecisionHeads.expectedQhash,
          ownerKnown: true,
        );
        await chatRow('t-wait', last: const Duration(hours: 3), count: 1);
        await chatSays('m-t-wait', 't-wait', const Duration(hours: 3),
            outbound: true);
        // The controls, as mail.
        await conversation('c-ask',
            state: 'needs_reply', people: const ['ana@northwind.com']);
        await message('m-c-ask', 'c-ask',
            from: 'ana@northwind.com', fromName: 'Ana Ruiz');
        await decide('m-c-ask', needsYou: 0.9, intent: 'request');
        await conversation('c-wait', people: const ['kim@contoso.com']);
        await message('m-c-wait', 'c-wait', outbound: true);
        related.hits = [
          hit('t-ask', 0.9,
              source: 'teams', ago: const Duration(hours: 3)),
          hit('t-wait', 0.88,
              source: 'teams', ago: const Duration(hours: 3)),
          hit('c-ask', 0.8),
          hit('c-wait', 0.78),
        ];

        final input = await relatedInput(big());
        expect([for (final t in input.threads) t.conversationKey],
            ['t-ask', 't-wait', 'c-ask', 'c-wait']);
        expect([for (final a in input.openAsks) a.threadIndex], [2]);
        expect([for (final t in input.waitingOn) t.conversationKey],
            ['c-wait']);
      });
    });

    group('a related mail thread', () {
      /// A thread [key] with Kim of [n] messages, the oldest [n] hours ago.
      Future<void> mailThread(String key, int n) async {
        await conversation(key,
            people: const ['kim@contoso.com'],
            count: n,
            ago: const Duration(hours: 1));
        for (var i = 1; i <= n; i++) {
          await message('$key-$i', key,
              from: 'kim@contoso.com',
              fromName: 'Kim',
              ago: Duration(hours: n - i + 1),
              body: 'Note $i ${'y' * 1000}');
        }
      }

      test('quotes the match and the newest two, oldest first, each at the '
          'related cap', () async {
        await mailThread('c-m', 5);
        related.hits = [
          hit('c-m', 0.8, messageId: 'c-m-1', ago: const Duration(hours: 5)),
        ];
        final t = (await relatedInput(big())).threads.single;
        expect(t.excerpt, isFalse);
        expect(t.snippets, hasLength(3));
        expect(t.snippets[0], contains('Note 1 '));
        expect(t.snippets[1], contains('Note 4 '));
        expect(t.snippets[2], contains('Note 5 '));
        for (final snippet in t.snippets) {
          expect(snippet, contains('y' * 300));
          expect(snippet, isNot(contains('y' * BriefGatherer.relatedSnippetCap)));
        }
        // A mail thread is whole: its stamp and count are the thread's.
        expect(t.messageCount, 5);
      });

      test('a match already among the newest quotes the last three', () async {
        await mailThread('c-m', 5);
        related.hits = [
          hit('c-m', 0.8, messageId: 'c-m-4', ago: const Duration(hours: 2)),
        ];
        final t = (await relatedInput(big())).threads.single;
        expect([for (final s in t.snippets) RegExp(r'Note \d').firstMatch(s)![0]],
            ['Note 3', 'Note 4', 'Note 5']);
      });

      test('a two-message thread quotes both at the full cap', () async {
        await mailThread('c-m', 2);
        related.hits = [
          hit('c-m', 0.8, messageId: 'c-m-1', ago: const Duration(hours: 2)),
        ];
        final t = (await relatedInput(big())).threads.single;
        expect(t.snippets, hasLength(2));
        for (final snippet in t.snippets) {
          expect(snippet, contains('y' * 500));
        }
      });

      test('an invite thread still quotes its last two at the full cap',
          () async {
        await conversation('inv-0',
            people: const ['kim@contoso.com'],
            count: 3,
            ago: const Duration(hours: 1));
        for (var i = 1; i <= 3; i++) {
          await message('inv-0-$i', 'inv-0',
              from: 'kim@contoso.com',
              fromName: 'Kim',
              ago: Duration(hours: 4 - i),
              body: 'Note $i ${'y' * 1000}',
              eventId: 'evt-1');
        }
        related.hits = const [];
        final t = (await relatedInput(big())).threads.single;
        expect(t.invite, isTrue);
        expect(t.snippets, hasLength(2));
        expect(t.snippets[0], contains('Note 2 '));
        expect(t.snippets[1], contains('Note 3 '));
        for (final snippet in t.snippets) {
          expect(snippet, contains('y' * 500));
        }
      });
    });

    group('people on the related path are only who WROTE in the threads',
        () {
      /// Me, Guest 1–10, then Lee Mapp, Pat Quill and Rae Roster.
      final attendees = [
        const Attendee(name: 'Me', address: owner),
        for (var i = 1; i <= 10; i++)
          Attendee(name: 'Guest $i', address: 'g$i@northwind.com'),
        const Attendee(name: 'Lee Mapp', address: 'g11@northwind.com'),
        const Attendee(name: 'Pat Quill', address: 'g12@northwind.com'),
        const Attendee(name: 'Rae Roster', address: 'g13@northwind.com'),
      ];

      /// A related mail thread Lee wrote in, with Rae on its roster only;
      /// and a chat excerpt Pat wrote in, under a chat id and another case.
      Future<void> seedWriters() async {
        await conversation('c-m',
            people: const ['kim@contoso.com', 'g13@northwind.com']);
        await message('m-c-m', 'c-m',
            from: 'g11@northwind.com',
            fromName: 'Lee Mapp',
            body: 'The Falcon pricing is agreed.');
        await chatRow('t-1', last: const Duration(hours: 1), count: 1);
        await chatSays('m-t-1', 't-1', const Duration(hours: 1),
            fromName: 'PAT QUILL',
            fromAddress: 'teams:pat',
            body: 'The Falcon vendor signed today.');
        related.hits = [hit('c-m', 0.8), hit('t-1', 0.75, source: 'teams')];
      }

      CalendarEvent falcon() => meeting(
            subject: 'Falcon launch plan',
            organizerAddress: 'g3@northwind.com',
            attendees: attendees,
          );

      test('mail by address and Teams by name count alike; the organiser '
          'leads when they wrote; a roster alone is not writing', () async {
        await seedWriters();
        // The organiser sent the invite: they wrote, on the invite thread.
        await conversation('inv-1', people: const ['g3@northwind.com']);
        await message('m-inv-1', 'inv-1',
            from: 'g3@northwind.com',
            fromName: 'Guest 3',
            body: 'Agenda: the Falcon go or no-go.',
            eventId: 'evt-1');

        final input = await relatedInput(falcon());
        expect(input.path, BriefPath.related);
        expect([for (final p in input.people) p.name],
            ['Guest 3', 'Lee Mapp', 'Pat Quill'],
            reason: 'Rae is only on a roster; the other guests wrote nothing');
        expect(input.people.first.isOrganizer, isTrue);
        expect(input.peopleMore, 13 - input.people.length);
        final lee = input.people[1];
        expect(lee.threadCount, 1);
        expect(lee.lastWords, contains('The Falcon pricing is agreed.'));
        final pat = input.people[2];
        expect(pat.threadCount, 1);
        expect(pat.lastWords, contains('The Falcon vendor signed today.'));
      });

      test('an organiser who wrote nothing is not listed', () async {
        await seedWriters();
        final input = await relatedInput(falcon());
        expect([for (final p in input.people) p.name], ['Lee Mapp', 'Pat Quill']);
        expect(input.people.any((p) => p.isOrganizer), isFalse);
        expect(input.peopleMore, 13 - 2);
      });

      test('nobody in the meeting wrote: no people, all of them counted',
          () async {
        await topic('c-a');
        related.hits = [hit('c-a', 0.8)];
        final input = await relatedInput(big());
        expect(input.threads, hasLength(1));
        expect(input.people, isEmpty);
        expect(input.peopleMore, 6);
      });

      test('ten who wrote: eight listed, the rest counted', () async {
        await conversation('c-m', people: const ['kim@contoso.com']);
        for (var i = 1; i <= 10; i++) {
          await message('m-$i', 'c-m',
              from: 'g$i@northwind.com',
              fromName: 'Guest $i',
              ago: Duration(hours: 12 - i));
        }
        related.hits = [hit('c-m', 0.8, messageId: 'm-1')];
        final input = await relatedInput(big(attendees: [
          const Attendee(name: 'Me', address: owner),
          for (var i = 1; i <= 10; i++)
            Attendee(name: 'Guest $i', address: 'g$i@northwind.com'),
        ]));
        expect([for (final p in input.people) p.name],
            [for (var i = 1; i <= 8; i++) 'Guest $i']);
        expect(input.peopleMore, 2);
      });
    });

    test('With: leads with the organiser, who `briefOthers` lists last, on '
        'either path', () async {
      CalendarEvent attendeeCopy(int n) {
        final start = now.add(const Duration(hours: 3));
        return CalendarEvent(
          id: 'evt-1',
          subject: 'Falcon launch plan',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          responseStatus: 'accepted',
          organizerName: 'Orla Grant',
          organizerAddress: 'orla@northwind.com',
          changeKey: 'ck-1',
          attendees: [
            const Attendee(name: 'Me', address: owner),
            for (var i = 1; i <= n; i++)
              Attendee(name: 'Guest $i', address: 'g$i@northwind.com'),
          ],
        );
      }

      // Nineteen attendees and the organiser: twenty others.
      final large = await relatedInput(attendeeCopy(19));
      expect(large.path, BriefPath.related);
      expect(large.attendees, hasLength(20));
      expect(large.attendees.first, 'Orla Grant');
      final msg = const MeetingBriefTask().buildUserMessage(large);
      expect(
          msg,
          contains(wrapUntrusted('attendees',
              large.attendees.take(MeetingBriefTask.withCap).join(', '))));
      expect(msg, contains('Orla Grant'));

      // Four others: the people path, the organiser first there too.
      await conversation('c-g', people: const ['g1@northwind.com']);
      await message('m-c-g', 'c-g', from: 'g1@northwind.com', fromName: 'Guest 1');
      final small = await relatedInput(attendeeCopy(3));
      expect(small.path, BriefPath.people);
      expect(small.attendees, ['Orla Grant', 'Guest 1', 'Guest 2', 'Guest 3']);
    });

    test('the people path still reads thirty days of mail', () async {
      // Older than the related search's 21 days, inside the people path's 30.
      await thread('c-old', ago: const Duration(days: 25));
      final input = await eligible(meeting());
      expect(input.path, BriefPath.people);
      expect([for (final t in input.threads) t.conversationKey], ['c-old']);
      expect(briefRelatedWindow, const Duration(days: 21));
      expect(briefMailWindow, const Duration(days: 30));
    });

    test('at most four related threads', () async {
      for (var i = 0; i < 6; i++) {
        await topic('c-$i');
      }
      related.hits = [for (var i = 0; i < 6; i++) hit('c-$i', 0.9 - i / 100)];
      final input = await relatedInput(big());
      expect([for (final t in input.threads) t.conversationKey],
          ['c-0', 'c-1', 'c-2', 'c-3']);
    });

    test('invite threads lead and are flagged; three of them leave room for '
        'three related; an invite key among the hits is not doubled',
        () async {
      for (var i = 0; i < 3; i++) {
        await topic('inv-$i', eventId: 'evt-1', ago: Duration(hours: i + 1));
      }
      for (var i = 0; i < 4; i++) {
        await topic('c-$i');
      }
      related.hits = [
        hit('inv-0', 0.95),
        for (var i = 0; i < 4; i++) hit('c-$i', 0.9 - i / 100),
      ];
      final input = await relatedInput(big());
      expect(input.threads, hasLength(BriefGatherer.maxThreads));
      expect([for (final t in input.threads.take(3)) t.conversationKey]..sort(),
          ['inv-0', 'inv-1', 'inv-2']);
      expect([for (final t in input.threads) t.invite],
          [true, true, true, false, false, false]);
      expect([for (final t in input.threads.skip(3)) t.conversationKey],
          ['c-0', 'c-1', 'c-2']);
      expect(input.searchBest, closeTo(0.9, 1e-9),
          reason: 'the invite hit was not kept as a related thread');
    });

    test("another meeting's invite and an Accepted: thread are dropped; the "
        "series master's thread leads as an invite thread, not doubled",
        () async {
      await topic('c-other', eventId: 'evt-other');
      await topic('c-accepted', subject: 'RE: Accepted: Falcon launch plan');
      await topic('c-master', eventId: 'master-1');
      await topic('c-plain');
      related.hits = [
        hit('c-other', 0.9),
        hit('c-accepted', 0.88),
        hit('c-master', 0.8),
        hit('c-plain', 0.7),
      ];
      // c-master's message names the series master: the occurrence's own
      // invite lookup finds it, so it is kept and leads as an invite thread
      // rather than being dropped as another meeting's.
      final input = await relatedInput(big(seriesMasterId: 'master-1'));
      expect([for (final t in input.threads) t.conversationKey],
          ['c-master', 'c-plain']);
      expect([for (final t in input.threads) t.invite], [true, false]);
      expect(input.searchBest, closeTo(0.7, 1e-9));
    });

    test('a big meeting with nothing to search by sends no query: still '
        'eligible, and no_query hashes apart from off', () async {
      final many = [
        for (var i = 0; i < 16; i++)
          Attendee(name: 'Guest $i', address: 'guest$i@northwind.com'),
      ];
      final e = big(subject: '', attendees: many);
      final input = await relatedInput(e);
      expect(server.calls, 0);
      expect(related.calls, isEmpty);
      expect(input.path, BriefPath.related);
      expect(input.threads, isEmpty);
      final off = await BriefGatherer(related, calendar,
              ownerAddress: () async => owner, zone: () => la)
          .gather(e, now: now) as BriefEligible;
      expect(off.input.path, BriefPath.related);
      expect(off.input.inputsHash, isNot(input.inputsHash),
          reason: 'related|no_query against related|off');
    });

    test('nothing found is still eligible, never no_mail', () async {
      related.hits = const [];
      final input = await relatedInput(big());
      expect(input.threads, isEmpty);
      expect(input.path, BriefPath.related);
      expect(input.searchBest, isNull);
      expect(input.inputsHash, isNotEmpty);
    });

    test('the query is embedded once across gathers, and the light and full '
        'gathers hash alike', () async {
      await topic('c-a');
      related.hits = [hit('c-a', 0.8)];
      final full = await relatedInput(big());
      final light = await relatedInput(big(), passages: false);
      expect(server.calls, 1);
      expect(server.inputs.single,
          startsWith(EmbeddingsClient.searchQueryPrefix));
      expect(related.calls, hasLength(2), reason: 'the KNN runs each time');
      expect(light.inputsHash, full.inputsHash);
      expect([for (final t in light.threads) t.conversationKey], ['c-a']);
    });

    test('the agenda rides the query; the join block does not', () async {
      await relatedInput(big(
          bodyPreview: 'Agree the launch checklist.\n__________\n'
              'Microsoft Teams meeting Join on your computer'));
      expect(server.inputs.single,
          '${EmbeddingsClient.searchQueryPrefix}Falcon launch plan\n'
          'Agree the launch checklist.');
    });

    test('embed down: unavailable, no second request inside two minutes, '
        'one after; the hash moves when the search comes back', () async {
      await topic('c-a');
      related.hits = [hit('c-a', 0.8)];
      final down = FakeEmbedServer(status: 500);
      final g = gathererOver(related, down);

      final first = await g.gather(big(), now: now) as BriefEligible;
      expect(first.input.threads, isEmpty);
      expect(down.calls, 1);
      expect(related.calls, isEmpty);

      final soon = await g.gather(big(),
          now: now.add(const Duration(minutes: 1))) as BriefEligible;
      expect(down.calls, 1, reason: 'inside embedRetryAfter');
      expect(soon.input.inputsHash, first.input.inputsHash);

      await g.gather(big(), now: now.add(const Duration(minutes: 3)));
      expect(down.calls, 2, reason: 'past embedRetryAfter');

      // The same meeting and mail with a working server: `ok`, and a thread.
      final back = await relatedInput(big());
      expect(back.threads, hasLength(1));
      expect(back.inputsHash, isNot(first.input.inputsHash));
    });

    test('the related state alone moves the hash', () async {
      related.hits = const [];
      final ok = await relatedInput(big());
      final off = await BriefGatherer(related, calendar,
              ownerAddress: () async => owner, zone: () => la)
          .gather(big(), now: now) as BriefEligible;
      expect(off.input.threads, isEmpty);
      expect(off.input.inputsHash, isNot(ok.inputsHash));
      related.indexMissing = true;
      final noIndex = await relatedInput(big());
      expect(noIndex.inputsHash, isNot(ok.inputsHash));
      expect(noIndex.inputsHash, isNot(off.input.inputsHash));
    });

    test("a five-person meeting's hash: the people path adds no path or "
        'search line, byte for byte', () async {
      await thread('c-1');
      final e = meeting(attendees: const [
        Attendee(name: 'Dana Lee', address: dana),
        Attendee(name: 'Sam', address: sam),
        Attendee(name: 'Kim', address: 'kim@northwind.com'),
        Attendee(name: 'Lu', address: 'lu@northwind.com'),
        Attendee(name: 'Mo', address: 'mo@northwind.com'),
      ]);
      // A topical meeting: the people search embeds its query and finds
      // Dana's thread by her message.
      related.senderHits = [hit('c-1', 0.7, messageId: 'm-c-1')];
      final input = await relatedInput(e);
      expect(input.path, BriefPath.people);
      expect(input.search, 'ok');
      expect(server.inputs.single,
          startsWith(EmbeddingsClient.searchQueryPrefix));
      final row = (await store.getConversationRow('email', 'c-1'))!;
      final lines = [
        'event|${e.id}|${e.changeKey}',
        'start|${e.startUtc!.toIso8601String()}',
        'end|${e.endUtc!.toIso8601String()}',
        'owner|$owner',
        'thread|email|c-1|${row['last_message_at']}|1',
      ];
      expect(input.inputsHash,
          sha256.convert(utf8.encode(lines.join('\n'))).toString());
    });

    test('a topicless meeting of eight others takes the people path, with '
        'the address threads', () async {
      await thread('c-1');
      final input = await relatedInput(big(
        subject: 'Weekly sync',
        attendees: [
          const Attendee(name: 'Dana Lee', address: dana),
          for (var i = 0; i < 7; i++)
            Attendee(name: 'P$i', address: 'p$i@northwind.com'),
        ],
      ));
      expect(input.path, BriefPath.people);
      expect([for (final t in input.threads) t.conversationKey], ['c-1']);
      expect(related.calls, isEmpty);
      expect(server.calls, 0);
    });

    group('the people path reads what its people wrote, mail and Teams', () {
      const lopez = Attendee(name: 'Dana Lopez', address: dana);
      const danaRoster = [
        {'name': 'Dana Lopez', 'email': 'teams:dana-id'},
      ];

      CalendarEvent small({
        String subject = 'Fabrikam renewal pricing',
        List<Attendee> attendees = const [
          Attendee(name: 'Me', address: owner),
          lopez,
        ],
      }) =>
          meeting(subject: subject, attendees: attendees);

      /// Topicless: nothing to search by, so ordered by time.
      CalendarEvent oneOnOne() => small(subject: '1:1');

      /// Dana's 1:1 chat with the owner: its row, as the Teams sync writes
      /// it, [count] messages, the newest [last] ago.
      Future<void> danaChat(String key,
              {required Duration last,
              int count = 1,
              String state = 'waiting'}) =>
          chatRow(key,
              last: last,
              count: count,
              state: state,
              subject: 'Renewal chat',
              roster: danaRoster);

      /// Dana writing in a chat: no address, her id and her name.
      Future<void> danaSays(String id, String key, Duration ago,
              {String? body}) =>
          chatSays(id, key, ago,
              fromName: 'Dana Lopez', fromAddress: 'teams:dana-id', body: body);

      /// A mail thread Dana wrote in: the row with her on it, one message.
      Future<void> danaMail(String key, Duration ago,
          {String? subject, String? eventId}) async {
        await conversation(key, ago: ago, subject: subject);
        await message('m-$key', key,
            fromName: 'Dana Lopez', ago: ago, eventId: eventId);
      }

      /// A mail thread Dana is only ON: Kim wrote it, [pressing] or not.
      Future<void> onlyOn(String key, Duration ago,
          {bool pressing = false}) async {
        await conversation(key,
            people: const [dana, 'kim@contoso.com'], ago: ago);
        await message('m-$key', key,
            from: 'kim@contoso.com', fromName: 'Kim', ago: ago);
        if (pressing) await decide('m-$key', urgency: 'high');
      }

      List<String> keys(BriefInput input) =>
          [for (final t in input.threads) t.conversationKey];

      test('a 1:1 whose only contact is a Teams chat Dana wrote in is '
          'briefed from an excerpt of it, by time, with no query embedded',
          () async {
        await danaChat('t-dana', last: const Duration(hours: 2), count: 2);
        await danaSays('d-1', 't-dana', const Duration(hours: 3),
            body: 'Are the tiers final?');
        await chatSays('o-1', 't-dana', const Duration(hours: 2),
            outbound: true);

        final g = await relating.gather(oneOnOne(), now: now, passages: false);
        expect(g, isA<BriefEligible>(), reason: 'a chat is contact: no no_mail');
        final input = (g as BriefEligible).input;
        expect(input.path, BriefPath.people);
        expect(input.search, 'recent');
        final t = input.threads.single;
        expect((t.source, t.conversationKey, t.excerpt),
            ('teams', 't-dana', true));
        expect(t.snippets.first, contains('Are the tiers final?'));
        expect(server.inputs, isEmpty,
            reason: 'a topicless meeting has nothing to search by');
        expect([for (final c in related.senderCalls) c.ranked], [false]);
        expect(related.threadLoads, isNot(contains('t-dana')));
        expect(input.searchBest, isNull);
      });

      test('nothing from them anywhere and no invite thread: no_mail; asked, '
          'a brief with no threads', () async {
        // Somebody else's chat and mail, with nobody from the meeting on
        // them.
        await chatRow('t-kim', last: const Duration(hours: 1), count: 1);
        await chatSays('k-1', 't-kim', const Duration(hours: 1));
        await topic('c-kim');

        final g = await relating.gather(oneOnOne(), now: now);
        expect((g as BriefIneligible).why, BriefIneligibility.noMail);
        final asked =
            await relating.gather(oneOnOne(), now: now, asked: true)
                as BriefEligible;
        expect(asked.input.threads, isEmpty);
      });

      test('a topical meeting is searched by meaning among what its people '
          'wrote: addresses, the names the invite gives, three weeks', () async {
        await danaMail('c-a', const Duration(hours: 5));
        related.senderHits = [
          hit('c-a', 0.71, ago: const Duration(hours: 5)),
        ];
        final e = small(attendees: const [
          Attendee(name: 'Me', address: owner),
          lopez,
          // Named by address only: matched in mail alone.
          Attendee(name: '', address: sam),
        ]);

        final full = await relatedInput(e);
        await relatedInput(e, passages: false);
        expect(full.path, BriefPath.people);
        expect(full.search, 'ok');
        expect(keys(full), ['c-a']);
        expect(full.searchBest, closeTo(0.71, 1e-9));
        expect([for (final c in related.senderCalls) c.ranked], [true, true],
            reason: 'ordered by meaning, so never asked by time');
        final call = related.senderCalls.first;
        expect(call.embedModel, EmbeddingsClient.documentModelTag);
        expect(call.addresses, {dana, sam});
        expect(call.names, {'Dana Lopez'});
        expect(call.limit, BriefGatherer.relatedCandidateLimit);
        expect(
            DateTime.parse(call.sinceIso)
                .difference(now.subtract(briefRelatedWindow))
                .abs(),
            lessThan(const Duration(seconds: 1)));
        expect(server.inputs,
            ['${EmbeddingsClient.searchQueryPrefix}Fabrikam renewal pricing'],
            reason: 'embedded once across the two gathers');
        expect(related.calls, isEmpty, reason: 'no related search');
      });

      test('ordered by meaning: what they wrote leads in score order, then '
          'the mail they are only on, pressing first — it never jumps the '
          'found ones', () async {
        await danaChat('t-dana', last: const Duration(hours: 4));
        await danaSays('d-1', 't-dana', const Duration(hours: 4));
        await danaMail('c-a', const Duration(hours: 5));
        await onlyOn('c-press', const Duration(hours: 2), pressing: true);
        await onlyOn('c-plain', const Duration(minutes: 30));
        related.senderHits = [
          hit('t-dana', 0.8,
              source: 'teams',
              messageId: 'd-1',
              ago: const Duration(hours: 4)),
          hit('c-a', 0.6, ago: const Duration(hours: 5)),
        ];

        final input = await relatedInput(small());
        expect(input.search, 'ok');
        expect(keys(input), ['t-dana', 'c-a', 'c-press', 'c-plain']);
        expect([for (final t in input.threads) t.excerpt],
            [true, false, false, false]);
        expect([for (final t in input.threads) t.ranked],
            [false, false, true, false]);
      });

      test('ordered by time: a pressing thread they are on leads, then the '
          'rest newest first, a chat placed by its newest SHOWN message',
          () async {
        // Dana wrote thirty hours ago; Kim's chatter half an hour ago is a
        // day and more later, so outside her excerpt — and the room's own
        // newest stamp.
        await danaChat('t-dana', last: const Duration(minutes: 30), count: 2);
        await danaSays('d-1', 't-dana', const Duration(hours: 30));
        await chatSays('k-late', 't-dana', const Duration(minutes: 30));
        await onlyOn('c-press', const Duration(hours: 48), pressing: true);
        await onlyOn('c-mid', const Duration(hours: 10));
        await onlyOn('c-older', const Duration(hours: 40));

        final input = await relatedInput(oneOnOne());
        expect(input.search, 'recent');
        expect(keys(input), ['c-press', 'c-mid', 't-dana', 'c-older']);
        expect(input.threads[2].lastAt, stampAgo(const Duration(hours: 30)));
      });

      test('at most four found, six in all, the invite threads leading',
          () async {
        for (var i = 0; i < 2; i++) {
          await danaMail('inv-$i', Duration(hours: 10 + i), eventId: 'evt-1');
        }
        for (var i = 0; i < 6; i++) {
          await danaMail('c-$i', Duration(hours: i + 1));
        }
        related.senderHits = [
          for (var i = 0; i < 6; i++)
            hit('c-$i', 0.9 - i / 100, ago: Duration(hours: i + 1)),
        ];

        final input = await relatedInput(small());
        expect(keys(input), ['inv-0', 'inv-1', 'c-0', 'c-1', 'c-2', 'c-3']);
        expect([for (final t in input.threads) t.invite],
            [true, true, false, false, false, false]);
      });

      test('ordered by meaning with room left, the mail they are only on '
          'fills it, pressing first', () async {
        for (var i = 0; i < 3; i++) {
          await danaMail('inv-$i', Duration(hours: 10 + i), eventId: 'evt-1');
        }
        for (var i = 0; i < 4; i++) {
          await danaMail('c-$i', Duration(hours: i + 1));
        }
        await onlyOn('c-only', const Duration(minutes: 30), pressing: true);
        // One found thread: room for two more after the three invites.
        related.senderHits = [hit('c-0', 0.9, ago: const Duration(hours: 1))];

        final roomy = await relatedInput(small());
        expect(keys(roomy),
            ['inv-0', 'inv-1', 'inv-2', 'c-0', 'c-only', 'c-1']);
      });

      test('a logistics subject is dropped and not brought back by the '
          "address match; another meeting's invite never leads as a match "
          'but is still mail with these people; an invite key is not doubled',
          () async {
        await danaMail('inv', const Duration(hours: 6), eventId: 'evt-1');
        await danaMail('c-acc', const Duration(hours: 3),
            subject: 'Accepted: Fabrikam renewal pricing');
        await danaMail('c-other', const Duration(hours: 4),
            eventId: 'evt-other');
        await danaMail('c-plain', const Duration(hours: 5));
        related.senderHits = [
          hit('inv', 0.95, ago: const Duration(hours: 6)),
          hit('c-acc', 0.9, ago: const Duration(hours: 3)),
          hit('c-other', 0.85, ago: const Duration(hours: 4)),
          hit('c-plain', 0.8, ago: const Duration(hours: 5)),
        ];

        final input = await relatedInput(small());
        expect(keys(input), ['inv', 'c-plain', 'c-other'],
            reason: 'Dana is on both threads the search left out, inside '
                'thirty days: only the other invite comes back, and last');
        expect([for (final t in input.threads) t.invite],
            [true, false, false]);
        expect(input.searchBest, closeTo(0.8, 1e-9));
        // Ordered by time the same two are listed, newest first, and the
        // answer is still left out.
        related.senderHits = null;
        final byTime = await BriefGatherer(related, calendar,
                ownerAddress: () async => owner, zone: () => la)
            .gather(small(), now: now) as BriefEligible;
        expect(keys(byTime.input), ['inv', 'c-other', 'c-plain']);
      });

      test('a chat excerpt on the people path: stamped and counted by what is '
          "shown, a bot's post left out, the room's later talk no input, never "
          'an ask nor waiting', () async {
        await danaChat('t-dana',
            last: const Duration(hours: 8), count: 4, state: 'needs_reply');
        await danaSays('match', 't-dana', const Duration(hours: 10),
            body: 'The renewal pricing needs your sign-off.');
        await chatSays('bot', 't-dana', const Duration(hours: 9, minutes: 30),
            fromName: 'Build Bot',
            fromAddress: 'teams:bot',
            gateReason: teamsBotGate);
        await chatSays('o-1', 't-dana', const Duration(hours: 9),
            outbound: true);
        await danaSays('d-2', 't-dana', const Duration(hours: 8),
            body: 'Can you approve it today?');
        await store.writeDecision(
          'teams',
          'd-2',
          fakeDecision(fakeAnswers(needsYou: 0.9, intent: 'approval')),
          qhash: DecisionHeads.expectedQhash,
          ownerKnown: true,
        );
        related.senderHits = [
          hit('t-dana', 0.8,
              source: 'teams',
              messageId: 'match',
              ago: const Duration(hours: 10)),
        ];

        final before = await relatedInput(small());
        final t = before.threads.single;
        expect(t.excerpt, isTrue);
        expect(t.snippets, hasLength(3));
        expect(t.snippets.join(), isNot(contains('Chat says bot.')));
        expect(t.lastAt, stampAgo(const Duration(hours: 8)));
        expect(t.messageCount, 3);
        expect(before.openAsks, isEmpty);
        expect(before.waitingOn, isEmpty);

        // The excerpt already shows three: a later line by the owner, inside
        // the day, is not part of it, and moves nothing.
        await chatSays('o-2', 't-dana', const Duration(hours: 7),
            outbound: true);
        await danaChat('t-dana',
            last: const Duration(hours: 7), count: 5, state: 'needs_reply');
        final later = await relatedInput(small());
        expect(later.threads.single.messageCount, 3);
        expect(later.inputsHash, before.inputsHash);
      });

      test('the people block reads a Teams-only writer by her name: her chat, '
          'her words, its subject', () async {
        await danaChat('t-dana', last: const Duration(hours: 2));
        await danaSays('d-1', 't-dana', const Duration(hours: 2),
            body: 'The 12k tier works for us.');

        final input = await relatedInput(oneOnOne());
        final d = input.people.single;
        expect(d.name, 'Dana Lopez');
        expect(d.threadCount, 1);
        expect(d.lastWords,
            wrapUntrusted('last_words', 'The 12k tier works for us.'));
        expect(d.lastSubject, 'Renewal chat');
        expect(d.lastInboundAgo, '2 hours ago');
      });

      group('how the search went', () {
        test('no embeddings client: off, one read by time', () async {
          await danaMail('c-a', const Duration(hours: 2));
          final g = await BriefGatherer(related, calendar,
                  ownerAddress: () async => owner, zone: () => la)
              .gather(small(), now: now) as BriefEligible;
          expect(g.input.search, 'off');
          expect(keys(g.input), ['c-a']);
          expect(related.senderCalls.single.ranked, isFalse);
          expect(g.input.searchBest, isNull);
        });

        test('embed down: unavailable and read by time; no second request '
            'inside two minutes, one after', () async {
          await danaMail('c-a', const Duration(hours: 2));
          final down = FakeEmbedServer(status: 500);
          final g = gathererOver(related, down);

          final first = await g.gather(small(), now: now) as BriefEligible;
          expect(first.input.search, 'unavailable');
          expect(keys(first.input), ['c-a']);
          expect([for (final c in related.senderCalls) c.ranked], [false]);
          expect(down.calls, 1);

          await g.gather(small(), now: now.add(const Duration(minutes: 1)));
          expect(down.calls, 1, reason: 'inside embedRetryAfter');
          await g.gather(small(), now: now.add(const Duration(minutes: 3)));
          expect(down.calls, 2, reason: 'past embedRetryAfter');
        });

        test('the ranked read returns null: unavailable, read by time',
            () async {
          await danaMail('c-a', const Duration(hours: 2));
          related.sendersIndexMissing = true;
          final input = await relatedInput(small());
          expect(input.search, 'unavailable');
          expect([for (final c in related.senderCalls) c.ranked],
              [true, false]);
          expect(keys(input), ['c-a']);
          expect(input.searchBest, isNull);
        });

        test('the ranked read throws: unavailable, read by time, the threads '
            'still there', () async {
          await danaMail('c-a', const Duration(hours: 2));
          related.sendersThrow = true;
          final input = await relatedInput(small());
          expect(input.search, 'unavailable');
          expect([for (final c in related.senderCalls) c.ranked],
              [true, false]);
          expect(keys(input), ['c-a']);
        });

        test('both reads throw: briefed from the mail they are on alone',
            () async {
          await danaMail('c-a', const Duration(hours: 2));
          related
            ..sendersThrow = true
            ..recentThrows = true;
          final input = await relatedInput(small());
          expect(input.search, 'unavailable');
          expect(keys(input), ['c-a'], reason: 'the address match');
          // Not found by her message, so quoted as before: its last two.
          expect(input.threads.single.snippets, hasLength(1));
        });
      });

      test('the light and full gathers hash alike with a chat excerpt and a '
          'found mail thread', () async {
        await danaChat('t-dana', last: const Duration(hours: 4));
        await danaSays('d-1', 't-dana', const Duration(hours: 4));
        await danaMail('c-a', const Duration(hours: 5));
        related.senderHits = [
          hit('t-dana', 0.8,
              source: 'teams',
              messageId: 'd-1',
              ago: const Duration(hours: 4)),
          hit('c-a', 0.6, ago: const Duration(hours: 5)),
        ];
        final full = await relatedInput(small());
        final light = await relatedInput(small(), passages: false);
        expect(keys(full), ['t-dana', 'c-a']);
        expect(keys(light), keys(full));
        expect(light.inputsHash, full.inputsHash);
      });
    });
  });

  group('the related path over the real search', () {
    late bool available;
    late BondDatabase vecDb;
    late MessageStore vecStore;

    setUpAll(() {
      available = ensureSqliteVecLoaded();
    });

    setUp(() {
      vecDb = vecTestDb();
      vecStore = MessageStore(vecDb);
    });

    tearDown(() async => vecDb.close());

    test('no scripted search: the store finds a chat message near the '
        'subject and the gatherer quotes it as an excerpt', () async {
      if (!available) return;
      // The query and the one message share an axis; everything else is
      // orthogonal to it.
      final embed = FakeEmbedServer(
        vectorFor: (input) =>
            input.contains('Falcon') ? axes({0: 1.0}) : axes({3: 1.0}),
      );
      await vecStore.upsertConversation({
        'source': 'teams',
        'conversation_key': 't-room',
        'subject': 'Ops room',
        'participants_json': jsonEncode([
          {'name': 'Kim', 'email': 'teams:kim'},
        ]),
        'state': 'waiting',
        'message_count': 2,
        'last_message_at': stampAgo(const Duration(hours: 2)),
      });
      for (final (id, age, body) in [
        ('t-lunch', const Duration(hours: 4), 'Lunch at noon?'),
        ('t-falcon', const Duration(hours: 2), 'The Falcon launch moves a week.'),
      ]) {
        await vecStore.upsertMessage({
          'source': 'teams',
          'source_message_id': id,
          'conversation_key': 't-room',
          'direction': 'inbound',
          'subject': 'Ops room',
          'from_name': 'Kim',
          'from_address': 'teams:kim',
          'received_at': stampAgo(age),
          'body_text': body,
          'triage_status': 'done',
        });
      }
      await vecStore.upsertMessageVector(
        source: 'teams',
        sourceMessageId: 't-falcon',
        embedding: encodeEmbedding(axes({0: 1.0})),
        dims: embedDims,
        embeddedHash: 'h-falcon',
        embedModel: EmbeddingsClient.documentModelTag,
      );
      await vecStore.upsertMessageVector(
        source: 'teams',
        sourceMessageId: 't-lunch',
        embedding: encodeEmbedding(axes({3: 1.0})),
        dims: embedDims,
        embeddedHash: 'h-lunch',
        embedModel: EmbeddingsClient.documentModelTag,
      );

      final g = await BriefGatherer(
        vecStore,
        CalendarStore(vecDb),
        ownerAddress: () async => owner,
        zone: () => la,
        embeddings: embed.client,
      ).gather(
        meeting(
          subject: 'Falcon launch plan',
          attendees: const [
            Attendee(name: 'Me', address: owner),
            Attendee(name: 'Ana Ruiz', address: 'ana@northwind.com'),
            Attendee(name: 'Ben Okafor', address: 'ben@northwind.com'),
            Attendee(name: 'Cy Park', address: 'cy@northwind.com'),
            Attendee(name: 'Di Moss', address: 'di@northwind.com'),
            Attendee(name: 'Ed Vance', address: 'ed@northwind.com'),
            Attendee(name: 'Flo Hart', address: 'flo@northwind.com'),
          ],
        ),
        now: now,
      );
      final input = (g as BriefEligible).input;
      expect(input.path, BriefPath.related);
      final t = input.threads.single;
      expect((t.source, t.conversationKey), ('teams', 't-room'));
      expect(t.excerpt, isTrue);
      expect(t.snippets.join(), contains('The Falcon launch moves a week.'));
      expect(t.lastAt, stampAgo(const Duration(hours: 2)));
      expect(input.searchBest, closeTo(1.0, 0.001));
    });

    test('no scripted search on the people path: what Dana wrote, nearest '
        "first, her chat before her mail; a stranger's nearer mail is never "
        'found', () async {
      if (!available) return;
      final embed = FakeEmbedServer(
        vectorFor: (input) =>
            input.contains('Fabrikam') ? axes({0: 1.0}) : axes({3: 1.0}),
      );
      Future<void> said(String source, String key, String id,
          {required String name,
          required String address,
          required Duration age,
          required Map<int, double> vector}) async {
        await vecStore.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': key,
          'direction': 'inbound',
          'subject': 'Thread $key',
          'from_name': name,
          'from_address': address,
          'received_at': stampAgo(age),
          'body_text': 'Message $id.',
          'triage_status': 'done',
        });
        await vecStore.upsertMessageVector(
          source: source,
          sourceMessageId: id,
          embedding: encodeEmbedding(axes(vector)),
          dims: embedDims,
          embeddedHash: 'h-$id',
          embedModel: EmbeddingsClient.documentModelTag,
        );
      }

      Future<void> row(String source, String key, List<Object> roster,
              Duration last) =>
          vecStore.upsertConversation({
            'source': source,
            'conversation_key': key,
            'subject': 'Thread $key',
            'participants_json': jsonEncode(roster),
            'state': 'waiting',
            'message_count': 1,
            'last_message_at': stampAgo(last),
          });

      // Dana's chat message sits near the subject; her mail far from it.
      await row('teams', 't-dana', [
        {'name': 'Dana Lopez', 'email': 'teams:dana-id'},
      ], const Duration(hours: 3));
      await said('teams', 't-dana', 'dana-chat',
          name: 'Dana Lopez',
          address: 'teams:dana-id',
          age: const Duration(hours: 3),
          vector: {0: 0.9, 2: 0.4359});
      await row('email', 'c-dana', [
        {'name': 'Dana Lopez', 'email': dana},
        {'name': 'Me', 'email': owner},
      ], const Duration(hours: 1));
      await said('email', 'c-dana', 'dana-mail',
          name: 'Dana Lopez',
          address: dana,
          age: const Duration(hours: 1),
          vector: {0: 0.2, 3: 0.9798});
      // A stranger's mail, the nearest of all, with nobody from the
      // meeting on it.
      await row('email', 'c-kim', [
        {'name': 'Kim', 'email': 'kim@contoso.com'},
        {'name': 'Me', 'email': owner},
      ], const Duration(hours: 2));
      await said('email', 'c-kim', 'kim-mail',
          name: 'Kim',
          address: 'kim@contoso.com',
          age: const Duration(hours: 2),
          vector: {0: 1.0});

      final g = await BriefGatherer(
        vecStore,
        CalendarStore(vecDb),
        ownerAddress: () async => owner,
        zone: () => la,
        embeddings: embed.client,
      ).gather(
        meeting(subject: 'Fabrikam renewal pricing', attendees: const [
          Attendee(name: 'Me', address: owner),
          Attendee(name: 'Dana Lopez', address: dana),
        ]),
        now: now,
      );
      final input = (g as BriefEligible).input;
      expect(input.path, BriefPath.people);
      expect(input.search, 'ok');
      expect([for (final t in input.threads) (t.source, t.conversationKey)],
          [('teams', 't-dana'), ('email', 'c-dana')]);
      expect(input.threads.first.excerpt, isTrue);
      expect(input.searchBest, closeTo(0.9, 0.001));
    });
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

/// A store whose related search is scripted, so the related path is tested
/// without seeding the vec0 index (`message_search_test.dart` tests the real
/// read): [hits] is what it answers, [indexMissing] answers null, and every
/// call is recorded. [threadLoads] records every `loadThread` key, so a test
/// can prove a chat's history was never read.
///
/// The people path's read by sender can be scripted too: [senderHits]
/// answers the RANKED call (with a query) and [recentHits] the unranked one;
/// either left null falls through to the real read, so a test that scripts
/// nothing runs the real SQL. [sendersIndexMissing] answers the ranked call
/// null, [sendersThrow] makes it throw and [recentThrows] the unranked one.
/// Every call is recorded in [senderCalls].
class _RelatedStore extends MessageStore {
  _RelatedStore(super.db);

  List<RelatedConversation> hits = const [];
  bool indexMissing = false;
  final List<String> threadLoads = [];

  List<RelatedConversation>? senderHits;
  List<RelatedConversation>? recentHits;
  bool sendersIndexMissing = false;
  bool sendersThrow = false;
  bool recentThrows = false;
  final List<
      ({
        bool ranked,
        String embedModel,
        Set<String> addresses,
        Set<String> names,
        String sinceIso,
        int limit
      })> senderCalls = [];

  @override
  Future<List<RelatedConversation>?> conversationsFromSenders({
    Uint8List? queryEmbedding,
    required String embedModel,
    required Set<String> addresses,
    required Set<String> names,
    required String sinceIso,
    int limit = 12,
  }) async {
    final ranked = queryEmbedding != null;
    senderCalls.add((
      ranked: ranked,
      embedModel: embedModel,
      addresses: addresses,
      names: names,
      sinceIso: sinceIso,
      limit: limit,
    ));
    if (ranked) {
      if (sendersThrow) throw StateError('the index broke');
      if (sendersIndexMissing) return null;
    } else if (recentThrows) {
      throw StateError('the store broke');
    }
    final scripted = ranked ? senderHits : recentHits;
    if (scripted != null) return scripted.take(limit).toList();
    return super.conversationsFromSenders(
      queryEmbedding: queryEmbedding,
      embedModel: embedModel,
      addresses: addresses,
      names: names,
      sinceIso: sinceIso,
      limit: limit,
    );
  }

  @override
  Future<List<Message>> loadThread(
    String conversationKey, {
    List<String> sources = const ['email'],
    String? untilIso,
  }) {
    threadLoads.add(conversationKey);
    return super.loadThread(conversationKey,
        sources: sources, untilIso: untilIso);
  }
  final List<
      ({
        Uint8List query,
        String embedModel,
        String sinceIso,
        double floor,
        int limit
      })> calls = [];

  @override
  Future<List<RelatedConversation>?> relatedConversations(
    Uint8List queryEmbedding, {
    required String embedModel,
    required String sinceIso,
    required double floor,
    int limit = 12,
  }) async {
    calls.add((
      query: queryEmbedding,
      embedModel: embedModel,
      sinceIso: sinceIso,
      floor: floor,
      limit: limit,
    ));
    if (indexMissing) return null;
    return hits.take(limit).toList();
  }
}
