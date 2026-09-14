import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/golden_run.dart';
import 'fixtures/golden_set.dart';

/// The golden loader and run-file writer, against a FICTIONAL golden-shaped
/// fixture.
///
/// The real set is a hundred real messages and never enters this repo, so the
/// thing these tests pin is the SHAPE: that an item rebuilds into the message
/// the app would have rendered, that the context rungs carry what they claim,
/// and that a run file lands in exactly the shape `golden/tools/score_run.py`
/// reads. A change that breaks any of those breaks every accuracy number the
/// bakeoff quotes, silently, on a machine that has the real set.
///
/// The fixture pins absolute dates on purpose — `now` is a fact the set
/// records so that `deadline` and `urgency` labels cannot rot as the wall
/// clock moves, which is the opposite of the usual rule about literal dates in
/// fixtures.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';
  const registryPath = 'test/fixtures/golden_registry_fixture.json';

  late GoldenSet set;
  late Map<String, GoldenItem> byId;
  late Directory tmp;

  setUp(() {
    set = GoldenSet.fromJson(
      jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>,
    );
    byId = set.byId;
    tmp = Directory.systemTemp.createTempSync('golden-run-test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  // ── the round trip that says the replay sends the real prompt ─────────
  group('a rebuilt message renders what the set recorded', () {
    for (final id in const [
      'email:fx-keep-tail',
      'teams:fx-floor',
      'email:fx-drop-notification',
      'email:fx-outbound',
      'email:fx-reply',
      'email:fx-attachments-long',
      'teams:fx-empty-body',
    ]) {
      test(id, () {
        final item = byId[id]!;
        expect(item.blockMatches, isTrue, reason: 'the block drifted');
        expect(item.directnessMatches, isTrue,
            reason: 'the directness line drifted');
      });
    }
  });

  test('a chat block carries no subject line', () {
    expect(byId['teams:fx-floor']!.messageBlock, isNot(contains('Subject:')));
    expect(
      byId['email:fx-keep-tail']!.messageBlock,
      contains('Subject: Re: Addendum for the River Street suite'),
    );
  });

  test('a body past the prompt cap is clipped to 4000 characters', () {
    final item = byId['email:fx-attachments-long']!;
    expect(item.message.bodyText!.length, 4000);
    expect(item.blockMatches, isTrue);
  });

  // ── the set as a whole ────────────────────────────────────────────────
  test('the fixture holds seven items, four of them gold-keep', () {
    expect(set.items.length, 7);
    expect(
      set.keep.map((item) => item.id),
      containsAll(const [
        'email:fx-keep-tail',
        'teams:fx-floor',
        'email:fx-reply',
        'email:fx-attachments-long',
      ]),
    );
    expect(set.keep.length, 4);
    expect(set.generated, isNotEmpty);
  });

  test('byId finds an item by the id the scorer joins on', () {
    expect(byId.length, 7);
    expect(byId['email:fx-reply']!.stratum, 'triage-spread');
    expect(byId['email:fx-attachments-long']!.difficulty, 'hard');
  });

  // ── the thread ────────────────────────────────────────────────────────
  test('the tail keeps its order, oldest first', () {
    final tail = byId['email:fx-keep-tail']!.tail;
    expect(tail.length, 3);
    expect(tail.map((m) => m.fromName),
        ['Dana Whitfield', 'You', 'Dana Whitfield']);
  });

  test("the owner's own line in a tail is outbound", () {
    final tail = byId['email:fx-keep-tail']!.tail;
    expect(tail[1].outbound, isTrue);
    expect(tail[0].outbound, isFalse);
    expect(tail[2].outbound, isFalse);
  });

  test('tail messages are numbered off the item id', () {
    expect(
      byId['email:fx-keep-tail']!.tail.map((m) => m.id),
      ['email:fx-keep-tail#t0', 'email:fx-keep-tail#t1', 'email:fx-keep-tail#t2'],
    );
  });

  test('the none rung shows the message alone', () {
    expect(byId['email:fx-keep-tail']!.threadFor(GoldenCtx.none), isEmpty);
  });

  test('the tail3 rung is the tail itself', () {
    final item = byId['email:fx-keep-tail']!;
    expect(item.threadFor(GoldenCtx.tail3), same(item.tail));
  });

  test('the compressed rung leads with the digest', () {
    final item = byId['email:fx-keep-tail']!;
    final thread = item.threadFor(GoldenCtx.compressed);
    expect(thread.first.fromName, 'Earlier in this thread');
    expect(thread.first.id, 'email:fx-keep-tail#digest');
    expect(thread.first.outbound, isFalse);
    expect(thread.first.bodyText, item.digest);
    expect(thread.first.receivedAt, '2026-08-19');
  });

  test('the compressed rung fits the three-message window the readers keep',
      () {
    // Triage and needs-you read the LAST three thread messages. A fourth
    // message would cost the oldest one — the digest — and the rung would
    // silently score as tail3. So the digest plus the two newest tail
    // messages is the whole thread, in order.
    final item = byId['email:fx-keep-tail']!;
    expect(item.tail.length, 3, reason: 'the fixture item carries a full tail');
    final thread = item.threadFor(GoldenCtx.compressed);
    expect(thread.length, 3);
    expect(
      thread.skip(1).map((m) => m.id),
      item.tail.skip(1).map((m) => m.id),
    );
    // A short tail loses nothing.
    final short = byId['email:fx-reply']!;
    expect(short.tail.length, lessThan(3));
    expect(
      short.threadFor(GoldenCtx.compressed).length,
      short.digest == null ? short.tail.length : short.tail.length + 1,
    );
  });

  test('an item with no digest falls back to its tail at the compressed rung',
      () {
    final item = byId['email:fx-reply']!;
    expect(item.digest, isNull);
    expect(item.tail, hasLength(1));
    expect(item.threadFor(GoldenCtx.compressed).map((m) => m.id),
        item.tail.map((m) => m.id));
  });

  test('an empty body round-trips without an attachment stand-in', () {
    // `buildMessageBlock` substitutes a sentence about the files when a message
    // has no words — but only from HYDRATED attachments, which a rebuilt item
    // never has. So the block ends at the `Body:` line, and the loader that
    // reads the body back out of it must produce the same nothing.
    final item = byId['teams:fx-empty-body']!;
    expect(item.message.bodyText, isEmpty);
    expect(item.message.attachments, isEmpty);
    expect(item.messageBlock, endsWith('\n\nBody:\n'));
    expect(item.blockMatches, isTrue);
    expect(item.messageBlock, isNot(contains('Shared a file')));
    expect(item.messageBlock, isNot(contains('Shared an image')));
    // The names are still carried: triage reads them beside the block.
    expect(item.attachmentRows, [
      {'name': 'elevation-sketch.png', 'size': 0, 'is_inline': 0},
    ]);
    expect(item.gold.gateVerdict, 'drop');
  });

  // ── the packed day ────────────────────────────────────────────────────
  test('now is the local day the item was packed', () {
    final now = byId['email:fx-keep-tail']!.now;
    expect(now, DateTime(2026, 9, 9));
    expect(now.isUtc, isFalse);
  });

  test('an item whose packed day is unreadable stops the load', () {
    // Never the wall clock: a `deadline` label written for one day, scored on
    // another, is a wrong answer nothing would report.
    final raw = jsonDecode(File(fixturePath).readAsStringSync())
        as Map<String, dynamic>;
    final item = Map<String, dynamic>.from(
        (raw['items'] as List).first as Map<String, dynamic>);
    item['stage_input'] = Map<String, dynamic>.from(
        item['stage_input'] as Map<String, dynamic>)
      ..['now'] = 'sometime';
    expect(
      () => GoldenItem.fromJson(item),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('email:fx-keep-tail'))
          .having((e) => e.message, 'message', contains('sometime'))),
    );
  });

  // ── attachments ───────────────────────────────────────────────────────
  test('attachment names become the rows a triage prompt takes', () {
    expect(byId['email:fx-attachments-long']!.attachmentRows, [
      {'name': 'north-elevation-survey.pdf', 'size': 0, 'is_inline': 0},
      {'name': 'summary-sheet.xlsx', 'size': 0, 'is_inline': 0},
    ]);
  });

  test('a message with nothing attached has no rows', () {
    expect(byId['email:fx-keep-tail']!.attachmentRows, isEmpty);
  });

  // ── the needs-you floor ───────────────────────────────────────────────
  test('a chat sender is a name and no address', () {
    final item = byId['teams:fx-floor']!;
    expect(item.message.fromAddress, isNull);
    expect(item.message.fromName, 'Noor Haddad');
    expect(item.message.subject, isNull);
  });

  test('an inbound chat that names the owner reaches the floor', () {
    final item = byId['teams:fx-floor']!;
    expect(item.addressedMe, isTrue);
    expect(item.floorSaysYes, isTrue);
  });

  test('mail addressed only to the owner does not reach the floor', () {
    final item = byId['email:fx-reply']!;
    expect(item.addressedMe, isTrue);
    expect(item.floorSaysYes, isFalse);
  });

  // ── direction, recipients, read state ─────────────────────────────────
  test("the owner's own mail is outbound", () {
    final item = byId['email:fx-outbound']!;
    expect(item.direction, 'outbound');
    expect(item.message.outbound, isTrue);
    expect(item.gold.gateVerdict, 'drop');
  });

  test('the envelope count becomes that many empty recipients', () {
    expect(byId['email:fx-keep-tail']!.message.to, hasLength(3));
    expect(byId['email:fx-keep-tail']!.message.isRead, isFalse);
    expect(byId['email:fx-drop-notification']!.message.isRead, isTrue);
  });

  // ── gold ──────────────────────────────────────────────────────────────
  test('gold carries what the harness picks populations with', () {
    final gold = byId['email:fx-keep-tail']!.gold;
    expect(gold.gateVerdict, 'keep');
    expect(gold.storylineId, 'river-office-lease');
    expect(gold.storylineStrength, 'must');
    expect(gold.storylineForbidden,
        ['ANTI-person-hub', 'studio-website-redesign']);
    expect(gold.hasReply, isTrue);
    expect(gold.replyExpected, isTrue);
    expect(gold.needsYou, isTrue);
    expect(gold.annotatorAgreement, '2/2');
  });

  test('gold records which context rung each stage needs', () {
    final gold = byId['email:fx-keep-tail']!.gold;
    expect(gold.derivableFrom['triage'], 'ctx_tail3');
    expect(gold.derivableFrom['extract'], 'ctx_none');
    expect(gold.derivableFrom['needs_you'], 'ctx_none');
    expect(gold.derivableFrom['storyline'], 'ctx_tail3');
  });

  test('an item nobody files reads as no storyline, not as no answer', () {
    expect(byId['teams:fx-floor']!.gold.storylineId, 'none');
    expect(byId['email:fx-attachments-long']!.gold.hasReply, isFalse);
    expect(byId['email:fx-attachments-long']!.gold.annotatorAgreement, '1/2');
  });

  test('the whole gold block is kept for callers this class does not serve',
      () {
    final raw = byId['email:fx-keep-tail']!.gold.raw;
    expect(raw['thread_state'], 'needs_reply');
    expect((raw['triage'] as Map)['deadline'], 'Friday');
  });

  test("the app's stored output is carried through untouched", () {
    final stored = byId['email:fx-drop-notification']!.stored;
    expect(stored['triage_status'], 'skipped');
    expect(stored['gate_reason'], 'newsletter');
    expect(stored['category'], isNull);
  });

  test('the conversation card fields survive the load', () {
    final item = byId['email:fx-keep-tail']!;
    expect(item.conversationSubject, 'Addendum for the River Street suite');
    expect(item.conversationParticipants,
        ['Dana Whitfield', 'Alex Rivera', 'Priya Raman']);
    expect(item.conversationKey, 'email:fx-conv-lease');
  });

  // ── the ctx knob ──────────────────────────────────────────────────────
  test('parseGoldenCtx reads the three rungs in any case', () {
    expect(parseGoldenCtx('none'), GoldenCtx.none);
    expect(parseGoldenCtx('TAIL3'), GoldenCtx.tail3);
    expect(parseGoldenCtx(' Compressed '), GoldenCtx.compressed);
  });

  test('parseGoldenCtx refuses a rung nobody defined', () {
    expect(
      () => parseGoldenCtx('tail'),
      throwsA(isA<ArgumentError>()
          .having((e) => e.name, 'name', contains('GOLDEN_CTX'))),
    );
    expect(() => parseGoldenCtx(''), throwsA(isA<ArgumentError>()));
  });

  // ── loading ───────────────────────────────────────────────────────────
  test('loadGoldenSet reads a set off disk', () async {
    final loaded = await loadGoldenSet(fixturePath);
    expect(loaded.items, hasLength(7));
    expect(loaded.byId.keys, containsAll(byId.keys));
  });

  test('loadGoldenSet says where it looked when the file is not there',
      () async {
    final missing = '${tmp.path}${Platform.pathSeparator}not-here.json';
    await expectLater(
      loadGoldenSet(missing),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains(missing))),
    );
  });

  test('loadGoldenSet refuses a file that is not a golden set', () async {
    final wrong = File('${tmp.path}${Platform.pathSeparator}wrong.json')
      ..writeAsStringSync('{"generated": "2026-09-14"}');
    await expectLater(
      loadGoldenSet(wrong.path),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('items'))),
    );
  });

  // ── the run file ──────────────────────────────────────────────────────
  test('a full entry emits every section the scorer reads', () {
    final entry = _fullEntry();
    final json = entry.toScoreRunJson();

    expect(json['id'], 'email:fx-keep-tail');
    expect(json['stratum'], 'storyline-core');
    expect(json['difficulty'], 'easy');
    expect(json['triage'], {
      'category': 'work',
      'urgency': 'normal',
      'needs_action': true,
      'reply_expected': true,
      'deadline': 'Friday',
      'label': 'lease addendum',
      'summary': 'The allowance is capped.',
      'action_items': ['Answer by Friday'],
    });
    expect(json['extract'], {
      'intent': 'request',
      'importance': 'high',
      'project': 'River Street office',
      'topics': ['allowance'],
      'people': ['Dana Whitfield'],
      'organizations': ['Harbor Lane'],
      'evidence': 'capped at 18,000',
    });
    expect(json['needs_you'], {
      'verdict': true,
      'confidence': 'high',
      'evidence': 'A direct question.',
      'floor': false,
    });
    expect(json['storyline'], {'id': 'river-office-lease'});
    expect(json['draft'], {
      'body': 'Yes, that works.',
      'options': ['shorter'],
      'evidence': 'the capped allowance',
    });
  });

  test('a claimed absence of a deadline is an empty string, never null', () {
    final entry = GoldenRunEntry(
      id: 'email:fx-reply',
      stratum: 'triage-spread',
      difficulty: 'medium',
    )..triage = const GoldenTriageOut(
        category: 'work',
        urgency: 'normal',
        needsAction: true,
        replyExpected: true,
        deadline: '',
        label: 'addendum question',
        summary: 'A yes or no is wanted.',
      );
    final triage = entry.toScoreRunJson()['triage'] as Map<String, Object?>;
    expect(triage['deadline'], '');
    expect(triage.containsKey('deadline'), isTrue);
    expect(triage['action_items'], isEmpty);
  });

  test('a prose entry scores its reply decision as triage.reply_expected', () {
    final entry = GoldenRunEntry(
      id: 'email:fx-reply',
      stratum: 'triage-spread',
      difficulty: 'medium',
    )..decision = const GoldenDecisionOut(
        needsReply: true,
        reason: 'The sender asks a direct question.',
      );
    final json = entry.toScoreRunJson();
    expect(json['triage'], {'reply_expected': true});
    expect(json['decision'], {
      'needs_reply': true,
      'reason': 'The sender asks a direct question.',
    });
  });

  test('a triage section wins over a decision for the triage key', () {
    final entry = _fullEntry()
      ..decision = const GoldenDecisionOut(needsReply: false);
    final triage = entry.toScoreRunJson()['triage'] as Map<String, Object?>;
    expect(triage['reply_expected'], isTrue);
    expect(triage['category'], 'work');
  });

  test('a stage that never ran is absent, not null', () {
    final json = GoldenRunEntry(
      id: 'email:fx-outbound',
      stratum: 'thread-recap',
      difficulty: 'easy',
    ).toScoreRunJson();
    expect(json.keys, ['id', 'stratum', 'difficulty']);
    for (final key in const [
      'triage',
      'extract',
      'needs_you',
      'storyline',
      'decision',
      'draft',
      'calls',
    ]) {
      expect(json.containsKey(key), isFalse, reason: '$key must be absent');
    }
  });

  test('a floor answer states no confidence at all', () {
    final entry = GoldenRunEntry(
      id: 'teams:fx-floor',
      stratum: 'needsyou-hard',
      difficulty: 'medium',
    )..needsYou = const GoldenNeedsYouOut(
        verdict: true,
        evidence: 'teams_direct',
        floor: true,
      );
    final needsYou =
        entry.toScoreRunJson()['needs_you'] as Map<String, Object?>;
    expect(needsYou.containsKey('confidence'), isFalse);
    expect(needsYou['floor'], isTrue);
    expect(needsYou['verdict'], isTrue);
  });

  test('an abstention is a storyline of none, not a missing storyline', () {
    final entry = GoldenRunEntry(
      id: 'teams:fx-floor',
      stratum: 'needsyou-hard',
      difficulty: 'medium',
    )..storylineId = 'none';
    expect(entry.toScoreRunJson()['storyline'], {'id': 'none'});
  });

  test("calls keep a runtime's missing token counts as null", () {
    final entry = GoldenRunEntry(
      id: 'email:fx-reply',
      stratum: 'triage-spread',
      difficulty: 'medium',
    );
    entry.calls['triage'] = const GoldenCall(
      ms: 2176,
      promptTokens: 1240,
      completionTokens: 96,
      outcome: 'ok',
    );
    entry.calls['extraction'] = const GoldenCall(ms: 900, outcome: 'format');
    expect(entry.toScoreRunJson()['calls'], {
      'triage': {
        'ms': 2176,
        'prompt_tokens': 1240,
        'completion_tokens': 96,
        'outcome': 'ok',
      },
      'extraction': {
        'ms': 900,
        'prompt_tokens': null,
        'completion_tokens': null,
        'outcome': 'format',
      },
    });
  });

  test('writeGoldenRun names the file for the label and round-trips the rows',
      () async {
    final path = await writeGoldenRun(
      [_fullEntry()],
      bench: 'golden-bulk',
      label: 'llamacpp/Qwen3-4B (bulk)',
      outDir: '${tmp.path}${Platform.pathSeparator}bench',
      finishedAt: DateTime.utc(2026, 9, 14, 7, 5, 9),
    );

    final name = path.split(Platform.pathSeparator).last;
    expect(name, 'golden-run-llamacpp-qwen3-4b-bulk-20260914-070509.json');
    final decoded = jsonDecode(File(path).readAsStringSync());
    expect(decoded, isA<List<Object?>>());
    expect((decoded as List).single, _fullEntry().toScoreRunJson());
  });

  test('writeGoldenRun refuses to write when no output directory is defined',
      () async {
    await expectLater(
      writeGoldenRun([], bench: 'golden-bulk', label: 'x', outDir: ''),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('golden-bulk'))),
    );
  });

  // ── the fixture must stay safe for a public repo ──────────────────────
  test('every address in the fixtures is fictional', () {
    final text = _fixtureText(fixturePath, registryPath);
    final addresses = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9._%+\-]+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();
    expect(addresses, isNotEmpty);
    for (final address in addresses) {
      expect(address.endsWith('example.com'), isTrue,
          reason: 'a real-looking address leaked into a public fixture');
    }
  });

  test('every host the fixtures mention is an example.com host', () {
    // Wider than the address check: a URL, a hostname in a body, or a bare
    // domain must be fictional too. Naming real vendors here to exclude them
    // would put those names into a public file, which is the leak this
    // test exists to prevent.
    final text = _fixtureText(fixturePath, registryPath);
    final hosts = RegExp(r'\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|ai)\b',
            caseSensitive: false)
        .allMatches(text)
        .map((m) => m.group(0)!.toLowerCase())
        .toSet();
    expect(hosts, isNotEmpty);
    for (final host in hosts) {
      expect(host.endsWith('example.com'), isTrue,
          reason: 'a real-looking host leaked into a public fixture');
    }
  });

  test('the registry fixture carries three storylines and one anti-pattern',
      () {
    final registry = jsonDecode(File(registryPath).readAsStringSync())
        as Map<String, dynamic>;
    final slugs = [
      for (final entry in registry['storylines'] as List)
        (entry as Map)['slug'],
    ];
    expect(slugs, [
      'river-office-lease',
      'studio-website-redesign',
      'spring-portfolio-review',
    ]);
    expect(
      [
        for (final entry in registry['anti_storylines'] as List)
          (entry as Map)['slug'],
      ],
      ['ANTI-person-hub'],
    );
    final first = (registry['storylines'] as List).first as Map;
    expect(first['charter'], isNotEmpty);
    expect(first['members'], isNotEmpty);
  });
}

/// Both committed fixtures as one blob, for the hygiene checks. They are read
/// together because a name that must not appear in a public repo must not
/// appear in EITHER of them, and a check that covered one would say nothing
/// about the other.
String _fixtureText(String a, String b) =>
    '${File(a).readAsStringSync()}\n${File(b).readAsStringSync()}';

/// One entry with every section filled, so the shape tests read a single
/// definition rather than six near-copies.
GoldenRunEntry _fullEntry() => GoldenRunEntry(
      id: 'email:fx-keep-tail',
      stratum: 'storyline-core',
      difficulty: 'easy',
    )
      ..triage = const GoldenTriageOut(
        category: 'work',
        urgency: 'normal',
        needsAction: true,
        replyExpected: true,
        deadline: 'Friday',
        label: 'lease addendum',
        summary: 'The allowance is capped.',
        actionItems: ['Answer by Friday'],
      )
      ..extract = const GoldenExtractOut(
        intent: 'request',
        importance: 'high',
        project: 'River Street office',
        topics: ['allowance'],
        people: ['Dana Whitfield'],
        organizations: ['Harbor Lane'],
        evidence: 'capped at 18,000',
      )
      ..needsYou = const GoldenNeedsYouOut(
        verdict: true,
        confidence: 'high',
        evidence: 'A direct question.',
      )
      ..storylineId = 'river-office-lease'
      ..draft = const GoldenDraftOut(
        body: 'Yes, that works.',
        options: ['shorter'],
        evidence: 'the capped allowance',
      );
