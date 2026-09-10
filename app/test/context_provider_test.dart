import 'dart:convert';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/context_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/context/directory_access.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart'
    show encodeEmbedding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Settings library's read model and its five writes.
///
/// The section above it is prop-only and pinned by
/// `settings_context_section_test.dart`; this pins what actually reaches the
/// database — the three counts on every row, and that Add both registers the
/// directory and queues the read that fills it in.

class _FakeDialogs implements FileDialogs {
  _FakeDialogs(this.folder);

  /// What the open panel answers. Null is a cancel.
  String? folder;

  int calls = 0;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      null;

  @override
  Future<String?> chooseDirectory() async {
    calls++;
    return folder;
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ContextStore context;
  late ProviderContainer container;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    context = ContextStore(db);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // Preloaded, so building the worker below does not start an async
      // preference read that would still be out when this test closes its
      // database.
      initialAppPrefsProvider.overrideWithValue(
        await AppPrefsNotifier.read(store),
      ),
      // No Runner behind a `flutter test` binary, so the real channel would
      // answer MissingPluginException on every call.
      directoryAccessProvider.overrideWithValue(const PlainDirectoryAccess()),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  ContextDirectoriesActions actions() =>
      container.read(contextDirectoriesActionsProvider);

  Future<List<ContextDirRow>> readRows() =>
      container.read(contextDirectoriesProvider.future);

  test('an empty library is an empty list, not an error', () async {
    expect(await readRows(), isEmpty);
  });

  test('a row carries its links, passages and embedded count', () async {
    final id = await context.registerDirectory(
      path: '/Users/pat/projects/acme',
      displayName: 'acme',
    );
    final fileId = await context.upsertFile(
      dirId: id,
      relPath: 'docs/pricing.md',
      size: 400,
      mtime: '2026-09-09T10:00:00Z',
      sha256: 'abc',
      kind: 'doc',
      claudeChain: const [],
      textChars: 400,
    );
    await context.replaceChunks(fileId, const [
      (seq: 0, locator: 'Pricing', text: 'docs/pricing.md · Pricing\nrates'),
      (seq: 1, locator: 'Terms', text: 'docs/pricing.md · Terms\nnet 30'),
    ]);
    await context.setChunkEmbedding(
      (await context.unembeddedChunks(fileId)).first.id,
      embedding: encodeEmbedding(List<double>.filled(4, 0.5)),
      dims: 4,
      embedModel: 'test-embed',
    );
    await context.link(id, ContextScopeKind.thread, 'email', 'c1');
    await context.link(id, ContextScopeKind.storyline, '', 's1');

    final rows = await readRows();

    expect(rows, hasLength(1));
    expect(rows.single.dir.displayName, 'acme');
    expect(rows.single.links, 2);
    expect(rows.single.chunks, 2);
    expect(rows.single.embedded, 1);
    // Nothing has been digested and nothing carries a brief yet.
    expect(rows.single.about, isNull);
    expect(rows.single.digestsDone, 0);
    expect(rows.single.digestsEligible, 1);
  });

  test('a row carries the brief opener and how far the summaries have got',
      () async {
    final id = await context.registerDirectory(
      path: '/Users/pat/projects/acme',
      displayName: 'acme',
    );
    await context.setDirectoryBrief(
      id,
      briefJson: jsonEncode(
        const ContextBrief(about: 'Acme is the renewal analysis.').toJson(),
      ),
      briefHash: 'h1',
    );
    Future<int> addFile(String relPath, {required int chars}) =>
        context.upsertFile(
          dirId: id,
          relPath: relPath,
          size: chars,
          mtime: '2026-09-09T10:00:00Z',
          sha256: 'sha-$relPath',
          kind: 'doc',
          claudeChain: const [],
          textChars: chars,
        );
    final done = await addFile('docs/pricing.md', chars: 400);
    await addFile('docs/terms.md', chars: 400);
    // Below the floor: in neither half of the progress, which is what
    // makes `K of M` a count that can actually reach its total.
    await addFile('docs/stub.md', chars: 20);
    await context.setFileDigest(done, status: 'done', digestJson: '{}');

    final rows = await readRows();

    expect(rows.single.about, 'Acme is the renewal analysis.');
    expect(rows.single.digestsDone, 1);
    expect(rows.single.digestsEligible, 2);
  });

  group('one file, for the panel', () {
    late String dirId;
    late int fileId;

    setUp(() async {
      dirId = await context.registerDirectory(
        path: '/Users/pat/projects/acme',
        displayName: 'acme',
      );
      fileId = await context.upsertFile(
        dirId: dirId,
        relPath: 'docs/pricing.md',
        size: 400,
        mtime: '2026-09-09T10:00:00Z',
        sha256: 'abc',
        kind: 'doc',
        claudeChain: const [],
        textChars: 400,
      );
      await context.setFileText(
        fileId,
        'Intro paragraph.\n\nQ4 rates hold at nine.\n',
      );
      await context.replaceChunks(fileId, const [
        (
          seq: 0,
          locator: 'Pricing',
          text: 'docs/pricing.md · Pricing\nQ4 rates hold at nine.',
        ),
      ]);
      await context.setFileDigest(
        fileId,
        status: 'done',
        digestJson: jsonEncode(const ContextFileDigest(
          purpose: 'The renewal pricing model.',
          findings: ['Rates hold at nine.'],
          kindHint: 'analysis',
        ).toJson()),
      );
    });

    Future<ContextFileView?> read({String? locator}) => container
        .read(contextFileProvider((fileId: fileId, locator: locator)).future);

    test('the file, its directory, its words and its digest', () async {
      final view = (await read())!;

      expect(view.file.relPath, 'docs/pricing.md');
      expect(view.dir.displayName, 'acme');
      expect(view.text, contains('Q4 rates hold at nine.'));
      expect(view.digest!.purpose, 'The renewal pricing model.');
      // Nothing named a section, so nothing is marked.
      expect(view.located, isNull);
    });

    test('a locator answers the passage with its header line off', () async {
      final view = (await read(locator: 'Pricing'))!;

      // The chunker's `<rel path> · <locator>` header is stored WITH the
      // passage so the embedding carries it, and it is not in the file's own
      // words — a highlight hunting for it would never find one.
      expect(view.located, 'Q4 rates hold at nine.');
    });

    test('a digest locator marks nothing in the words', () async {
      final view = (await read(locator: 'digest'))!;

      // The digest has a block of its own above the words and is not IN them.
      expect(view.located, isNull);
    });

    test('a locator nothing was cut under marks nothing', () async {
      expect((await read(locator: 'Nowhere'))!.located, isNull);
    });

    test('a file nobody indexed is null', () async {
      expect(
        await container
            .read(contextFileProvider((fileId: 9999, locator: null)).future),
        isNull,
      );
    });

    test('contextFilesProvider lists a directory in path order', () async {
      await context.upsertFile(
        dirId: dirId,
        relPath: 'CLAUDE.md',
        size: 20,
        mtime: '2026-09-09T10:00:00Z',
        sha256: 'def',
        kind: 'claude_md',
        claudeChain: const [],
        textChars: 20,
      );

      final files =
          await container.read(contextFilesProvider(dirId).future);

      expect(
        [for (final file in files) file.relPath],
        ['CLAUDE.md', 'docs/pricing.md'],
      );
      expect(
        await container.read(contextFilesProvider('no-such-dir').future),
        isEmpty,
      );
    });
  });

  group('Add directory…', () {
    test('registers the folder and queues a forced read', () async {
      final dialogs = _FakeDialogs('/Users/pat/projects/acme');

      final added = await actions().addDirectory(dialogs);

      expect(dialogs.calls, 1);
      expect(added, isNotNull);
      expect(added!.displayName, 'acme');
      expect(added.id, ContextStore.idForPath('/Users/pat/projects/acme'));

      final dirs = await context.directories();
      expect(dirs.single.path, '/Users/pat/projects/acme');
      // No Runner in a test, so no bookmark: the directory is registered on
      // its stored path and reads for this launch off that.
      expect(dirs.single.bookmark, isNull);
      expect(dirs.single.status, 'pending');

      expect(
        await store.workCounts('context_reconcile', sources: const ['local']),
        {'pending': 1},
      );
      final work = await db
          .customSelect(
            'SELECT payload_json FROM work_items '
            "WHERE task_kind = 'context_reconcile'",
          )
          .getSingle();
      expect(work.data['payload_json'], '{"force":true}');
    });

    test('a cancelled panel registers nothing', () async {
      final dialogs = _FakeDialogs(null);

      expect(await actions().addDirectory(dialogs), isNull);
      expect(await context.directories(), isEmpty);
      expect(
        await store.workCounts('context_reconcile', sources: const ['local']),
        isEmpty,
      );
    });
  });

  test('Re-read now brings a finished item back to pending', () async {
    final dialogs = _FakeDialogs('/Users/pat/projects/acme');
    final added = await actions().addDirectory(dialogs);
    // The pass ran and the row is done: this is exactly the state an
    // `INSERT OR IGNORE` would leave alone, and the upsert revives.
    await db.customUpdate(
      "UPDATE work_items SET status = 'done', payload_json = NULL "
      "WHERE task_kind = 'context_reconcile'",
    );

    await actions().reread(added!.id);

    expect(
      await store.workCounts('context_reconcile', sources: const ['local']),
      {'pending': 1},
    );
    final work = await db
        .customSelect(
          'SELECT payload_json FROM work_items '
          "WHERE task_kind = 'context_reconcile'",
        )
        .getSingle();
    expect(work.data['payload_json'], '{"force":true}');
  });

  test('Re-read now on a directory with no work row makes one', () async {
    final id = await context.registerDirectory(
      path: '/Users/pat/notes',
      displayName: 'notes',
    );

    await actions().reread(id);

    // The other half of the same upsert: one call inserts where there is no
    // row and revives where there is a finished one, so nothing follows it.
    expect(
      await store.workCounts('context_reconcile', sources: const ['local']),
      {'pending': 1},
    );
  });

  group('the Summaries switch', () {
    Future<String> registered() async {
      final id = await context.registerDirectory(
        path: '/Users/pat/projects/acme',
        displayName: 'acme',
      );
      // The pass has run and the work row is finished — the state a person
      // is actually in when they reach for this switch.
      await store.requeueWork('context_reconcile', 'local', id);
      await db.customUpdate(
        "UPDATE work_items SET status = 'done', payload_json = NULL "
        "WHERE task_kind = 'context_reconcile'",
      );
      return id;
    }

    test('turning it on queues a forced pass now', () async {
      final id = await registered();

      await actions().setDigests(id, true);

      // The digests are queued by the reconcile pass and by nothing else,
      // and the pass answers `fresh` for a minute — so without this the
      // switch looks like it does nothing.
      expect(
        await store.workCounts('context_reconcile', sources: const ['local']),
        {'pending': 1},
      );
      final work = await db
          .customSelect(
            'SELECT payload_json FROM work_items '
            "WHERE task_kind = 'context_reconcile'",
          )
          .getSingle();
      expect(work.data['payload_json'], '{"force":true}');
    });

    test('turning it off queues nothing', () async {
      final id = await registered();

      await actions().setDigests(id, false);

      // The handler already declines a directory whose switch is off, and
      // the rows it leaves pending are what makes turning it back on pick
      // up where it stopped.
      expect(
        await store.workCounts('context_reconcile', sources: const ['local']),
        {'done': 1},
      );
    });
  });

  test('Remove drops the directory and its links', () async {
    final id = await context.registerDirectory(
      path: '/Users/pat/projects/acme',
      displayName: 'acme',
    );
    await context.link(id, ContextScopeKind.thread, 'email', 'c1');

    await actions().remove(id);

    expect(await context.directories(), isEmpty);
    expect(await context.linkCount(id), 0);
  });

  test('the two option switches write only their own column', () async {
    final id = await context.registerDirectory(
      path: '/Users/pat/projects/acme',
      displayName: 'acme',
    );

    await actions().setDigests(id, false);
    var dir = await context.directory(id);
    expect(dir!.digests, isFalse);
    expect(dir.honorGitignore, isFalse);

    await actions().setHonorGitignore(id, true);
    dir = await context.directory(id);
    expect(dir!.digests, isFalse, reason: 'the other switch was not touched');
    expect(dir.honorGitignore, isTrue);
  });
}
