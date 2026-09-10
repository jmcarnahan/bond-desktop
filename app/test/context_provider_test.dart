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
    // The pass ran and the row is done: this is exactly the state a plain
    // `enqueueWork` would ignore.
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

    expect(
      await store.workCounts('context_reconcile', sources: const ['local']),
      {'pending': 1},
    );
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
