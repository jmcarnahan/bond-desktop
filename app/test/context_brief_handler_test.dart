import 'dart:convert';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/context/context_brief_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// One brief per directory, and the hash that keeps it to one.
///
/// The hash is the load-bearing part. The reconcile pass queues this kind on
/// every pass that queued anything at all — including passes over a folder
/// nothing has touched, because a digest backlog lands on later passes — so
/// what stops the app paying for a brief every minute is that this handler
/// compares its own inputs first. Several tests below hand it a script with
/// exactly ONE answer in it: a second call would run off the end and throw.
class _FakeLlm extends LlmClient {
  _FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  final List<Object> script;
  final List<String> userMessages = [];

  int get calls => userMessages.length;

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    userMessages.add(user);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (script.isEmpty) throw StateError('the script ran out');
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};
  String? status;

  @override
  void note(Map<String, Object?> facts) => notes.addAll(facts);

  @override
  void noteStatus(String value) => status = value;
}

Map<String, dynamic> briefAnswer({
  String about = 'Atlas is where the renewal analysis lives.',
  List<Map<String, String>> pointers = const [
    {'topic': 'Pricing', 'path': 'analysis/pricing.md'},
  ],
}) =>
    {
      'about': about,
      'reply_guidance': const ['Keep it short.'],
      'key_facts': const ['The renewal is 2,600 a month.'],
      'pointers': pointers,
      'vocabulary': const ['Marrowfield'],
    };

void main() {
  late BondDatabase db;
  late ContextStore store;
  late _Recorder log;

  setUp(() {
    db = testDb();
    store = ContextStore(db);
    log = _Recorder();
  });

  tearDown(() async => db.close());

  Future<String> register() => store.registerDirectory(
        path: '/Users/wren/projects/atlas',
        displayName: 'atlas',
      );

  /// A file row with words, and optionally a digest already on it.
  Future<int> addFile(
    String dirId, {
    required String relPath,
    required String text,
    ContextFileDigest? digest,
  }) async {
    final id = await store.upsertFile(
      dirId: dirId,
      relPath: relPath,
      size: text.length,
      mtime: '2026-09-09T11:00:00Z',
      sha256: 'sha-$relPath',
      kind: relPath == 'CLAUDE.md' ? 'claude_md' : 'doc',
      claudeChain: const [],
      textChars: text.length,
    );
    await store.setFileText(id, text);
    if (digest != null) {
      await store.setFileDigest(
        id,
        status: 'done',
        digestJson: jsonEncode(digest.toJson()),
      );
    }
    return id;
  }

  Future<void> runFor(
    _FakeLlm llm,
    String dirId, {
    Future<int> Function(String dirId)? onBriefChanged,
  }) =>
      ContextBriefHandler(
        store,
        llm,
        activityLog: log,
        onBriefChanged: onBriefChanged,
      ).run({
        'task_kind': 'context_brief',
        'source': 'local',
        'entity_id': dirId,
      });

  test('a directory nobody registered is skipped as gone', () async {
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, 'no-such-directory');

    expect(log.status, 'skipped');
    expect(log.notes['reason'], 'gone');
    expect(llm.calls, 0);
  });

  test('a directory with no notes and no digests is cleared, not briefed',
      () async {
    final dirId = await register();
    await store.setDirectoryBrief(
      dirId,
      briefJson: '{"about":"stale"}',
      briefHash: 'old',
    );
    await addFile(dirId, relPath: 'art/logo.png', text: '');
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    // Cleared rather than left alone: a project that lost its notes must
    // not keep handing replies the guidance it used to give.
    final dir = (await store.directory(dirId))!;
    expect(dir.briefJson, isNull);
    expect(dir.briefHash, isNull);
    expect(log.notes['reason'], 'nothing_to_brief');
    expect(llm.calls, 0);
  });

  test('standing notes alone are enough, imports and all', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n@docs/conventions.md\nReplies here stay short.\n',
    );
    await addFile(
      dirId,
      relPath: 'docs/conventions.md',
      text: 'Always cite the notebook.',
    );
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    // The import is resolved through the INDEX, not off the disk: this
    // handler runs long after the walk and may be outside the sandbox by
    // then.
    expect(llm.userMessages.single, contains('Always cite the notebook.'));
    expect(llm.userMessages.single, contains('imported: docs/conventions.md'));
    expect(llm.userMessages.single, isNot(contains('file_map')));

    final brief = ContextBrief.decode((await store.directory(dirId))!.briefJson)!;
    expect(brief.about, 'Atlas is where the renewal analysis lives.');
    expect(log.notes['has_claude_md'], isTrue);
    expect(log.notes['files_mapped'], 0);
  });

  test('digests alone are enough, as path · purpose · questions', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'analysis/pricing.md',
      text: 'The renewal is 2,600 a month.',
      digest: const ContextFileDigest(
        purpose: 'Works out the renewal.',
        questionsAnswered: ['What does it cost?', 'When does it renew?'],
      ),
    );
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    expect(
      llm.userMessages.single,
      contains('analysis/pricing.md · Works out the renewal. · '
          'What does it cost?; When does it renew?'),
    );
    expect(llm.userMessages.single, isNot(contains('claude_md')));
    expect(log.notes['files_mapped'], 1);
    expect(log.notes['has_claude_md'], isFalse);
    expect(log.notes['pointers'], 1);
  });

  test('both halves ride in the same message', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n\nReplies here stay short.\n',
    );
    await addFile(
      dirId,
      relPath: 'analysis/pricing.md',
      text: 'The renewal is 2,600 a month.',
      digest: const ContextFileDigest(purpose: 'Works out the renewal.'),
    );
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    expect(llm.userMessages.single, contains('claude_md'));
    expect(llm.userMessages.single, contains('file_map'));
  });

  test('a row whose digest JSON will not decode is dropped from the map',
      () async {
    final dirId = await register();
    final broken = await addFile(
      dirId,
      relPath: 'analysis/broken.md',
      text: 'Something.',
    );
    await store.setFileDigest(broken, status: 'done', digestJson: '{oops');
    await addFile(
      dirId,
      relPath: 'analysis/pricing.md',
      text: 'The renewal is 2,600 a month.',
      digest: const ContextFileDigest(purpose: 'Works out the renewal.'),
    );
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    expect(llm.userMessages.single, isNot(contains('analysis/broken.md')));
    expect(log.notes['files_mapped'], 2, reason: 'both rows carry JSON');
  });

  test('a second pass over unchanged inputs pays nothing', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n\nReplies here stay short.\n',
    );
    // ONE answer in the script: a second call runs off the end and throws.
    final llm = _FakeLlm([briefAnswer()]);
    await runFor(llm, dirId);
    final hash = (await store.directory(dirId))!.briefHash;

    log = _Recorder();
    await runFor(llm, dirId);

    expect(log.status, 'skipped');
    expect(log.notes['reason'], 'unchanged');
    expect(llm.calls, 1);
    expect((await store.directory(dirId))!.briefHash, hash);
  });

  test('an edit past the prompt\'s own ceiling is not a second brief',
      () async {
    final dirId = await register();
    // Nine thousand characters of standing notes against a ceiling of eight:
    // the last thousand never reach the model.
    final notes = 'Replies here stay short. '.padRight(9000, 'x');
    final fileId = await addFile(dirId, relPath: 'CLAUDE.md', text: notes);
    // ONE answer in the script: a second call runs off the end and throws.
    final llm = _FakeLlm([briefAnswer()]);
    await runFor(llm, dirId);
    final hash = (await store.directory(dirId))!.briefHash;

    await store.setFileText(
      fileId,
      '${notes.substring(0, 8500)}and a sentence nobody will ever be shown.',
    );
    log = _Recorder();
    await runFor(llm, dirId);

    // The hash decides whether this directory is briefed again, so it has
    // to be a hash of what the prompt actually CARRIES. Unclamped, an edit
    // past the ceiling buys a call that reads the identical message.
    expect(log.status, 'skipped');
    expect(log.notes['reason'], 'unchanged');
    expect(llm.calls, 1);
    expect((await store.directory(dirId))!.briefHash, hash);
  });

  test('the root notes are not imported into themselves', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n@docs/a.md\nReplies here stay short.\n',
    );
    await addFile(
      dirId,
      relPath: 'docs/a.md',
      text: 'Always cite the notebook.\n@../CLAUDE.md\n',
    );
    final llm = _FakeLlm([briefAnswer()]);

    await runFor(llm, dirId);

    // `A` importing `B` importing `A` has always meant the second line is
    // left as text. Without the root on the cycle stack the notes get
    // inlined into the middle of themselves.
    final message = llm.userMessages.single;
    expect(message, contains('Always cite the notebook.'));
    expect(message, contains('imported: docs/a.md'));
    expect(message, isNot(contains('imported: CLAUDE.md')));
    expect(message, contains('@../CLAUDE.md'));
  });

  test('a changed digest changes the hash and re-runs the brief', () async {
    final dirId = await register();
    final fileId = await addFile(
      dirId,
      relPath: 'analysis/pricing.md',
      text: 'The renewal is 2,600 a month.',
      digest: const ContextFileDigest(purpose: 'Works out the renewal.'),
    );
    final llm = _FakeLlm([
      briefAnswer(),
      briefAnswer(about: 'Atlas now covers the escalator too.'),
    ]);
    await runFor(llm, dirId);
    final first = (await store.directory(dirId))!.briefHash;

    await store.setFileDigest(
      fileId,
      status: 'done',
      digestJson: jsonEncode(
        const ContextFileDigest(purpose: 'Works out the escalator.').toJson(),
      ),
    );
    log = _Recorder();
    await runFor(llm, dirId);

    expect(llm.calls, 2);
    final dir = (await store.directory(dirId))!;
    expect(dir.briefHash, isNot(first));
    expect(
      ContextBrief.decode(dir.briefJson)!.about,
      'Atlas now covers the escalator too.',
    );
  });

  test('pointers are clamped at ten on the way into the column', () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n\nReplies here stay short.\n',
    );
    final llm = _FakeLlm([
      briefAnswer(
        pointers: [
          for (var i = 0; i < 20; i++) {'topic': 'topic $i', 'path': 'p$i.md'},
        ],
      ),
    ]);

    await runFor(llm, dirId);

    final brief =
        ContextBrief.decode((await store.directory(dirId))!.briefJson)!;
    expect(brief.pointers, hasLength(10));
    expect(log.notes['pointers'], 10);
  });

  group('telling the rest of the app the project said something new', () {
    test('the callback fires once, with the directory it is about', () async {
      final dirId = await register();
      await addFile(
        dirId,
        relPath: 'CLAUDE.md',
        text: '# Atlas\n\nReplies here stay short.\n',
      );
      final told = <String>[];

      await runFor(_FakeLlm([briefAnswer()]), dirId,
          onBriefChanged: (id) async {
        told.add(id);
        return 2;
      });

      expect(told, [dirId]);
      expect(log.notes['charters_offered'], 2);
    });

    test('an unchanged brief tells nobody anything', () async {
      final dirId = await register();
      await addFile(
        dirId,
        relPath: 'CLAUDE.md',
        text: '# Atlas\n\nReplies here stay short.\n',
      );
      final llm = _FakeLlm([briefAnswer()]);
      final told = <String>[];
      Future<int> record(String id) async {
        told.add(id);
        return 1;
      }

      await runFor(llm, dirId, onBriefChanged: record);
      log = _Recorder();
      await runFor(llm, dirId, onBriefChanged: record);

      // An unchanged brief has nothing new to say about the project, so
      // there is nothing to offer anyone.
      expect(log.notes['reason'], 'unchanged');
      expect(told, hasLength(1));
    });

    test('nothing to brief tells nobody anything', () async {
      final dirId = await register();
      final told = <String>[];

      await runFor(_FakeLlm([briefAnswer()]), dirId,
          onBriefChanged: (id) async {
        told.add(id);
        return 1;
      });

      expect(log.notes['reason'], 'nothing_to_brief');
      expect(told, isEmpty);
    });

    test('an offer that throws costs the offer and never the brief', () async {
      final dirId = await register();
      await addFile(
        dirId,
        relPath: 'CLAUDE.md',
        text: '# Atlas\n\nReplies here stay short.\n',
      );

      await runFor(
        _FakeLlm([briefAnswer()]),
        dirId,
        onBriefChanged: (_) async => throw StateError('the storylines are out'),
      );

      // The brief was paid for with a model call and is already stored; the
      // charter offer is a courtesy built on top of it.
      final dir = (await store.directory(dirId))!;
      expect(dir.briefHash, isNotNull);
      expect(ContextBrief.decode(dir.briefJson)!.about,
          'Atlas is where the renewal analysis lives.');
      expect(log.notes['charter_error'], contains('the storylines are out'));
      expect(log.notes['charters_offered'], isNull);
    });

    test('nothing offered is nothing noted', () async {
      final dirId = await register();
      await addFile(
        dirId,
        relPath: 'CLAUDE.md',
        text: '# Atlas\n\nReplies here stay short.\n',
      );

      await runFor(_FakeLlm([briefAnswer()]), dirId,
          onBriefChanged: (_) async => 0);

      expect(log.notes['charters_offered'], isNull);
    });
  });

  test('a failed call leaves the previous brief and its hash alone',
      () async {
    final dirId = await register();
    await addFile(
      dirId,
      relPath: 'CLAUDE.md',
      text: '# Atlas\n\nReplies here stay short.\n',
    );
    await store.setDirectoryBrief(
      dirId,
      briefJson: '{"about":"the one before"}',
      briefHash: 'previous',
    );

    await expectLater(
      runFor(_FakeLlm([const LlmUnavailableException('fast slot off')]), dirId),
      throwsA(isA<LlmUnavailableException>()),
    );

    // The hash is written only WITH the brief it describes. A hash stamped
    // before the call would tell the next pass this directory was briefed
    // from notes no brief was ever compiled from.
    final dir = (await store.directory(dirId))!;
    expect(dir.briefHash, 'previous');
    expect(ContextBrief.decode(dir.briefJson)!.about, 'the one before');
  });
}
