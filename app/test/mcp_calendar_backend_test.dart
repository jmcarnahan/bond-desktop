import 'dart:convert';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/calendar_errors.dart';
import 'package:bond_inbox/services/backend/unavailable_calendar_backend.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_calendar_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calendar backend over MCP, with only the wire faked.
///
/// What is pinned is the WIRE: the exact tool name and args of every call,
/// with `options` decoded and compared as a map — the server's strict keys
/// refuse an unknown key or a `"true"` where a `true` belongs, and nothing
/// offline would notice either — and the exact exception each refusal code
/// becomes, because the callers route on the type.

/// A scripted client. Duplicated per test file on purpose — a shared fake is a
/// file that can break tests it is not in.
class _FakeMcp implements BondMcpClient {
  /// Per tool: the replies to give, in order. A Map is returned, anything else
  /// is thrown. The last entry is sticky, so a tool called repeatedly with one
  /// scripted answer keeps giving it.
  final Map<String, List<Object>> scripted;

  final List<({String tool, Map<String, Object?> args})> calls = [];
  int closes = 0;

  _FakeMcp([this.scripted = const {}]);

  Map<String, Object?> argsFor(String tool) =>
      calls.firstWhere((c) => c.tool == tool).args;

  /// The `options` arg of the first [tool] call, decoded.
  Map<String, Object?> optionsFor(String tool) =>
      (jsonDecode(argsFor(tool)['options']! as String) as Map)
          .cast<String, Object?>();

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args));
    final queue = scripted[name];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> close() async => closes++;
}

/// An event row as the tools send it — only the keys the tests read.
Map<String, dynamic> _row({
  String id = 'evt-1',
  String startUtc = '2026-10-01T16:00:00Z',
  String endUtc = '2026-10-01T17:00:00Z',
  String changeKey = 'ck-2',
}) =>
    {
      'id': id,
      'subject': 'Design review',
      'start': '2026-10-01T16:00:00.0000000',
      'end': '2026-10-01T17:00:00.0000000',
      'is_all_day': false,
      'start_utc': startUtc,
      'end_utc': endUtc,
      'change_key': changeKey,
      'organizer': 'Dana Reyes',
      'organizer_address': 'dana@contoso.com',
    };

void main() {
  final start = DateTime.utc(2026, 10, 1, 16);
  final end = DateTime.utc(2026, 10, 1, 17);

  group('syncPage', () {
    test('sends the window on a first call and reads the page', () async {
      final mcp = _FakeMcp({
        'sync_calendar': [
          {
            'events': [
              _row(),
              {'subject': 'no id — skipped'},
            ],
            'removed': ['gone-1', ''],
            'cursor': 'https://graph.microsoft.com/v1.0/me/calendarView/delta?x',
            'complete': false,
            'window': {
              'start': '2026-09-01T00:00:00Z',
              'end': '2027-03-01T00:00:00Z',
            },
          },
        ],
      });
      final page = await McpCalendarBackend(mcp).syncPage(
        startUtc: '2026-09-01T00:00:00Z',
        endUtc: '2027-03-01T00:00:00Z',
      );

      expect(mcp.calls.single.tool, 'sync_calendar');
      expect(mcp.calls.single.args, {
        'cursor': '',
        'start_date': '2026-09-01T00:00:00Z',
        'end_date': '2027-03-01T00:00:00Z',
      });
      expect(page.events.map((e) => e.id), ['evt-1']);
      expect(page.removed, ['gone-1']);
      expect(page.cursor, startsWith('https://graph.microsoft.com/'));
      expect(page.complete, isFalse);
      expect(page.windowStart, '2026-09-01T00:00:00Z');
      expect(page.windowEnd, '2027-03-01T00:00:00Z');
    });

    test('a continuation sends the cursor and blank dates', () async {
      final mcp = _FakeMcp({
        'sync_calendar': [
          {
            'events': const [],
            'removed': const [],
            'cursor': 'c2',
            'complete': true,
            'window': {'start': '', 'end': ''},
          },
        ],
      });
      final page = await McpCalendarBackend(mcp).syncPage(cursor: 'c1');

      expect(mcp.argsFor('sync_calendar'),
          {'cursor': 'c1', 'start_date': '', 'end_date': ''});
      expect(page.complete, isTrue);
      expect(page.explicitlyComplete, isTrue);
      expect(page.windowStart, '');
    });

    test('a missing complete key ends the loop but is not explicit', () async {
      final mcp = _FakeMcp({
        'sync_calendar': [
          {
            'events': const [],
            'removed': const [],
            'cursor': 'c2',
          },
        ],
      });
      final page = await McpCalendarBackend(mcp).syncPage(cursor: 'c1');

      expect(page.complete, isTrue);
      expect(page.explicitlyComplete, isFalse);
    });
  });

  group('reads', () {
    test('getEvent', () async {
      final mcp = _FakeMcp({
        'get_calendar_event': [_row()],
      });
      final e = await McpCalendarBackend(mcp).getEvent('evt-1');

      expect(mcp.calls.single.tool, 'get_calendar_event');
      expect(mcp.calls.single.args, {'event_id': 'evt-1', 'options': ''});
      expect(e.startUtc, start);
      expect(e.changeKey, 'ck-2');
    });

    test('mailboxSettings', () async {
      final mcp = _FakeMcp({
        'get_mailbox_settings': [
          {
            'time_zone': 'Pacific Standard Time',
            'time_zone_iana': 'America/Los_Angeles',
            'working_hours': {'days_of_week': ['monday']},
            'automatic_replies': {'status': 'disabled'},
          },
        ],
      });
      final s = await McpCalendarBackend(mcp).mailboxSettings();

      expect(mcp.calls.single.tool, 'get_mailbox_settings');
      expect(mcp.calls.single.args, isEmpty);
      expect(s.timeZone, 'Pacific Standard Time');
      expect(s.workingDays, ['monday']);
    });
  });

  group('respond', () {
    test('sends exactly its keys, and acks with no event', () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {'ok': true, 'id': 'evt-1', 'action': 'respond', 'response': 'accept'},
        ],
      });
      final result = await McpCalendarBackend(mcp)
          .respond('evt-1', response: 'accept', comment: 'See you there');

      final args = mcp.argsFor('manage_event');
      expect(args['action'], 'respond');
      expect(args['event_id'], 'evt-1');
      expect(mcp.optionsFor('manage_event'), {
        'response': 'accept',
        'comment': 'See you there',
        'send_response': true,
      });
      expect(result, isA<EventWriteAck>());
      expect((result as EventWriteAck).id, 'evt-1');
      expect(result.event, isNull);
    });

    test('a proposal and a silent dry run', () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {
            'dry_run': true,
            'method': 'POST',
            'path': '/me/events/evt-1/tentativelyAccept',
            'payload': {'sendResponse': true},
            'notifies': ['Dana@Contoso.com'],
          },
        ],
      });
      final result = await McpCalendarBackend(mcp).respond(
        'evt-1',
        response: 'tentative',
        proposedStartUtc: DateTime.utc(2026, 10, 2, 16),
        proposedEndUtc: DateTime.utc(2026, 10, 2, 17),
        dryRun: true,
      );

      expect(mcp.optionsFor('manage_event'), {
        'response': 'tentative',
        'send_response': true,
        'proposed_new_time': {
          'start': '2026-10-02T16:00:00Z',
          'end': '2026-10-02T17:00:00Z',
        },
        'dry_run': true,
      });
      expect(result, isA<WritePreview>());
      final preview = result as WritePreview;
      expect(preview.method, 'POST');
      expect(preview.path, '/me/events/evt-1/tentativelyAccept');
      expect(preview.payload, {'sendResponse': true});
      expect(preview.notifies, ['dana@contoso.com']);
      expect(preview.ifMatch, isNull);
    });

    test('send_response false goes out as a JSON false', () async {
      final mcp = _FakeMcp();
      await McpCalendarBackend(mcp)
          .respond('evt-1', response: 'decline', sendResponse: false);
      expect(mcp.optionsFor('manage_event'),
          {'response': 'decline', 'send_response': false});
    });

    test('refuses a bad response word or half a proposal locally', () async {
      final mcp = _FakeMcp();
      final backend = McpCalendarBackend(mcp);
      await expectLater(backend.respond('evt-1', response: 'maybe'),
          throwsArgumentError);
      await expectLater(
          backend.respond('evt-1',
              response: 'decline', proposedStartUtc: start),
          throwsArgumentError);
      expect(mcp.calls, isEmpty);
    });

    test('refuses a comment or a proposal that would not be sent', () async {
      final mcp = _FakeMcp();
      final backend = McpCalendarBackend(mcp);
      await expectLater(
          backend.respond('evt-1',
              response: 'decline', comment: 'Sorry', sendResponse: false),
          throwsArgumentError);
      await expectLater(
          backend.respond('evt-1',
              response: 'tentative',
              sendResponse: false,
              proposedStartUtc: start,
              proposedEndUtc: end),
          throwsArgumentError);
      expect(mcp.calls, isEmpty);
    });

    test('refuses a proposal with accept', () async {
      final mcp = _FakeMcp();
      await expectLater(
          McpCalendarBackend(mcp).respond('evt-1',
              response: 'accept', proposedStartUtc: start, proposedEndUtc: end),
          throwsArgumentError);
      expect(mcp.calls, isEmpty);
    });
  });

  group('update', () {
    test('a timed move sends Z instants and if_match; acks the new row',
        () async {
      final mcp = _FakeMcp({
        'manage_event': [_row(changeKey: 'ck-3')],
      });
      final result = await McpCalendarBackend(mcp).update(
        'evt-1',
        ifMatch: 'ck-2',
        startUtc: DateTime.utc(2026, 10, 1, 18, 0, 0, 500),
        endUtc: DateTime.utc(2026, 10, 1, 19),
        subject: 'Design review (moved)',
      );

      expect(mcp.argsFor('manage_event')['action'], 'update');
      expect(mcp.argsFor('manage_event')['event_id'], 'evt-1');
      expect(mcp.optionsFor('manage_event'), {
        'if_match': 'ck-2',
        'start': '2026-10-01T18:00:00Z',
        'end': '2026-10-01T19:00:00Z',
        'subject': 'Design review (moved)',
      });
      final ack = result as EventWriteAck;
      expect(ack.id, 'evt-1');
      expect(ack.event!.changeKey, 'ck-3');
    });

    test('an ack with no UTC pair is unplaced, like a create\'s: the legacy '
        'start/end are never read', () async {
      final mcp = _FakeMcp({
        'manage_event': [_row(startUtc: '', endUtc: '', changeKey: 'ck-3')],
      });
      final result = await McpCalendarBackend(mcp).update(
        'evt-1',
        ifMatch: 'ck-2',
        startUtc: DateTime.utc(2026, 10, 1, 18),
        endUtc: DateTime.utc(2026, 10, 1, 19),
      );
      final ack = result as EventWriteAck;
      expect(ack.id, 'evt-1');
      expect(ack.event, isNull,
          reason: 'the write notes the id and the forced sync brings the row');
    });

    test('an all-day move sends dates and the zone on both sides', () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {
            'dry_run': true,
            'method': 'PATCH',
            'path': '/me/events/evt-1',
            'if_match': 'W/"ck-2"',
            'payload': null,
            'notifies': const [],
          },
        ],
      });
      final result = await McpCalendarBackend(mcp).update(
        'evt-1',
        ifMatch: 'ck-2',
        startDate: const CalendarDate(2026, 10, 5),
        endDate: const CalendarDate(2026, 10, 6),
        allDayZone: 'Pacific Standard Time',
        showAs: 'free',
        dryRun: true,
      );

      expect(mcp.optionsFor('manage_event'), {
        'if_match': 'ck-2',
        'start': '2026-10-05',
        'end': '2026-10-06',
        'start_timezone': 'Pacific Standard Time',
        'end_timezone': 'Pacific Standard Time',
        'show_as': 'free',
        'dry_run': true,
      });
      final preview = result as WritePreview;
      expect(preview.ifMatch, 'W/"ck-2"');
      expect(preview.payload, isNull);
      expect(preview.notifies, isEmpty);
    });

    test('dates without allDayZone, or mixed with instants, are refused',
        () async {
      final mcp = _FakeMcp();
      final backend = McpCalendarBackend(mcp);
      await expectLater(
        backend.update('evt-1',
            ifMatch: 'ck',
            startDate: const CalendarDate(2026, 10, 5),
            endDate: const CalendarDate(2026, 10, 6)),
        throwsArgumentError,
      );
      await expectLater(
        backend.update('evt-1',
            ifMatch: 'ck',
            startUtc: start,
            endUtc: end,
            startDate: const CalendarDate(2026, 10, 5),
            endDate: const CalendarDate(2026, 10, 6),
            allDayZone: 'UTC'),
        throwsArgumentError,
      );
      await expectLater(
        backend.update('evt-1', ifMatch: 'ck', startUtc: start),
        throwsArgumentError,
      );
      expect(mcp.calls, isEmpty);
    });
  });

  group('cancel and delete', () {
    test('cancel sends only its comment', () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {'ok': true, 'id': 'evt-1', 'action': 'cancel'},
        ],
      });
      final result = await McpCalendarBackend(mcp)
          .cancel('evt-1', comment: 'Moving this to next week');

      expect(mcp.argsFor('manage_event'), {
        'action': 'cancel',
        'event_id': 'evt-1',
        'options': jsonEncode({'comment': 'Moving this to next week'}),
      });
      expect((result as EventWriteAck).event, isNull);
    });

    test('a cancel dry run lists everyone it emails', () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {
            'dry_run': true,
            'method': 'POST',
            'path': '/me/events/evt-1/cancel',
            'payload': {'Comment': ''},
            'notifies': ['sam@fabrikam.com', 'lee@contoso.com'],
          },
        ],
      });
      final result =
          await McpCalendarBackend(mcp).cancel('evt-1', dryRun: true);

      expect(mcp.optionsFor('manage_event'), {'dry_run': true});
      expect((result as WritePreview).notifies,
          ['sam@fabrikam.com', 'lee@contoso.com']);
    });

    test('delete sends an empty options object, never a blank string',
        () async {
      final mcp = _FakeMcp({
        'manage_event': [
          {'ok': true, 'id': 'evt-1', 'action': 'delete'},
        ],
      });
      await McpCalendarBackend(mcp).delete('evt-1');
      expect(mcp.argsFor('manage_event'),
          {'action': 'delete', 'event_id': 'evt-1', 'options': '{}'});

      final dry = _FakeMcp();
      await McpCalendarBackend(dry).delete('evt-1', dryRun: true);
      expect(dry.optionsFor('manage_event'), {'dry_run': true});
    });
  });

  group('create', () {
    test('sends UTC wall times, the transaction id and bare addresses',
        () async {
      final mcp = _FakeMcp({
        'create_calendar_event': [
          {
            'ok': true,
            'id': 'new-1',
            'subject': 'Kickoff',
            'start': '2026-10-01T16:00:00.0000000',
            'end': '2026-10-01T17:00:00.0000000',
            'timezone': 'UTC',
            'is_all_day': false,
            'start_utc': '2026-10-01T16:00:00Z',
            'end_utc': '2026-10-01T17:00:00Z',
            'change_key': 'ck-new',
          },
        ],
      });
      final result = await McpCalendarBackend(mcp).create(
        subject: 'Kickoff',
        startUtc: start,
        endUtc: end,
        attendees: ['Dana@Contoso.com', 'sam@fabrikam.com'],
        isOnlineMeeting: true,
        body: 'First look at the plan.',
        transactionId: '0123456789abcdef0123456789abcdef',
      );

      final args = mcp.argsFor('create_calendar_event');
      expect(args['subject'], 'Kickoff');
      expect(args['start_datetime'], '2026-10-01T16:00:00');
      expect(args['end_datetime'], '2026-10-01T17:00:00');
      expect(args['timezone'], 'UTC');
      expect(mcp.optionsFor('create_calendar_event'), {
        'attendees': ['dana@contoso.com', 'sam@fabrikam.com'],
        'is_online_meeting': true,
        'body': 'First look at the plan.',
        'transaction_id': '0123456789abcdef0123456789abcdef',
      });
      final ack = result as EventWriteAck;
      expect(ack.id, 'new-1');
      expect(ack.event!.startUtc, start);
    });

    test('an ack whose UTC re-read failed has no event, not a guessed one',
        () async {
      final mcp = _FakeMcp({
        'create_calendar_event': [
          {
            'ok': true,
            'id': 'new-2',
            // Echoes the request zone; must NOT be read as the instant.
            'start': '2026-10-01T09:00:00.0000000',
            'end': '2026-10-01T10:00:00.0000000',
            'is_all_day': false,
            'start_utc': '',
            'end_utc': '',
          },
        ],
      });
      final result = await McpCalendarBackend(mcp).create(
        subject: 'Solo block',
        startUtc: start,
        endUtc: end,
        transactionId: 'tx-2',
      );

      expect(mcp.optionsFor('create_calendar_event'),
          {'transaction_id': 'tx-2'});
      final ack = result as EventWriteAck;
      expect(ack.id, 'new-2');
      expect(ack.event, isNull);
    });

    test('a dry run previews who gets invited', () async {
      final mcp = _FakeMcp({
        'create_calendar_event': [
          {
            'dry_run': true,
            'method': 'POST',
            'path': '/me/events',
            'payload': {'subject': 'Kickoff'},
            'notifies': ['dana@contoso.com'],
          },
        ],
      });
      final result = await McpCalendarBackend(mcp).create(
        subject: 'Kickoff',
        startUtc: start,
        endUtc: end,
        attendees: ['dana@contoso.com'],
        transactionId: 'tx-3',
        dryRun: true,
      );

      expect(mcp.optionsFor('create_calendar_event'), {
        'attendees': ['dana@contoso.com'],
        'transaction_id': 'tx-3',
        'dry_run': true,
      });
      expect((result as WritePreview).notifies, ['dana@contoso.com']);
    });

    test('a display-name address is refused before the wire', () async {
      final mcp = _FakeMcp();
      final backend = McpCalendarBackend(mcp);
      for (final bad in [
        'Dana Reyes <dana@contoso.com>',
        'dana @contoso.com',
        '<dana@contoso.com>',
        'dana',
        '',
      ]) {
        await expectLater(
          backend.create(
            subject: 'x',
            startUtc: start,
            endUtc: end,
            attendees: [bad],
            transactionId: 'tx',
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(mcp.calls, isEmpty);
    });
  });

  group('findMeetingTimes', () {
    test('sends a CSV, Z bounds with UTC, and reads the suggestions',
        () async {
      final mcp = _FakeMcp({
        'find_meeting_times': [
          {
            'suggestions': [
              {
                'start_utc': '2026-10-02T17:00:00Z',
                'end_utc': '2026-10-02T17:30:00Z',
                'confidence': 100,
                'organizer_availability': 'free',
                'attendees': [
                  {'address': 'Dana@Contoso.com', 'availability': 'free'},
                ],
                'suggestion_reason': 'Suggested because it is one of the '
                    'nearest times when all attendees are available.',
              },
              {'start_utc': '', 'end_utc': ''},
            ],
            'empty_reason': '',
          },
        ],
      });
      final slots = await McpCalendarBackend(mcp).findMeetingTimes(
        attendees: ['dana@contoso.com', 'Sam@Fabrikam.com'],
        durationMinutes: 30,
        windowStartUtc: DateTime.utc(2026, 10, 2, 15),
        windowEndUtc: DateTime.utc(2026, 10, 3, 1),
        maxCandidates: 3,
      );

      expect(mcp.calls.single.tool, 'find_meeting_times');
      expect(mcp.calls.single.args, {
        'attendees': 'dana@contoso.com,sam@fabrikam.com',
        'duration_minutes': 30,
        'window_start': '2026-10-02T15:00:00Z',
        'window_end': '2026-10-03T01:00:00Z',
        'timezone': 'UTC',
        'options': jsonEncode({'max_candidates': 3}),
      });
      expect(slots, hasLength(1));
      expect(slots.single.startUtc, DateTime.utc(2026, 10, 2, 17));
      expect(slots.single.endUtc, DateTime.utc(2026, 10, 2, 17, 30));
      expect(slots.single.confidence, 100.0);
      expect(slots.single.organizerAvailability, 'free');
      expect(slots.single.attendeeAvailability, {'dana@contoso.com': 'free'});
      expect(slots.single.reason, startsWith('Suggested'));
    });

    test('no attendees is refused locally: a self-only search is not a call',
        () async {
      final mcp = _FakeMcp();
      await expectLater(
        McpCalendarBackend(mcp).findMeetingTimes(
          attendees: const [],
          durationMinutes: 60,
          windowStartUtc: start,
          windowEndUtc: end,
        ),
        throwsArgumentError,
      );
      expect(mcp.calls, isEmpty);
    });

    test('the default max_candidates goes out; bad addresses are refused',
        () async {
      final mcp = _FakeMcp({
        'find_meeting_times': [
          {'suggestions': const [], 'empty_reason': 'AttendeesUnavailable'},
        ],
      });
      final backend = McpCalendarBackend(mcp);
      final slots = await backend.findMeetingTimes(
        attendees: ['dana@contoso.com'],
        durationMinutes: 60,
        windowStartUtc: start,
        windowEndUtc: end,
      );
      expect(slots, isEmpty);
      expect(mcp.optionsFor('find_meeting_times'), {'max_candidates': 5});

      await expectLater(
        backend.findMeetingTimes(
          attendees: ['Sam Ortiz <sam@fabrikam.com>'],
          durationMinutes: 30,
          windowStartUtc: start,
          windowEndUtc: end,
        ),
        throwsArgumentError,
      );
      expect(mcp.calls, hasLength(1));
    });
  });

  group('errors', () {
    Future<Object?> failureOf(Map<String, dynamic> reply) async {
      final mcp = _FakeMcp({
        'get_calendar_event': [reply],
      });
      try {
        await McpCalendarBackend(mcp).getEvent('evt-1');
      } on Object catch (e) {
        return e;
      }
      return null;
    }

    test('each refusal code becomes its type', () async {
      final expected = <String, Matcher>{
        'calendar_scope_missing': isA<CalendarScopeMissing>(),
        'mailbox_settings_scope_missing': isA<CalendarScopeMissing>(),
        'cursor_expired': isA<CalendarCursorExpired>(),
        'invalid_cursor': isA<CalendarCursorExpired>(),
        'event_changed': isA<CalendarEventChanged>(),
        'not_organizer': isA<CalendarNotOrganizer>(),
        'not_found': isA<CalendarEventGone>(),
        'not_connected': isA<ReconsentRequired>(),
        'html_body_readonly': isA<CalendarRefused>()
            .having((e) => e.code, 'code', 'html_body_readonly'),
        'unsupported_account': isA<CalendarRefused>()
            .having((e) => e.code, 'code', 'unsupported_account'),
        'invalid_options': isA<CalendarRefused>()
            .having((e) => e.reason, 'reason', 'Unknown key.'),
      };
      for (final entry in expected.entries) {
        final failure = await failureOf({
          'error': entry.key,
          'reason': 'Unknown key.',
        });
        expect(failure, entry.value, reason: entry.key);
      }
    });

    test('a missing mailbox-settings grant names that permission', () async {
      expect(
        await failureOf({'error': 'mailbox_settings_scope_missing'}),
        isA<CalendarScopeMissing>().having(
            (e) => e.message, 'message', contains('mailbox settings')),
      );
      expect(
        await failureOf({'error': 'calendar_scope_missing'}),
        isA<CalendarScopeMissing>().having(
            (e) => e.message, 'message', contains('calendar permission')),
      );
    });

    test('an empty error string is not a refusal', () async {
      expect(await failureOf({..._row(), 'error': ''}), isNull);
    });

    test('a tool error and a transport failure are transient', () async {
      final tool = _FakeMcp({
        'sync_calendar': [const McpToolException('Graph API error 429')],
      });
      await expectLater(
        McpCalendarBackend(tool).syncPage(),
        throwsA(isA<CalendarTransient>()
            .having((e) => e.message, 'message', 'Graph API error 429')
            .having((e) => e.statusCode, 'statusCode', isNull)),
      );

      final transport = _FakeMcp({
        'manage_event': [
          const McpTransportException('server unreachable', statusCode: 503),
        ],
      });
      await expectLater(
        McpCalendarBackend(transport).delete('evt-1'),
        throwsA(isA<CalendarTransient>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('messages are for a person and are what toString says', () {
      const refused = CalendarRefused('invalid_options', 'Bad key.');
      expect(refused.toString(), refused.message);
      expect(const CalendarScopeMissing().toString(),
          contains('calendar permission'));
    });
  });

  group('UnavailableCalendarBackend', () {
    test('every method says the calendar needs the server connection',
        () async {
      const backend = UnavailableCalendarBackend();
      final isUnavailable = throwsA(isA<CalendarUnavailable>().having(
        (e) => e.sentence,
        'sentence',
        'The calendar needs the Bond server connection (Settings › Connection).',
      ));
      await expectLater(backend.syncPage(), isUnavailable);
      await expectLater(backend.getEvent('x'), isUnavailable);
      await expectLater(backend.mailboxSettings(), isUnavailable);
      await expectLater(backend.respond('x', response: 'accept'), isUnavailable);
      await expectLater(backend.update('x', ifMatch: 'k'), isUnavailable);
      await expectLater(backend.cancel('x'), isUnavailable);
      await expectLater(backend.delete('x'), isUnavailable);
      await expectLater(
        backend.create(
            subject: 's', startUtc: start, endUtc: end, transactionId: 't'),
        isUnavailable,
      );
      await expectLater(
        backend.findMeetingTimes(
          attendees: const [],
          durationMinutes: 30,
          windowStartUtc: start,
          windowEndUtc: end,
        ),
        isUnavailable,
      );
    });
  });
}
