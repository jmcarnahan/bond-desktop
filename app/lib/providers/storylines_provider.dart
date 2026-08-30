import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../services/ai_worker.dart';
import '../services/conversation_state.dart';
import '../services/storyline_service.dart';
import 'app_providers.dart';
import 'conversations_provider.dart' show inboxSources;

/// The storylines read model.
///
/// Same two rules as `conversations_provider.dart`, for the same reasons:
/// **once loaded, never blank** — a failed re-read keeps the rows on screen
/// and hangs an explanation off them — and every load stamps a sequence number
/// before its first await and checks it on the way back, so a slow read can
/// never stamp itself over a newer one.

const String _staleStorylinesMessage =
    "Couldn't refresh storylines just now — showing the last set.";

@immutable
sealed class StorylinesState {
  const StorylinesState();
}

class StorylinesInitial extends StorylinesState {
  const StorylinesInitial();
}

class StorylinesLoading extends StorylinesState {
  const StorylinesLoading();
}

class StorylinesLoaded extends StorylinesState {
  final List<Storyline> storylines;

  /// Non-null when the newest read failed. The rows above it are still real,
  /// just older than they should be.
  final String? loadError;

  const StorylinesLoaded(this.storylines, [this.loadError]);
}

class StorylinesError extends StorylinesState {
  final String message;

  const StorylinesError(this.message);
}

class StorylinesNotifier extends StateNotifier<StorylinesState> {
  /// The same debounce the inbox uses. Both storyline queues report after
  /// every item, and a sweep that proposes three groups in a second would
  /// otherwise be three full list reads.
  static const Duration _reloadDelay = Duration(milliseconds: 400);

  /// The two kinds whose progress means the storyline list may have changed.
  /// Extraction and triage report constantly and change nothing here.
  static const Set<String> _kinds = {'storyline', 'storyline_sweep'};

  static const String _source = 'email';

  final MessageStore _store;
  final StorylineService _service;

  StreamSubscription<WorkProgress>? _progress;
  Timer? _reload;

  int _fetchSeq = 0;

  StorylinesNotifier(this._store, this._service, {AiWorker? aiWorker})
      : super(const StorylinesInitial()) {
    final worker = aiWorker;
    if (worker == null) return;
    _progress = worker.progress.listen((progress) {
      if (!_kinds.contains(progress.kind)) return;
      _scheduleReload();
    });
  }

  void _scheduleReload() {
    _reload?.cancel();
    _reload = Timer(_reloadDelay, () {
      if (!mounted) return;
      load();
    });
  }

  @override
  void dispose() {
    _reload?.cancel();
    _progress?.cancel();
    super.dispose();
  }

  /// Re-reads the list from sqlite. There is no network half — storylines are
  /// derived locally from mail that is already stored.
  Future<void> load() async {
    final seq = ++_fetchSeq;
    if (state is! StorylinesLoaded) state = const StorylinesLoading();

    final List<Storyline> rows;
    try {
      rows = _store.loadStorylines();
    } catch (e) {
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is StorylinesLoaded
          ? StorylinesLoaded(current.storylines, _staleStorylinesMessage)
          : StorylinesError('Could not read storylines: $e');
      return;
    }

    if (seq != _fetchSeq) return;
    state = StorylinesLoaded(rows);
  }

  // ── user actions ───────────────────────────────────────────────────────
  //
  // Every one of these writes through the service and then re-reads, rather
  // than patching the list in place. The writes are local and instantaneous,
  // and several of them change more than the row they were called on — a keep
  // re-orders the whole list, a remove changes a count — so a patched copy
  // would disagree with the database within one action.

  Future<void> keep(String id) async {
    _service.keepSuggestion(id);
    await load();
  }

  Future<void> dismiss(String id) async {
    _service.dismissSuggestion(id);
    await load();
  }

  Future<void> rename(String id, String title) async {
    _service.rename(id, title);
    await load();
  }

  Future<void> addThread(String id, String source, String conversationKey) async {
    _service.addThread(id, source, conversationKey);
    await load();
  }

  Future<void> removeThread(
    String id,
    String source,
    String conversationKey,
  ) async {
    _service.removeThread(id, source, conversationKey);
    await load();
  }

  /// Starts a storyline around one thread and returns its id, so the caller
  /// can select what it just made.
  Future<String> create(
    String title, {
    required String conversationKey,
    String source = _source,
  }) async {
    final id = _service.createStoryline(
      title,
      source: source,
      conversationKey: conversationKey,
    );
    await load();
    return id;
  }
}

final storylinesProvider =
    StateNotifierProvider<StorylinesNotifier, StorylinesState>(
  (ref) => StorylinesNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(storylineServiceProvider),
    aiWorker: ref.watch(aiWorkerProvider),
  ),
);

// ── one storyline's merged transcript ──────────────────────────────────

@immutable
sealed class StorylineTimelineState {
  const StorylineTimelineState();
}

class StorylineTimelineInitial extends StorylineTimelineState {
  const StorylineTimelineInitial();
}

class StorylineTimelineLoading extends StorylineTimelineState {
  const StorylineTimelineLoading();
}

class StorylineTimelineLoaded extends StorylineTimelineState {
  /// Every message of every member thread, oldest first.
  final List<Message> messages;

  /// `source_message_id` → `conversation_key`. Carried beside the messages
  /// because [Message] has no field for its thread's key, and the merged
  /// transcript has to know where one thread ends and the next begins.
  final Map<String, String> keyByMessageId;

  /// `conversation_key` → the thread's stripped subject. The timeline needs it
  /// to label the point where the transcript crosses from one thread into
  /// another, and the messages alone cannot supply it: a member thread's
  /// subject may be `Re: Re:` on every row.
  final Map<String, String> subjectByKey;

  final String? loadError;

  const StorylineTimelineLoaded(
    this.messages,
    this.keyByMessageId,
    this.subjectByKey, [
    this.loadError,
  ]);
}

class StorylineTimelineError extends StorylineTimelineState {
  final String message;

  const StorylineTimelineError(this.message);
}

class StorylineTimelineNotifier extends StateNotifier<StorylineTimelineState> {
  final MessageStore _store;
  final String storylineId;

  int _fetchSeq = 0;

  StorylineTimelineNotifier(this._store, this.storylineId)
      : super(const StorylineTimelineInitial());

  Future<void> load() async {
    final seq = ++_fetchSeq;
    if (state is! StorylineTimelineLoaded) {
      state = const StorylineTimelineLoading();
    }

    final List<Map<String, Object?>> rows;
    try {
      // Every connector, not just mail: a chat thread can join a storyline
      // through the assignment pass, and a timeline that dropped its messages
      // would show a member strip listing a thread with nothing in it.
      rows = _store.storylineTimeline(storylineId, sources: inboxSources);
    } catch (e) {
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is StorylineTimelineLoaded
          ? StorylineTimelineLoaded(
              current.messages,
              current.keyByMessageId,
              current.subjectByKey,
              "Couldn't refresh this storyline just now.",
            )
          : StorylineTimelineError('Could not read this storyline: $e');
      return;
    }

    final messages = <Message>[];
    final keys = <String, String>{};
    final subjects = <String, String>{};
    for (final row in rows) {
      final message = Message.fromRow(row);
      messages.add(message);
      final key = row['conversation_key'] as String? ?? '';
      if (key.isEmpty) continue;
      keys[message.id] = key;
      // The FIRST non-empty subject in chronological order names the thread —
      // the same rule the conversation fold uses, so the label here matches
      // the one on the inbox row.
      if (subjects[key]?.isNotEmpty == true) continue;
      final subject = stripReFw(row['subject'] as String?);
      if (subject.isNotEmpty) subjects[key] = subject;
    }

    if (seq != _fetchSeq) return;
    state = StorylineTimelineLoaded(messages, keys, subjects);
  }
}

/// Deliberately NOT autoDispose, for the reason `threadProvider` is not:
/// clicking back into a storyline should show its transcript, not a spinner
/// over a read that already ran this session.
final storylineTimelineProvider = StateNotifierProvider.family<
    StorylineTimelineNotifier, StorylineTimelineState, String>(
  (ref, storylineId) =>
      StorylineTimelineNotifier(ref.watch(messageStoreProvider), storylineId),
);
