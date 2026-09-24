import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/label_models.dart';
import '../models/message_models.dart' show Message;
import '../services/classification.dart';
import 'app_providers.dart';
import 'conversations_provider.dart';

/// The standing rules behind the owner's vocabulary, for the Settings list that
/// shows them and the picker that creates them.
///
/// Shaped exactly like `labels_provider.dart` next door, because it is the same
/// kind of thing: one short table the owner wrote by hand, read by more than one
/// surface, edited by a press. One notifier and not a family — there is one set
/// of rules, and every surface shows the same ones.
///
/// The same two list rules hold. **Once loaded, never blank**: a re-read that
/// fails keeps the rules already on screen and hangs a sentence off them, because
/// a Settings list that emptied itself reads as "your rules are gone" — which
/// about a list of standing instructions is alarming in a way no spinner
/// justifies. **Stamp before the first await**: a read started before a delete
/// can land after it, and an answer to a question nobody is asking any more
/// writes nothing.
///
/// Every write here returns how many THREADS moved, because that is the only
/// honest thing to say about a rule: creating one is not a settings change, it
/// moves mail the owner is looking at, and the count is what the toast says.

/// Shown when a re-read failed but there are still rules to look at.
const String _staleRulesMessage =
    "Couldn't re-read your rules just now — showing the last list.";

@immutable
class LabelRulesState {
  /// Newest first, as `MessageStore.listLabelRules` returns them — a rule the
  /// owner just wrote is the one they are looking for.
  final List<LabelRule> rules;

  /// Whether a read has come back at all, success or failure. What separates
  /// "nothing has been read yet" from "no rules exist yet", which are the same
  /// empty list and very different things to draw.
  final bool loaded;

  /// Non-null when the newest read or write failed. The rules above it are still
  /// real, and still standing. A refusal lands here too, because there is no
  /// dialog in this app to put one in.
  final String? error;

  const LabelRulesState({
    this.rules = const [],
    this.loaded = false,
    this.error,
  });

  /// [clearError] rather than a nullable-means-keep [error], for
  /// `LabelsState.copyWith`'s reason: a sentence that could only ever be set
  /// would outlive the failure it described.
  LabelRulesState copyWith({
    List<LabelRule>? rules,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) =>
      LabelRulesState(
        rules: rules ?? this.rules,
        loaded: loaded ?? this.loaded,
        error: clearError ? null : (error ?? this.error),
      );
}

class LabelRulesNotifier extends StateNotifier<LabelRulesState> {
  final MessageStore _store;

  /// What to do once threads have moved — the inbox list re-read, so the mail a
  /// new rule just filed leaves the list in the same frame the rule appears in.
  ///
  /// A callback rather than a `ref`, on `LabelsNotifier`'s precedent: this
  /// notifier owes nothing to the conversation list, and a test builds one with
  /// a store alone.
  final Future<void> Function()? _onThreadsChanged;

  /// Names the KIND of one message row, for a classification-scoped rule.
  ///
  /// A seam rather than an import, because naming the kind of a message is the
  /// pipeline's job and this file sits above it. Null — which is what a test gets
  /// — means a classification-scoped rule matches nothing on the retroactive
  /// walk; the sender, domain and subject scopes are unaffected.
  final String? Function(Map<String, Object?> row)? _classify;

  /// How far back a new rule reaches, or null for every stored message.
  ///
  /// Null is the default AND what production passes — `labelRulesProvider`
  /// below sets nothing here, deliberately: a rule is about a kind of mail,
  /// not about a window, and an owner who has just said "never show me these
  /// again" means the ones already in the mailbox. The walk stays affordable
  /// unbounded because it projects envelopes, never bodies (see
  /// `MessageStore.applyLabelRule`). The seam exists for a surface that IS
  /// about a window, and a test pins that the bound is honoured.
  final String? _lookbackIso;

  int _seq = 0;

  LabelRulesNotifier(
    this._store, {
    this._onThreadsChanged,
    this._classify,
    this._lookbackIso,
  }) : super(const LabelRulesState());

  /// Re-reads every rule. One indexed read of a table with as many rows as the
  /// owner has written, cheap enough to call after every write.
  Future<void> load() async {
    final seq = ++_seq;
    try {
      final rules = await _store.listLabelRules();
      if (seq != _seq || !mounted) return;
      state = state.copyWith(rules: rules, loaded: true, clearError: true);
    } catch (e) {
      if (seq != _seq || !mounted) return;
      debugPrint('label rules read failed: $e');
      state = state.copyWith(loaded: true, error: _staleRulesMessage);
    }
  }

  /// Writes a standing rule and applies it to the mail already here, returning
  /// how many threads it moved — or null when the write failed.
  ///
  /// The count is the point of the return, and null rather than 0 is the failure,
  /// because 0 is a real and unremarkable answer: a rule about a sender who has
  /// not written yet moves nothing and is still standing. `LabelsNotifier.create`
  /// returns a nullable for the same reason.
  ///
  /// Applying is part of creating rather than a second press. Requirement 11b
  /// asks for it in one gesture, and a rule that only took effect on the next
  /// delivery would leave the owner looking at the forty threads that made them
  /// write it.
  ///
  /// A second rule over the same scope REPLACES the first — the store's choice,
  /// documented there — so this cannot fail on a duplicate, and the owner
  /// correcting themselves is not an error message.
  Future<int?> createRule({
    required String labelId,
    required String scopeKind,
    required String scopeValue,
    required String disposition,
    bool unlessMentionsMe = true,
  }) async {
    if (scopeValue.trim().isEmpty) return null;
    try {
      final rule = await _store.createLabelRule(
        labelId: labelId,
        scopeKind: scopeKind,
        scopeValue: scopeValue,
        disposition: disposition,
        unlessMentionsMe: unlessMentionsMe,
      );
      final moved = await _store.applyLabelRule(
        rule.id,
        sinceIso: _lookbackIso,
        classify: _classify,
      );
      await load();
      if (moved > 0) await _announce();
      return moved;
    } on StateError catch (e) {
      if (mounted) state = state.copyWith(error: e.message);
      return null;
    } catch (e) {
      debugPrint('creating a label rule failed: $e');
      if (mounted) {
        state = state.copyWith(error: "Couldn't save that rule just now.");
      }
      return null;
    }
  }

  /// Stops a rule acting on new mail, leaving every thread it has already filed
  /// where it put it.
  ///
  /// The other half of [undoRule], and the difference between them is the whole
  /// reason both exist: this one is "enough of that", and the threads the owner
  /// has stopped thinking about stay gone.
  Future<void> deleteRule(String id) async {
    try {
      await _store.deleteLabelRule(id);
      await load();
    } catch (e) {
      debugPrint('deleting a label rule failed: $e');
      if (!mounted) return;
      state = state.copyWith(error: "Couldn't remove that rule just now.");
    }
  }

  /// Takes a rule back: the rule, the labels it applied, and the threads it
  /// moved. Returns how many threads came back, or null when it failed.
  ///
  /// A RECOMPUTE rather than a restore — see [MessageStore.undoLabelRule]. The
  /// threads return to what the model thinks of them, which is where they would
  /// have been had the rule never existed, and the needs-you pass re-judges them
  /// in the background.
  Future<int?> undoRule(String id) async {
    try {
      final moved = await _store.undoLabelRule(id);
      await load();
      if (moved > 0) await _announce();
      return moved;
    } catch (e) {
      debugPrint('undoing a label rule failed: $e');
      if (mounted) {
        state = state.copyWith(error: "Couldn't undo that rule just now.");
      }
      return null;
    }
  }

  /// "Show again" from the Recently dismissed view: ONE thread this rule filed
  /// comes back, and the rule keeps standing. Returns whether anything moved,
  /// or null when it failed.
  ///
  /// Never [undoRule], which deletes the rule and takes back every thread it
  /// ever filed — see [MessageStore.showRuleFiledThread]. The list re-reads
  /// because the rule's count moved.
  Future<bool?> showThreadAgain(
    String source,
    String conversationKey,
    String ruleId,
  ) async {
    try {
      final moved = await _store.showRuleFiledThread(
        source,
        conversationKey,
        ruleId: ruleId,
      );
      await load();
      if (moved) await _announce();
      return moved;
    } catch (e) {
      debugPrint('showing a rule-filed thread again failed: $e');
      if (mounted) {
        state = state.copyWith(
          error: "Couldn't bring that thread back just now.",
        );
      }
      return null;
    }
  }

  /// Tells the inbox list to re-read. A failure there is the list's own business
  /// and never the reason a write reads as failed — the rule is written either
  /// way, and saying otherwise would invite a second press that wrote it twice.
  Future<void> _announce() async {
    final announce = _onThreadsChanged;
    if (announce == null) return;
    try {
      await announce();
    } catch (e) {
      debugPrint('refreshing the threads after a rule change failed: $e');
    }
  }
}

/// Deliberately NOT autoDispose, for `labelsProvider`'s reason: the rules belong
/// to the session rather than to whichever pane is open, and a rule that stopped
/// existing when the Settings list closed would be read again from scratch on
/// every visit. [LabelRulesNotifier.load] is what keeps it honest.
final labelRulesProvider =
    StateNotifierProvider<LabelRulesNotifier, LabelRulesState>(
  (ref) => LabelRulesNotifier(
    ref.watch(messageStoreProvider),
    onThreadsChanged: () =>
        ref.read(conversationsProvider.notifier).load(syncFirst: false),
    // The same definition of a message's kind the gate and the needs-you pass
    // use, so a classification-scoped rule's retroactive walk moves exactly
    // the threads those two will act on tomorrow.
    classify: (row) => classificationOf(Message.fromRow(row)),
  ),
);
