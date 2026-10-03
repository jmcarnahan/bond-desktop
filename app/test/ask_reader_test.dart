import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/calendar/ask_reader.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/llm/ask_read_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// The ask reader with no server: one call per message then the stored
/// reading, nothing stored when the model could not answer, and an activity
/// row of counts and enum words only. Fictional mail; Sat Oct 3 2026, 9:40
/// AM in Los Angeles.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late ActivityLog log;
  late CalendarZone la;

  final now = DateTime.utc(2026, 10, 3, 16, 40);

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    log = ActivityLog(store);
  });

  tearDown(() async => db.close());

  Future<void> seedAsk({
    String id = 'm1',
    String body = 'Could we grab dinner on Friday? Thursday also works.',
    String? receivedAt = '2026-09-02T02:34:00Z',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Dinner?',
      'from_name': 'Dana',
      'from_address': 'dana@fabrikam.example',
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  Map<String, dynamic> answer({
    bool asks = true,
    List<String> when = const ['Friday', 'Thursday'],
    String time = '',
    String meal = 'dinner',
  }) =>
      {
        'evidence': 'Dana asks to have dinner.',
        'asks_for_time': asks,
        'when': when,
        'time': time,
        'duration': '',
        'meal': meal,
      };

  AskReader reader(ScriptedLlm llm, {bool enabled = true}) => AskReader(
        store: store,
        client: () => llm,
        log: log,
        zone: () => la,
        clock: () => now,
        enabled: enabled,
      );

  Future<List<Map<String, Object?>>> askRows() async => [
        for (final r in await store.recentActivity())
          if (r['kind'] == 'ask_read') r,
      ];

  test('one call, then the stored reading', () async {
    await seedAsk();
    final llm = ScriptedLlm(answers: {'ask_read': answer()});
    final r = reader(llm);

    final first = await r.readFor('email', 'm1');
    expect(first, isNotNull);
    expect(first!.fromCache, isFalse);
    expect(first.status, 'ready');
    expect(first.read.when, ['Friday', 'Thursday']);
    expect(first.read.meal, AskMeal.dinner);

    final second = await r.readFor('email', 'm1');
    expect(second!.fromCache, isTrue);
    expect(second.status, 'ready');
    expect(second.read, first.read);
    expect(llm.schemaNames, ['ask_read']);

    final row = await store.askReading('email', 'm1');
    expect(row!.status, 'ready');
    expect(row.read!.when, ['Friday', 'Thursday']);
    expect(row.readAt, MessageStore.isoStamp(now));
    // The phrases, never a date.
    final raw = await db
        .customSelect('SELECT read_json FROM ask_readings')
        .getSingle();
    expect(jsonDecode(raw.read<String>('read_json'))['when'],
        ['Friday', 'Thursday']);
  });

  test('a model that cannot be reached: null, and nothing stored', () async {
    await seedAsk();
    final llm = ScriptedLlm(answers: {
      'ask_read': const LlmUnavailableException('not reachable'),
    });
    expect(await reader(llm).readFor('email', 'm1'), isNull);
    expect(llm.schemaNames, ['ask_read']);
    expect(await store.askReading('email', 'm1'), isNull);
    expect(await askRows(), isEmpty);
  });

  test('a bad answer: null, nothing stored, an error row with its type, '
      'and a later call asks again', () async {
    await seedAsk();
    final llm = ScriptedLlm()
      ..scriptFor('ask_read', [
        const LlmFormatException('no JSON'),
        answer(),
      ]);
    final r = reader(llm);
    expect(await r.readFor('email', 'm1'), isNull);
    expect(await store.askReading('email', 'm1'), isNull);
    final rows = await askRows();
    expect(rows, hasLength(1));
    expect(rows.single['status'], 'error');
    expect(jsonDecode(rows.single['detail_json'] as String),
        {'error': 'LlmFormatException'});

    final retry = await r.readFor('email', 'm1');
    expect(retry!.status, 'ready');
    expect(llm.schemaNames, ['ask_read', 'ask_read']);
  });

  test('not asking for a time is stored as none and read back without a '
      'call', () async {
    await seedAsk(body: 'The review was on Friday. Notes attached.');
    final llm = ScriptedLlm(
        answers: {'ask_read': answer(asks: false, when: const ['Friday'])});
    final r = reader(llm);
    final first = await r.readFor('email', 'm1');
    expect(first!.status, 'none');
    expect(first.read.asksForTime, isFalse);
    expect(first.read.when, isEmpty);
    expect((await store.askReading('email', 'm1'))!.status, 'none');

    final again = await reader(llm).readFor('email', 'm1');
    expect(again!.fromCache, isTrue);
    expect(again.status, 'none');
    expect(again.read.asksForTime, isFalse);
    expect(llm.schemaNames, ['ask_read']);
  });

  test('asking with nothing copied is none too', () async {
    await seedAsk(body: 'Can we find a time to talk?');
    final llm = ScriptedLlm(
        answers: {'ask_read': answer(when: const [], meal: 'none')});
    expect((await reader(llm).readFor('email', 'm1'))!.status, 'none');
  });

  test('the activity row carries counts and enum words only', () async {
    await seedAsk();
    final llm = ScriptedLlm(answers: {'ask_read': answer()});
    await reader(llm).readFor('email', 'm1');
    final rows = await askRows();
    expect(rows, hasLength(1));
    expect(rows.single['status'], 'ok');
    final detail = jsonDecode(rows.single['detail_json'] as String) as Map;
    expect(detail, {'status': 'ready', 'when': 2, 'meal': 'dinner'});
    final flat = rows.single.values.join(' ');
    expect(flat, isNot(contains('Friday')));
    expect(flat, isNot(contains('Dana')));
  });

  test('two reads at once make one call', () async {
    await seedAsk();
    final gate = Completer<void>();
    final llm = ScriptedLlm()..scriptFor('ask_read', [gate, answer()]);
    final r = reader(llm);
    final a = r.readFor('email', 'm1');
    final b = r.readFor('email', 'm1');
    gate.complete();
    final results = await Future.wait([a, b]);
    expect(results.every((x) => x?.status == 'ready'), isTrue);
    expect(llm.schemaNames, ['ask_read']);
  });

  test('off: null, and no call', () async {
    await seedAsk();
    final llm = ScriptedLlm.never();
    expect(await reader(llm, enabled: false).readFor('email', 'm1'), isNull);
    expect(llm.calls, isEmpty);
    expect(await store.askReading('email', 'm1'), isNull);
  });

  test('a message that is gone: null, and no call', () async {
    final llm = ScriptedLlm.never();
    expect(await reader(llm).readFor('email', 'nope'), isNull);
    expect(llm.calls, isEmpty);
  });

  test('the model reads the message\'s own words and when it was sent',
      () async {
    await seedAsk(
        body: 'Thursday works for me.\n\n'
            'On Mon, Aug 31, 2026 at 3:15 PM Dana <dana@fabrikam.example> '
            'wrote:\n> How about Friday the 4th?');
    final llm = ScriptedLlm(answers: {'ask_read': answer()});
    await reader(llm).readFor('email', 'm1');
    final user = llm.userMessages.single;
    expect(user, contains('Now: Sat 3 Oct 2026, 9:40 AM PDT '
        '(America/Los_Angeles)'));
    expect(user, contains('Sent: Tue 1 Sep 2026, 7:34 PM PDT'));
    expect(user, contains('Subject: Dinner?'));
    expect(user, contains('Thursday works for me.'));
    expect(user, isNot(contains('Friday the 4th')));
    expect(llm.calls.single.temperature, AskReadTask.temperature);
    expect(llm.calls.single.maxTokens, AskReadTask.maxTokens);
  });

  test('a message with no words at all: null, and no call', () async {
    await store.upsertMessage({
      'source_message_id': 'm3',
      'conversation_key': 'conv-3',
      'direction': 'inbound',
      'subject': '  ',
      'from_address': 'sam@northwind.example',
      'received_at': '2026-10-02T17:00:00Z',
      'body_text': '',
    });
    final llm = ScriptedLlm.never();
    expect(await reader(llm).readFor('email', 'm3'), isNull);
    expect(llm.calls, isEmpty);
    expect(await store.askReading('email', 'm3'), isNull);
  });

  test('a ready row whose phrases do not decode reads as none, without a '
      'call', () async {
    await seedAsk();
    await db.customStatement(
        "INSERT INTO ask_readings (source, source_message_id, status, "
        "read_json, model, read_at) VALUES ('email', 'm1', 'ready', "
        "'{not json', 'm', 'x')");
    final llm = ScriptedLlm.never();
    final r = await reader(llm).readFor('email', 'm1');
    expect(r!.status, 'none');
    expect(r.fromCache, isTrue);
    expect(r.read.asksForTime, isFalse);
    expect(llm.calls, isEmpty);
  });

  test('a store that fails: null, never a throw', () async {
    await seedAsk();
    final llm = ScriptedLlm(answers: {'ask_read': answer()});
    final r = reader(llm);
    await db.close();
    expect(await r.readFor('email', 'm1'), isNull);
    expect(llm.calls, isEmpty);
    // A fresh database for tearDown to close.
    db = testDb();
  });

  test('the preview stands in for a body not yet fetched', () async {
    await store.upsertMessage({
      'source_message_id': 'm2',
      'conversation_key': 'conv-2',
      'direction': 'inbound',
      'subject': 'Coffee',
      'from_address': 'sam@northwind.example',
      'received_at': '2026-10-02T17:00:00Z',
      'body_preview': 'Coffee on Tuesday morning?',
    });
    final llm = ScriptedLlm(answers: {'ask_read': answer()});
    await reader(llm).readFor('email', 'm2');
    expect(llm.userMessages.single, contains('Coffee on Tuesday morning?'));
  });
}
