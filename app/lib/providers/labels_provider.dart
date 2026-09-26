import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/label_models.dart';
import 'app_providers.dart';
import 'conversations_provider.dart';

/// The owner's vocabulary, for the picker that applies it and the Settings list
/// that edits it.
///
/// One notifier and not a family: there is one vocabulary, every surface shows
/// the same chips in the same order, and a per-thread family would re-read the
/// whole table for each row on screen.
///
/// The rules the lists in this app share. **Once loaded, never blank**: a
/// re-read that fails keeps the chips that are already drawn and hangs a
/// sentence off them, because a picker that emptied itself mid-keystroke reads
/// as "your labels are gone". **Stamp before the first await**: a read started
/// before a rename can land after it, and an answer to a question nobody is
/// asking any more writes nothing.
///
/// Every mutation here is the OWNER's word, never the model's — nothing in this
/// file reads or writes `messages.label`.

/// Shown when a re-read failed but there are still chips to look at.
const String _staleLabelsMessage =
    "Couldn't re-read your labels just now — showing the last list.";

/// What [LabelsNotifier.remove] did.
@immutable
class LabelRemoval {
  /// False when no link came off: a stale chip's ✕ removed nothing, and an
  /// Undo over it would add a label the thread never had.
  final bool removed;

  const LabelRemoval(this.removed);
}

@immutable
class LabelsState {
  /// The picker's order: most used, then most recently used, then by name.
  final List<Label> labels;

  /// Whether a read has come back at all — success or failure. What separates
  /// "nothing has been read yet" from "no labels exist yet", which are the same
  /// empty list and very different things to draw.
  final bool loaded;

  /// Non-null when the newest read or write failed. The chips above it are
  /// still real. This is also where a refused rename says so, because there is
  /// no dialog to say it in.
  final String? error;

  const LabelsState({
    this.labels = const [],
    this.loaded = false,
    this.error,
  });

  /// [clearError] rather than a nullable-means-keep [error]: a sentence that
  /// could only be set and never cleared would outlive the failure it
  /// described — the next successful write is what takes it away.
  LabelsState copyWith({
    List<Label>? labels,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) =>
      LabelsState(
        labels: labels ?? this.labels,
        loaded: loaded ?? this.loaded,
        error: clearError ? null : (error ?? this.error),
      );
}

class LabelsNotifier extends StateNotifier<LabelsState> {
  final MessageStore _store;

  /// What to do once the vocabulary or a thread's chips have changed — the
  /// inbox list re-read, so a chip appears on the row in the same frame it
  /// appears in the picker.
  ///
  /// A callback rather than a `ref`, on `ArchiveNotifier`'s precedent: this
  /// notifier owes nothing to the conversation list, and a test can build one
  /// with a store alone.
  final Future<void> Function()? _onThreadsChanged;

  int _seq = 0;

  LabelsNotifier(this._store, {this._onThreadsChanged})
      : super(const LabelsState());

  /// Re-reads the whole vocabulary. Cheap enough to call on every picker open:
  /// it is one indexed read of a table with as many rows as the owner has
  /// words, and the alternative is a chip order that lags what they just did.
  Future<void> load() async {
    final seq = ++_seq;
    try {
      final labels = await _store.listLabels();
      if (seq != _seq || !mounted) return;
      state = state.copyWith(labels: labels, loaded: true, clearError: true);
    } catch (e) {
      if (seq != _seq || !mounted) return;
      debugPrint('labels read failed: $e');
      state = state.copyWith(loaded: true, error: _staleLabelsMessage);
    }
  }

  /// Adds a word to the vocabulary and hands it back, or null when the write
  /// failed.
  ///
  /// Idempotent in the store, which is what the picker's Enter key needs: a
  /// name that already exists — in any casing — comes back as the label that
  /// exists rather than as an error.
  Future<Label?> create(String name, {String? tone}) async {
    if (name.trim().isEmpty) return null;
    try {
      final label = await _store.createLabel(name, tone: tone);
      await load();
      return label;
    } catch (e) {
      debugPrint('creating a label failed: $e');
      if (!mounted) return null;
      state = state.copyWith(error: "Couldn't save that label just now.");
      return null;
    }
  }

  /// Renames a label, keeping every thread it is on. False when the name is
  /// already taken by another label.
  ///
  /// The refusal lands in [LabelsState.error] rather than as a throw, because
  /// the surface that asked is a Settings list with no dialog to catch one: the
  /// sentence belongs under the field. The store's rule is the authority — a
  /// rename must never silently merge two vocabularies.
  Future<bool> rename(String id, String newName) async {
    if (newName.trim().isEmpty) return false;
    try {
      await _store.renameLabel(id, newName);
      await load();
      await _announce();
      return true;
    } on StateError catch (e) {
      if (mounted) state = state.copyWith(error: e.message);
      return false;
    } catch (e) {
      debugPrint('renaming a label failed: $e');
      if (mounted) {
        state = state.copyWith(error: "Couldn't rename that label just now.");
      }
      return false;
    }
  }

  /// Sets, or with a null [tone] clears, one label's colour word.
  Future<void> setTone(String id, String? tone) async {
    try {
      await _store.setLabelTone(id, tone);
      await load();
      await _announce();
    } catch (e) {
      debugPrint('setting a label tone failed: $e');
      if (!mounted) return;
      state = state.copyWith(error: "Couldn't change that colour just now.");
    }
  }

  /// Deletes a label and every thread link it has.
  Future<void> delete(String id) async {
    try {
      await _store.deleteLabel(id);
      await load();
      await _announce();
    } catch (e) {
      debugPrint('deleting a label failed: $e');
      if (!mounted) return;
      state = state.copyWith(error: "Couldn't delete that label just now.");
    }
  }

  /// Files one thread under [labelIds], without touching its state.
  ///
  /// This is **keep with a label**: the thread stays exactly where it is and
  /// gains a chip. Dismissing WITH a label is one action and belongs to
  /// [ConversationsNotifier.markDone], so that the undo behind it is one step.
  ///
  /// Says whether the links went on, for the same reason [remove] does: a
  /// "Labeled" toast, and an Undo behind it, over a write that failed.
  Future<bool> apply(
    String source,
    String conversationKey,
    List<String> labelIds,
  ) async {
    if (labelIds.isEmpty) return true;
    try {
      await _store.applyLabels(source, conversationKey, labelIds);
      // The list as well as the threads: an apply moves `use_count`, which is
      // what orders the chips the owner is looking at.
      await load();
      await _announce();
      return true;
    } catch (e) {
      debugPrint('applying labels failed: $e');
      if (!mounted) return false;
      state = state.copyWith(error: "Couldn't file that thread just now.");
      return false;
    }
  }

  /// Takes one label off one thread, and says what happened: null when the
  /// write failed, otherwise whether a link came off — [LabelRemoval.removed]
  /// false when the chip was already gone, so the caller knows there is
  /// nothing to offer an Undo over. The label's `use_count` stays where it
  /// is — see [MessageStore.removeLabel].
  ///
  /// The answer is for a caller that reports the act: a toast saying
  /// "Removed" over a write that failed would be the bar lying, and the
  /// sentence for the failure is already in [LabelsState.error].
  Future<LabelRemoval?> remove(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    try {
      final removed =
          await _store.removeLabel(source, conversationKey, labelId);
      await _announce();
      if (mounted) state = state.copyWith(clearError: true);
      return LabelRemoval(removed);
    } catch (e) {
      debugPrint('removing a label failed: $e');
      if (!mounted) return null;
      state = state.copyWith(error: "Couldn't take that label off just now.");
      return null;
    }
  }

  /// The Undo behind [remove]: the link back, and no `use_count` movement,
  /// because putting back what was there is not the owner reaching for the
  /// word again. False when the write failed, and when the label has been
  /// deleted since: either way the chip is not coming back.
  Future<bool> restore(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    try {
      final restored =
          await _store.restoreLabel(source, conversationKey, labelId);
      await _announce();
      if (mounted) state = state.copyWith(clearError: true);
      return restored;
    } catch (e) {
      debugPrint('restoring a label failed: $e');
      if (!mounted) return false;
      state = state.copyWith(error: "Couldn't put that label back just now.");
      return false;
    }
  }

  /// Tells the inbox list to re-read, so a chip lands on the row in the same
  /// frame it lands in the picker. A failure there is the list's own business
  /// and never the reason a write reads as failed.
  Future<void> _announce() async {
    final announce = _onThreadsChanged;
    if (announce == null) return;
    try {
      await announce();
    } catch (e) {
      debugPrint('refreshing the threads after a label change failed: $e');
    }
  }
}

/// Deliberately NOT autoDispose: the vocabulary belongs to the session, not to
/// the picker that happens to be open, and re-reading it on every expand would
/// put a spinner over a list of five words. [LabelsNotifier.load] is what keeps
/// it honest.
final labelsProvider = StateNotifierProvider<LabelsNotifier, LabelsState>(
  (ref) => LabelsNotifier(
    ref.watch(messageStoreProvider),
    onThreadsChanged: () =>
        ref.read(conversationsProvider.notifier).load(syncFirst: false),
  ),
);
