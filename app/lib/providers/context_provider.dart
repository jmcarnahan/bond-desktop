import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/context_models.dart';
import '../services/attachments/file_dialogs.dart';
import 'activity_provider.dart' show activityEventsProvider;
import 'app_providers.dart';
import 'draft_provider.dart' show DraftTarget;

/// One registered directory, the sentence its brief opens with, and the four
/// counts the library row reports: how many rooms point at it, how many
/// passages it holds, how many of those have a vector, and how far the
/// per-file summaries have got.
///
/// A record rather than a class on [ContextDir], and the counts deliberately
/// NOT columns: `links` moves when a room is linked and `chunks` moves when a
/// file is re-read, so storing either on the directory row would be a second
/// copy of a number two other tables already answer.
///
/// [about] is the one part of the compiled brief this row shows. It is the
/// only place in Settings that says what the app made of a folder, which is
/// how a person tells a directory that was read from one that was merely
/// walked.
typedef ContextDirRow = ({
  ContextDir dir,
  int links,
  int chunks,
  int embedded,
  String? about,
  int digestsDone,
  int digestsEligible,
});

/// The Settings library, re-read after every recorded activity event.
///
/// Watching [activityEventsProvider] is the whole liveness mechanism, copied
/// from `syncStampsProvider` and kept for the same reason: the reconcile pass
/// records when it finishes, so a walk that lands behind an open Settings
/// pane moves `N files · read just now` with no timer of its own. Riverpod
/// carries the previous value through the reload, so the rows do not blink
/// between an event and its re-read.
///
/// Three extra reads per directory rather than one joined query, because the
/// library is a handful of rows a person registered by hand — a join written
/// to save six statements would be the harder thing to change the next time
/// a pass adds a number to this row.
final contextDirectoriesProvider =
    FutureProvider.autoDispose<List<ContextDirRow>>((ref) async {
  ref.watch(activityEventsProvider);
  final store = ref.watch(contextStoreProvider);
  final rows = <ContextDirRow>[];
  for (final dir in await store.directories()) {
    final counts = await store.chunkCounts(dir.id);
    final digests = await store.digestCounts(dir.id);
    rows.add((
      dir: dir,
      links: await store.linkCount(dir.id),
      chunks: counts.chunks,
      embedded: counts.embedded,
      about: ContextBrief.decode(dir.briefJson)?.about,
      digestsDone: digests.done,
      digestsEligible: digests.eligible,
    ));
  }
  return rows;
});

/// One room, as the link reads and writes name it.
///
/// A record and not three positional arguments, because it is the FAMILY KEY
/// of two providers: Riverpod compares family arguments by `==`, and a record
/// of three strings compares by value where a class would have needed one
/// written by hand — and a key that compared by identity would rebuild the
/// panel on every frame.
///
/// [source] is `''` for a storyline, whose ids are already global.
typedef ContextScope = ({
  ContextScopeKind kind,
  String source,
  String scopeKey,
});

/// The directories linked to ONE room — what the panel's switches read.
///
/// Re-read on every activity event, exactly as the library is and for the
/// same reason: a link written by the panel and a directory registered from
/// inside it both land as activity, and the switch under the reader's finger
/// has to agree with the row it just wrote.
final contextLinksProvider =
    FutureProvider.autoDispose.family<List<String>, ContextScope>(
  (ref, scope) async {
    ref.watch(activityEventsProvider);
    return ref
        .watch(contextStoreProvider)
        .dirIdsLinkedTo(scope.kind, scope.source, scope.scopeKey);
  },
);

/// What a THREAD reads because of the storylines it is in, named by storyline.
///
/// The inheritance is the one pinned documents have, and the panel shows it
/// rather than folding it into the switches: a directory a thread inherits is
/// not a directory this thread linked, and a switch that turned itself off
/// would be a switch that unlinked somebody else's storyline.
///
/// Empty for a storyline's own panel, which inherits from nothing.
///
/// The [dirId] rides beside the name because two readers need two different
/// things from the same row: the panel prints the name, and the file panel
/// asks whether THIS directory is in scope for the room before it offers
/// **Consult for the reply**. A name is not an identity — two storylines can
/// carry directories that display the same — so the question is answered on
/// the id.
final contextInheritedProvider = FutureProvider.autoDispose.family<
    List<({String storyline, String dirId, String dirName})>, DraftTarget>(
  (ref, target) async {
    ref.watch(activityEventsProvider);
    final messages = ref.watch(messageStoreProvider);
    final store = ref.watch(contextStoreProvider);
    final inherited = <({String storyline, String dirId, String dirName})>[];
    for (final storylineId
        in await messages.storylineIdsFor(target.source, target.conversationKey)) {
      final storyline = await messages.getStoryline(storylineId);
      if (storyline == null) continue;
      for (final dirId in await store.dirIdsLinkedTo(
        ContextScopeKind.storyline,
        '',
        storylineId,
      )) {
        final dir = await store.directory(dirId);
        if (dir == null) continue;
        inherited.add((
          storyline: storyline.title,
          dirId: dir.id,
          dirName: dir.displayName,
        ));
      }
    }
    return inherited;
  },
);

/// One indexed file as the panel reads it: the row, the directory it belongs
/// to, its extracted words, its digest, and the passage a citation named.
///
/// [located] is the stored passage under the requested locator with its header
/// line already off — the panel highlights it inside [text] and scrolls to it.
/// Null when no locator was asked for, when the locator was `digest` (the
/// digest has its own block above the words and is not IN them), or when the
/// file no longer has a passage there.
typedef ContextFileView = ({
  ContextFile file,
  ContextDir dir,
  String text,
  ContextFileDigest? digest,
  String? located,
});

/// One file of one registered directory, for the file panel.
///
/// Null for a file nobody indexed — the panel says so in a sentence rather
/// than showing an empty reader.
///
/// Re-read on every activity event for [contextLinksProvider]'s reason: a
/// reconcile pass that lands while the panel is open changes the words on
/// screen, and a file the walk deleted stops being a file.
final contextFileProvider = FutureProvider.autoDispose
    .family<ContextFileView?, ({int fileId, String? locator})>(
  (ref, key) async {
    ref.watch(activityEventsProvider);
    final store = ref.watch(contextStoreProvider);
    final file = await store.fileById(key.fileId);
    if (file == null) return null;
    // Belt and braces. `removeDirectory` deletes the file rows before the
    // directory row, so a file whose directory has gone is a file that cannot
    // be read back at all — this branch has nothing to catch today. It stays
    // because the alternative to it is a breadcrumb drawn against a null.
    final dir = await store.directory(file.dirId);
    if (dir == null) return null;

    final locator = key.locator;
    String? located;
    if (locator != null && locator.isNotEmpty && locator != 'digest') {
      final chunk = await store.chunkTextFor(file.id, locator);
      if (chunk != null) {
        // The chunker's own header — `<rel path> · <locator>` — is stored WITH
        // the passage so the embedding carries it. It is not in the file's
        // words, so a highlight hunting for it would never find one.
        final newline = chunk.indexOf('\n');
        located = newline < 0 ? '' : chunk.substring(newline + 1);
      }
    }

    return (
      file: file,
      dir: dir,
      text: await store.fileText(file.id) ?? '',
      digest: ContextFileDigest.decode(file.digestJson),
      located: (located != null && located.isEmpty) ? null : located,
    );
  },
);

/// Every file of one directory, in path order — what a `Files ›` disclosure
/// lists.
///
/// Watches the activity events for [contextFileProvider]'s reason: a pass that
/// adds or drops a file changes this list under an open panel.
final contextFilesProvider =
    FutureProvider.autoDispose.family<List<ContextFile>, String>(
  (ref, dirId) async {
    ref.watch(activityEventsProvider);
    return ref.watch(contextStoreProvider).filesFor(dirId);
  },
);

/// Every write the Settings library makes, in one place.
///
/// The section and the screen above it stay prop-only: they call these and
/// know nothing about [ContextStore], the work queue or the bookmark seam.
/// That is the same discipline the rest of Settings keeps, and here it also
/// buys the ordering — a register that did not enqueue, or an enqueue that
/// did not pump, is a directory that sits at `not read yet` until the next
/// sixty-second poll.
class ContextDirectoriesActions {
  ContextDirectoriesActions(this._ref);

  final Ref _ref;

  /// Opens the folder panel, registers what the user picked, and starts
  /// reading it. Null when they cancelled — the ordinary way out, and not an
  /// error.
  ///
  /// [dialogs] is passed rather than read from a provider because the host
  /// screen already owns one: `InboxScreen` takes a [FileDialogs] so a widget
  /// test can hand it a temp directory with no open panel anywhere.
  ///
  /// The bookmark is taken IMMEDIATELY after the panel and before anything
  /// else, because the sandbox's grant is on that pick: a bookmark asked for
  /// a moment later, from outside the panel's grant, is an error rather than
  /// a bookmark. A build that keeps none answers null, the directory is
  /// registered without one, and it reads for this launch off its stored
  /// path.
  Future<({String id, String displayName})?> addDirectory(
    FileDialogs dialogs,
  ) async {
    final path = await dialogs.chooseDirectory();
    if (path == null) return null;
    final displayName = p.basename(path);
    final store = _ref.read(contextStoreProvider);
    final id = await store.registerDirectory(
      path: path,
      displayName: displayName,
      bookmark: await _ref.read(directoryAccessProvider).bookmark(path),
    );
    // Forced, because the person is standing in front of it. Re-adding a
    // directory registered a moment ago must read it rather than answer
    // `fresh` at a row that has not changed on screen — and re-adding one
    // that was removed months ago must read it rather than meet the `done`
    // work row it left behind, which is why this is the same upsert
    // [reread] uses rather than an `INSERT OR IGNORE`.
    await _ref.read(messageStoreProvider).requeueWork(
          'context_reconcile',
          'local',
          id,
          payloadJson: '{"force":true}',
        );
    unawaited(_ref.read(aiWorkerProvider).pump());
    _ref.invalidate(contextDirectoriesProvider);
    return (id: id, displayName: displayName);
  }

  /// Points a room at a directory, or stops pointing it there.
  ///
  /// Two invalidations rather than one: the switch's own provider, and the
  /// library — whose row carries how many rooms point at each directory, and
  /// that number has just moved.
  Future<void> setLinked(String dirId, ContextScope scope, bool on) async {
    final store = _ref.read(contextStoreProvider);
    if (on) {
      await store.link(dirId, scope.kind, scope.source, scope.scopeKey);
    } else {
      await store.unlink(dirId, scope.kind, scope.source, scope.scopeKey);
    }
    _ref.invalidate(contextLinksProvider(scope));
    _ref.invalidate(contextDirectoriesProvider);
  }

  /// Registers a directory AND links it to the room the person was standing
  /// in. Null when they cancelled the open panel.
  ///
  /// Two steps and one meaning: pressing **Add directory…** inside a room is
  /// how a person says "read this here". Registering it and leaving the switch
  /// off would answer a question nobody asked.
  Future<({String id, String displayName})?> addDirectoryTo(
    FileDialogs dialogs,
    ContextScope scope,
  ) async {
    final added = await addDirectory(dialogs);
    if (added == null) return null;
    await setLinked(added.id, scope, true);
    return added;
  }

  /// Re-reads one directory now, whatever the freshness rung would have said.
  ///
  /// One call. [requeueWork] is an upsert on the work row's primary key
  /// `(task_kind, source, entity_id)`: it inserts a row where there is none,
  /// moves a `done` or `error` one back to pending with this payload, and
  /// leaves a row already waiting exactly where it is. That is every state a
  /// work row can be in, so nothing follows it.
  Future<void> reread(String id) async {
    await _ref.read(messageStoreProvider).requeueWork(
          'context_reconcile',
          'local',
          id,
          payloadJson: '{"force":true}',
        );
    unawaited(_ref.read(aiWorkerProvider).pump());
    _ref.invalidate(contextDirectoriesProvider);
  }

  /// Forgets a directory: its files, its words, its passages and its links.
  /// The folder on disk is untouched — this app has never written into one.
  Future<void> remove(String id) async {
    await _ref.read(contextStoreProvider).removeDirectory(id);
    _ref.invalidate(contextDirectoriesProvider);
  }

  /// Whether each changed file in this directory earns a one-call digest.
  ///
  /// Turning it ON queues a forced pass, exactly as Re-read now does. The
  /// digests are queued by the reconcile pass and by nothing else, and the
  /// pass is skipped as `fresh` for a minute — so without this, a person who
  /// switches summaries on watches `summaries 0 of 12` sit still and
  /// concludes the switch does nothing. Turning it OFF queues nothing:
  /// the digest handler already declines a directory whose switch is off,
  /// and the rows it leaves `pending` are what makes turning it back on
  /// pick up where it stopped.
  Future<void> setDigests(String id, bool on) async {
    await _ref.read(contextStoreProvider).setDirectoryOptions(id, digests: on);
    if (on) {
      await _ref.read(messageStoreProvider).requeueWork(
            'context_reconcile',
            'local',
            id,
            payloadJson: '{"force":true}',
          );
      unawaited(_ref.read(aiWorkerProvider).pump());
    }
    _ref.invalidate(contextDirectoriesProvider);
  }

  /// Whether `.gitignore` is honoured. Nothing is re-read on the strength of
  /// the change: the next pass applies it, which is the same contract the
  /// sync lookback keeps.
  Future<void> setHonorGitignore(String id, bool on) async {
    await _ref
        .read(contextStoreProvider)
        .setDirectoryOptions(id, honorGitignore: on);
    _ref.invalidate(contextDirectoriesProvider);
  }
}

final contextDirectoriesActionsProvider = Provider<ContextDirectoriesActions>(
  ContextDirectoriesActions.new,
);
