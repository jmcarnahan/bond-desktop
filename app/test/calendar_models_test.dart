import 'dart:convert';

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calendar's value types against the tool rows bond-mcps sends and the
/// `calendar_events` row the mirror stores.
///
/// Most of what is pinned is TIME: which field an instant is read from, that
/// the legacy naive strings are read as UTC and not as the test machine's
/// zone, that an all-day event is dates and never instants, and that the
/// stored stamp is byte-identical to the message store's so the two sort
/// together.

/// A timed row as `sync_calendar` sends it (handoff §3.1), with every key.
Map<String, dynamic> _timedRow({Map<String, dynamic> overrides = const {}}) => {
      'id': 'evt-1',
      'subject': 'Quarterly planning',
      'start': '2026-10-01T16:00:00.0000000',
      'end': '2026-10-01T17:00:00.0000000',
      'timezone': 'UTC',
      'organizer': 'Dana Reyes',
      'location': 'Room 4',
      'online_url': null,
      'is_all_day': false,
      'is_cancelled': false,
      'start_utc': '2026-10-01T16:00:00Z',
      'end_utc': '2026-10-01T17:00:00Z',
      'start_date': '',
      'end_date': '',
      'type': 'singleInstance',
      'series_master_id': '',
      'show_as': 'busy',
      'response_status': 'notResponded',
      'is_organizer': false,
      'organizer_address': 'Dana@Contoso.com',
      'join_url': 'https://teams.microsoft.com/l/meetup-join/'
          '19%3ameeting_ABC123%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d',
      'attendees': [
        {
          'name': 'Sam Ortiz',
          'address': 'Sam@Fabrikam.com',
          'type': 'required',
          'response': 'accepted',
        },
        {'name': 'Lee Park', 'address': 'lee@contoso.com', 'type': 'optional'},
      ],
      'categories': ['Planning'],
      'web_link': 'https://outlook.office365.com/owa/?itemid=evt-1',
      'change_key': 'ck-1',
      'ical_uid': 'uid-1',
      'is_reminder_on': true,
      'reminder_minutes': 15,
      'body_preview': 'Agenda attached.',
      'sensitivity': 'normal',
      'allow_new_time_proposals': true,
      'response_requested': true,
      ...overrides,
    };

void main() {
  group('fromToolRow', () {
    test('a timed row reads its instants from start_utc/end_utc', () {
      final e = CalendarEvent.fromToolRow(_timedRow());

      expect(e.id, 'evt-1');
      expect(e.isTimed, isTrue);
      expect(e.startUtc, DateTime.utc(2026, 10, 1, 16));
      expect(e.endUtc, DateTime.utc(2026, 10, 1, 17));
      expect(e.startUtc!.isUtc, isTrue);
      expect(e.startDate, isNull);
      expect(e.endDate, isNull);
      expect(e.eventType, 'singleInstance');
      expect(e.organizerName, 'Dana Reyes');
      expect(e.organizerAddress, 'dana@contoso.com');
      expect(e.showAs, 'busy');
      expect(e.responseStatus, 'notResponded');
      expect(e.changeKey, 'ck-1');
      expect(e.reminderMinutes, 15);
      expect(e.isReminderOn, isTrue);
      expect(e.categories, ['Planning']);
      expect(e.attendees, [
        const Attendee(
          name: 'Sam Ortiz',
          address: 'sam@fabrikam.com',
          type: 'required',
          response: 'accepted',
        ),
        // `response` absent on the wire defaults to none.
        const Attendee(
          name: 'Lee Park',
          address: 'lee@contoso.com',
          type: 'optional',
          response: 'none',
        ),
      ]);
    });

    test('an empty start_utc falls back to the legacy naive string, as UTC',
        () {
      final e = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'start_utc': '',
        'end_utc': '',
        'start': '2026-10-01T16:00:00.0000000',
        'end': '2026-10-01T16:30:00.1234567',
      }));

      // The 7-digit fraction parses, and the naive string is NOT read in the
      // test machine's local zone.
      expect(e.startUtc, DateTime.utc(2026, 10, 1, 16));
      expect(e.startUtc!.isUtc, isTrue);
      expect(e.endUtc!.isUtc, isTrue);
      expect(e.endUtc!.hour, 16);
      expect(e.endUtc!.minute, 30);
    });

    test('an all-day row is dates with an exclusive end, never instants', () {
      final e = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'is_all_day': true,
        'start_utc': '2026-10-01T00:00:00Z',
        'end_utc': '2026-10-02T00:00:00Z',
        'start_date': '2026-10-01',
        'end_date': '2026-10-02',
        'join_url': '',
      }));

      expect(e.isAllDay, isTrue);
      expect(e.isTimed, isFalse);
      expect(e.startDate, const CalendarDate(2026, 10, 1));
      expect(e.endDate, const CalendarDate(2026, 10, 2));
      expect(e.startUtc, isNull);
      expect(e.endUtc, isNull);
    });

    test('an occurrence keeps its series master id', () {
      final e = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'id': 'occ-7',
        'type': 'occurrence',
        'series_master_id': 'master-1',
      }));

      expect(e.eventType, 'occurrence');
      expect(e.seriesMasterId, 'master-1');
      expect(e.isSeriesMaster, isFalse);
      expect(
        CalendarEvent.fromToolRow(_timedRow(overrides: {'type': 'seriesMaster'}))
            .isSeriesMaster,
        isTrue,
      );
    });

    test('a cancelled row reads as cancelled', () {
      final e = CalendarEvent.fromToolRow(
          _timedRow(overrides: {'is_cancelled': true}));
      expect(e.isCancelled, isTrue);
    });

    test('missing optional keys are empty defaults; a missing id throws', () {
      final e = CalendarEvent.fromToolRow({'id': 'bare'});
      expect(e.subject, '');
      expect(e.responseStatus, 'none');
      expect(e.responseRequested, isNull);
      expect(e.allowNewTimeProposals, isNull);
      expect(e.attendees, isEmpty);
      expect(e.startUtc, isNull);
      expect(e.reminderMinutes, isNull);

      // A non-String organizer is tolerated.
      expect(
        CalendarEvent.fromToolRow({'id': 'x', 'organizer': 42}).organizerName,
        '',
      );

      expect(() => CalendarEvent.fromToolRow({'subject': 'no id'}),
          throwsFormatException);
      expect(() => CalendarEvent.fromToolRow({'id': ''}),
          throwsFormatException);
    });
  });

  group('teamsThreadId', () {
    test('is decoded from the URL-encoded form in the join link', () {
      final e = CalendarEvent.fromToolRow(_timedRow());
      expect(e.teamsThreadId, '19:meeting_ABC123@thread.v2');
    });

    test('reads the encoded form in either case', () {
      final e = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'join_url': 'https://teams.microsoft.com/l/meetup-join/'
            '19%3AMeeting_xyz%40thread.v2/0',
      }));
      expect(e.teamsThreadId, '19:Meeting_xyz@thread.v2');
    });

    test('is null for a short link and for no link', () {
      final short = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'join_url': 'https://teams.microsoft.com/meet/2345678?p=abcdef',
      }));
      expect(short.teamsThreadId, isNull);
      expect(
        CalendarEvent.fromToolRow(_timedRow(overrides: {'join_url': ''}))
            .teamsThreadId,
        isNull,
      );
    });
  });

  group('needsResponse', () {
    CalendarEvent row({
      Object? requested = true,
      String status = 'none',
      bool organizer = false,
      bool cancelled = false,
    }) =>
        CalendarEvent.fromToolRow(_timedRow(overrides: {
          'response_requested': requested,
          'response_status': status,
          'is_organizer': organizer,
          'is_cancelled': cancelled,
        }));

    test('the truth table', () {
      expect(row().needsResponse, isTrue);
      expect(row(status: 'notResponded').needsResponse, isTrue);
      // Null is not an explicit "no reply wanted".
      expect(row(requested: null).needsResponse, isTrue);
      expect(row(requested: false).needsResponse, isFalse);
      expect(row(status: 'accepted').needsResponse, isFalse);
      expect(row(status: 'tentativelyAccepted').needsResponse, isFalse);
      expect(row(status: 'declined').needsResponse, isFalse);
      expect(row(status: 'organizer').needsResponse, isFalse);
      expect(row(organizer: true).needsResponse, isFalse);
      expect(row(cancelled: true).needsResponse, isFalse);
    });
  });

  group('the db row', () {
    test('a timed event round-trips', () {
      final e = CalendarEvent.fromToolRow(_timedRow());
      final row = e.toDbRow(syncRun: 'run-1', syncedAt: '2026-09-29T00:00:00.000000Z');

      expect(row['start_utc'], '2026-10-01T16:00:00.000000Z');
      expect(row['end_utc'], '2026-10-01T17:00:00.000000Z');
      expect(row['start_date'], isNull);
      expect(row['is_organizer'], 0);
      expect(row['response_requested'], 1);
      expect(row['sync_run'], 'run-1');
      expect(jsonDecode(row['attendees_json']! as String), hasLength(2));

      final back = CalendarEvent.fromDbRow(row);
      expect(back, e);
      expect(back.hashCode, e.hashCode);
      expect(back.startUtc!.isUtc, isTrue);
    });

    test('an all-day event round-trips with no instants', () {
      final e = CalendarEvent.fromToolRow(_timedRow(overrides: {
        'is_all_day': true,
        'start_date': '2026-12-31',
        'end_date': '2027-01-01',
        'response_requested': null,
        'allow_new_time_proposals': null,
        'is_reminder_on': null,
        'reminder_minutes': null,
      }));
      final row = e.toDbRow(syncRun: 'r', syncedAt: 's');

      expect(row['start_utc'], isNull);
      expect(row['end_utc'], isNull);
      expect(row['start_date'], '2026-12-31');
      expect(row['end_date'], '2027-01-01');
      expect(row['is_all_day'], 1);
      expect(row['response_requested'], isNull);
      expect(row['is_reminder_on'], isNull);

      expect(CalendarEvent.fromDbRow(row), e);
    });

    test('the column names are the table\'s, exactly', () {
      final row = CalendarEvent.fromToolRow(_timedRow())
          .toDbRow(syncRun: 'r', syncedAt: 's');
      expect(row.keys.toList(), [
        'id', 'series_master_id', 'ical_uid', 'event_type', 'subject',
        'location', 'organizer_name', 'organizer_address', 'is_organizer',
        'is_all_day', 'is_cancelled', 'start_utc', 'end_utc', 'start_date',
        'end_date', 'show_as', 'response_status', 'response_requested',
        'allow_new_time_proposals', 'sensitivity', 'join_url', 'web_link',
        'change_key', 'attendees_json', 'categories_json', 'is_reminder_on',
        'reminder_minutes', 'body_preview', 'sync_run', 'synced_at',
      ]);
    });

    test('calendarStamp is MessageStore.isoStamp, byte for byte', () {
      for (final t in [
        DateTime.utc(2026, 10, 1, 16),
        DateTime.utc(2026, 10, 1, 16, 0, 0, 123),
        DateTime.utc(2026, 10, 1, 16, 0, 0, 123, 456),
        DateTime.utc(2000, 1, 1),
        DateTime.fromMicrosecondsSinceEpoch(1790000000123456, isUtc: true),
        DateTime(2026, 3, 8, 2, 30), // a local-time value, converted
      ]) {
        expect(calendarStamp(t), MessageStore.isoStamp(t));
      }
    });
  });

  group('CalendarDate', () {
    test('parses yyyy-mm-dd and nothing else', () {
      expect(CalendarDate.tryParse('2026-10-01'), const CalendarDate(2026, 10, 1));
      expect(CalendarDate.tryParse('2026-10-1'), isNull);
      expect(CalendarDate.tryParse('2026-10-01T00:00:00Z'), isNull);
      expect(CalendarDate.tryParse(''), isNull);
      expect(CalendarDate.tryParse(null), isNull);
      expect(CalendarDate.tryParse('2026-02-30'), isNull);
      expect(CalendarDate.tryParse('2026-13-01'), isNull);
      expect(CalendarDate.tryParse('2028-02-29'), const CalendarDate(2028, 2, 29));
    });

    test('toIso zero-pads', () {
      expect(const CalendarDate(2026, 3, 8).toIso(), '2026-03-08');
    });

    test('addDays crosses month, year and leap-day ends', () {
      expect(const CalendarDate(2026, 1, 31).addDays(1),
          const CalendarDate(2026, 2, 1));
      expect(const CalendarDate(2026, 12, 31).addDays(1),
          const CalendarDate(2027, 1, 1));
      expect(const CalendarDate(2027, 1, 1).addDays(-1),
          const CalendarDate(2026, 12, 31));
      expect(const CalendarDate(2028, 2, 28).addDays(1),
          const CalendarDate(2028, 2, 29));
      expect(const CalendarDate(2028, 2, 29).addDays(1),
          const CalendarDate(2028, 3, 1));
      expect(const CalendarDate(2026, 2, 28).addDays(1),
          const CalendarDate(2026, 3, 1));
      // Across the US spring-forward date: component arithmetic, no 23-hour day.
      expect(const CalendarDate(2026, 3, 7).addDays(2),
          const CalendarDate(2026, 3, 9));
    });

    test('orders and compares', () {
      const a = CalendarDate(2026, 10, 1);
      const b = CalendarDate(2026, 10, 2);
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect(a.compareTo(a), 0);
      expect([b, a]..sort(), [a, b]);
      expect(CalendarDate.ofDateTime(DateTime.utc(2026, 10, 1, 23, 59)), a);
    });
  });

  group('MailboxSettings', () {
    test('reads the tool row and round-trips its cache form', () {
      final s = MailboxSettings.fromToolRow({
        'time_zone': 'Pacific Standard Time',
        'time_zone_iana': 'America/Los_Angeles',
        'working_hours': {
          'days_of_week': ['monday', 'tuesday', 'wednesday'],
          'start_time': '08:30:00',
          'end_time': '17:00:00',
          'time_zone': 'Pacific Standard Time',
          'time_zone_iana': 'America/Los_Angeles',
        },
        'automatic_replies': {'status': 'scheduled'},
        'date_format': '',
        'time_format': '',
      });

      expect(s.timeZone, 'Pacific Standard Time');
      expect(s.timeZoneIana, 'America/Los_Angeles');
      expect(s.workingDays, ['monday', 'tuesday', 'wednesday']);
      expect(s.workingStart, '08:30:00');
      expect(s.workingEnd, '17:00:00');
      expect(s.workingZoneIana, 'America/Los_Angeles');
      expect(s.autoReplyStatus, 'scheduled');

      final cached = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      expect(MailboxSettings.fromJson(cached), s);
    });

    test('a thin answer is empty defaults', () {
      final s = MailboxSettings.fromToolRow({});
      expect(s.timeZoneIana, '');
      expect(s.workingDays, isEmpty);
      expect(s.autoReplyStatus, 'disabled');
    });
  });
}
