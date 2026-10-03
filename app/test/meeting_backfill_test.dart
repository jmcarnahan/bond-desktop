import 'dart:convert';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_mail_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The `meeting_detail_backfill` one-shot: MCP rows fetched before
/// `read_email` sent the meeting fields are re-fetched once, bounded, and
/// only after the calendar mirror's first full read has been swept.
///
/// What is pinned: which rows are candidates (the store query), the gate on
/// the mirror, that the loop fetches exactly the candidates and stores what
/// came back, that the pref closes after a clean loop or the third failed
/// one, and the cap.

/// A scripted MCP client. Duplicated per test file on purpose — a shared fake
/// is a file that can break tests it is not in. `read_email` answers per id
/// through [readEmail]; a throw from it is thrown to the caller. Every other
/// tool answers an empty drain.
class _FakeMcp implements BondMcpClient {
  Map<String, dynamic> Function(String id) readEmail;

  final List<({String tool, Map<String, Object?> args})> calls = [];

  _FakeMcp(this.readEmail);

  List<String> get readIds => [
        for (final c in calls)
          if (c.tool == 'read_email') c.args['message_id'] as String,
      ];

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args));
    if (name == 'read_email') {
      return readEmail(args['message_id'] as String);
    }
    if (name == 'sync_mail') {
      return {'messages': <Object>[], 'delta_cursor': 'cursor-${args['folder']}'};
    }
    return <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
}

/// Seconds-precision UTC, the shape Graph and the MCP server stamp mail in.
String ago(Duration d) => DateTime.now()
    .toUtc()
    .subtract(d)
    .toIso8601String()
    .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

/// A completed, swept first read — what opens the backfill's gate.
const String _sweptRun = '{"start":"2026-01-01T00:00:00Z",'
    '"end":"2026-06-01T00:00:00Z","run":"x","swept":true}';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> message(
    String id, {
    String subject = 'Lunch on Friday?',
    String direction = 'inbound',
    Duration age = const Duration(hours: 3),
    String? meta,
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': direction,
      'from_address': 'colleague@contoso.com',
      'subject': subject,
      'received_at': ago(age),
      'source_meta_json': ?meta,
    });
  }

  Future<void> mirror(List<String> subjects) async {
    await CalendarStore(db).upsertEvents(
      [
        for (var i = 0; i < subjects.length; i++)
          CalendarEvent(id: 'evt-$i', subject: subjects[i]),
      ],
      syncRun: 'run-1',
    );
  }

  String since() => ago(const Duration(days: 30));

  group('meetingBackfillCandidates', () {
    test('takes response prefixes and mirrored subjects, and nothing else',
        () async {
      await mirror(['Quarterly Planning Review', '']);
      await message('accepted', subject: 'Accepted: Weekly sync');
      await message('tentative',
          subject: 'Tentatively accepted: Weekly sync');
      await message('cancelled', subject: 'Cancelled: Offsite');
      await message('proposed', subject: 'new time proposed: Offsite');
      await message('invite', subject: '  quarterly PLANNING review ');
      await message('plain', subject: 'Lunch on Friday?');
      await message('known',
          subject: 'Declined: Weekly sync',
          meta: '{"meeting":"meetingDeclined"}');
      await message('outbound',
          subject: 'Accepted: Weekly sync', direction: 'outbound');
      await message('old',
          subject: 'Accepted: Weekly sync', age: const Duration(days: 40));
      await message('headers-only',
          subject: 'Canceled: Standup',
          meta: '{"headers":{"x-mailer":"Outlook"}}');

      final ids = await store.meetingBackfillCandidates(sinceIso: since());

      expect(ids.toSet(), {
        'accepted',
        'tentative',
        'cancelled',
        'proposed',
        'invite',
        'headers-only',
      });
    });

    test('an empty mirrored subject matches no empty mail subject', () async {
      await mirror(['']);
      await message('blank', subject: '');

      expect(await store.meetingBackfillCandidates(sinceIso: since()), isEmpty);
    });

    test('newest first, and the limit is respected', () async {
      for (var i = 0; i < 5; i++) {
        await message('m$i',
            subject: 'Accepted: Sync $i', age: Duration(hours: i + 1));
      }

      final ids =
          await store.meetingBackfillCandidates(sinceIso: since(), limit: 3);

      expect(ids, ['m0', 'm1', 'm2']);
    });

    test('a malformed blob does not throw, and reads as no meeting key',
        () async {
      await message('bad', subject: 'Accepted: Sync', meta: '{not json');

      expect(await store.meetingBackfillCandidates(sinceIso: since()),
          ['bad']);
    });
  });

  group('calendarMirrored', () {
    test('true once the first full read has been swept', () async {
      await store.setPref(calendarRunKey, _sweptRun);
      expect(await store.calendarMirrored(), isTrue);
    });

    test('false with no run state, even with a calendar cursor', () async {
      expect(await store.calendarMirrored(), isFalse);
      await store.setDeltaLink('primary', 'calendar-cursor',
          source: 'calendar');
      expect(await store.calendarMirrored(), isFalse);
    });

    test('false while the first read is still under way', () async {
      await store.setPref(
          calendarRunKey, _sweptRun.replaceFirst('true', 'false'));
      expect(await store.calendarMirrored(), isFalse);
    });

    test('false on malformed or non-object state', () async {
      await store.setPref(calendarRunKey, '{not json');
      expect(await store.calendarMirrored(), isFalse);
      await store.setPref(calendarRunKey, '[true]');
      expect(await store.calendarMirrored(), isFalse);
    });
  });

  group('the one-shot', () {
    Map<String, dynamic> meetingReply(String id) => {
          'body_text': '',
          'has_attachments': false,
          'meeting_message_type':
              id.startsWith('invite') ? 'meetingRequest' : 'meetingAccepted',
          'event_id': 'evt-for-$id',
        };

    SyncService syncOver(_FakeMcp mcp) => SyncService(
          McpMailBackend(mcp),
          store,
          activityLog: ActivityLog(store),
        );

    Future<Map<String, dynamic>> lastSyncMailDetail() async {
      final rows = await db
          .customSelect(
            "SELECT detail_json FROM activity_events WHERE kind = 'sync_mail' "
            'ORDER BY id DESC LIMIT 1',
          )
          .get();
      final raw = rows.first.data['detail_json'] as String?;
      return raw == null
          ? const {}
          : jsonDecode(raw) as Map<String, dynamic>;
    }

    test('waits for the mirror, then fetches exactly the candidates once',
        () async {
      await mirror(['Design Review']);
      await message('accepted', subject: 'Accepted: Weekly sync');
      await message('invite', subject: 'Design Review');
      await message('plain', subject: 'Lunch on Friday?');
      final mcp = _FakeMcp(meetingReply);
      final sync = syncOver(mcp);

      // No full read yet: nothing fetched, and the shot is not spent.
      await sync.syncNow();
      expect(mcp.readIds, isEmpty);
      expect(await store.getPref('meeting_detail_backfill'), isNull);

      await store.setPref(calendarRunKey, _sweptRun);
      await sync.syncNow();

      expect(mcp.readIds.toSet(), {'accepted', 'invite'});
      expect(mcp.readIds, hasLength(2));
      expect(await store.getPref('meeting_detail_backfill'), '1');

      final accepted = (await store.loadThread('conv-accepted',
              sources: const ['email']))
          .single;
      expect(accepted.meetingMessageType, 'meetingAccepted');
      expect(accepted.meetingEventId, 'evt-for-accepted');
      // The re-gate after the loop read the kind just stored.
      final acceptedRow = (await store.getMessageRow('email', 'accepted'))!;
      expect(acceptedRow['gate_reason'], 'meeting_response');
      // An invitation is a genuine ask and is never gated by that rule.
      final inviteRow = (await store.getMessageRow('email', 'invite'))!;
      expect(inviteRow['gate_reason'], isNot('meeting_response'));
      expect(
        (await CalendarStore(db).messagesForEvent('evt-for-invite'))
            .map((r) => r.sourceMessageId),
        ['invite'],
      );

      final detail = await lastSyncMailDetail();
      expect(detail['backfilled_meetings'], 2);

      // Closed: a later pass fetches nothing and reports nothing.
      mcp.calls.clear();
      await sync.syncNow();
      expect(mcp.readIds, isEmpty);
      final named = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM activity_events WHERE kind = 'sync_mail' "
            "AND detail_json LIKE '%backfilled_meetings%'",
          )
          .getSingle();
      expect((named.data['n'] as num).toInt(), 1,
          reason: 'exactly one sync_mail row ever names the backfill');
    });

    test('a transient failure mid-loop stops it and leaves the shot owed',
        () async {
      await store.setPref(calendarRunKey, _sweptRun);
      for (var i = 0; i < 3; i++) {
        await message('m$i',
            subject: 'Accepted: Sync $i', age: Duration(hours: i + 1));
      }
      var fail = true;
      final mcp = _FakeMcp((id) {
        if (id == 'm1' && fail) {
          throw const McpToolException(
              'Graph API error 503 (ServiceUnavailable): x');
        }
        return meetingReply(id);
      });
      final sync = syncOver(mcp);

      // The pass itself stays healthy.
      await expectLater(sync.syncNow(), completes);
      expect(mcp.readIds, ['m0', 'm1'],
          reason: 'the loop stops at the first throw');
      expect(await store.getPref('meeting_detail_backfill'), 'attempt:1');

      fail = false;
      mcp.calls.clear();
      await sync.syncNow();
      // m0 now has its `meeting` key and is no longer a candidate.
      expect(mcp.readIds, ['m1', 'm2']);
      expect(await store.getPref('meeting_detail_backfill'), '1');
    });

    test('three failing passes close it', () async {
      await store.setPref(calendarRunKey, _sweptRun);
      await message('m0', subject: 'Accepted: Sync');
      final mcp = _FakeMcp((id) => throw const McpToolException(
          'Graph API error 503 (ServiceUnavailable): x'));
      final sync = syncOver(mcp);

      await sync.syncNow();
      expect(await store.getPref('meeting_detail_backfill'), 'attempt:1');
      await sync.syncNow();
      expect(await store.getPref('meeting_detail_backfill'), 'attempt:2');
      await sync.syncNow();
      expect(await store.getPref('meeting_detail_backfill'), '1');
      expect(mcp.readIds, ['m0', 'm0', 'm0']);

      mcp.calls.clear();
      await sync.syncNow();
      expect(mcp.readIds, isEmpty, reason: 'closed: never asked again');
    });

    test('a failing pass then a clean one closes it', () async {
      await store.setPref(calendarRunKey, _sweptRun);
      await message('m0', subject: 'Accepted: Sync');
      var fail = true;
      final mcp = _FakeMcp((id) {
        if (fail) {
          throw const McpToolException(
              'Graph API error 503 (ServiceUnavailable): x');
        }
        return meetingReply(id);
      });
      final sync = syncOver(mcp);

      await sync.syncNow();
      expect(await store.getPref('meeting_detail_backfill'), 'attempt:1');
      fail = false;
      await sync.syncNow();
      expect(await store.getPref('meeting_detail_backfill'), '1');
      expect(mcp.readIds, ['m0', 'm0']);
    });

    test('is bounded at 200 read_email calls, newest first', () async {
      await store.setPref(calendarRunKey, _sweptRun);
      for (var i = 0; i < 201; i++) {
        await message('m${i.toString().padLeft(3, '0')}',
            subject: 'Accepted: Sync $i', age: Duration(minutes: i + 1));
      }
      final mcp = _FakeMcp(meetingReply);

      await syncOver(mcp).syncNow();

      expect(mcp.readIds, hasLength(200));
      expect(mcp.readIds, isNot(contains('m200')),
          reason: 'the oldest is the one left out');
      expect(await store.getPref('meeting_detail_backfill'), '1');
    });
  });
}
