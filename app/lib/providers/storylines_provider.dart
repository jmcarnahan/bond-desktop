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

  /// The kinds whose progress means the storyline list may have changed.
  /// Extraction and triage report constantly and change nothing here.
  static const Set<String> _kinds = {
    'storyline',
    'storyline_sweep',
    'storyline_recruit',
  };

  static const String _source = 'email';

  final MessageStore _store;
  final StorylineService _service;

  /// Held so [setCharter] can pump the queue it just fed. Nullable for tests
  /// that construct the notifier without a worker.
  final AiWorker? _worker;

  /// Called at the end of every list read. Membership is read by providers of
  /// its own now, and they cache — so without this the member strip would keep
  /// showing what was true before the user's last action or the assignment
  /// pass. Supplied by the provider below, which is the layer that holds a
  /// `Ref`; the notifier itself has no business knowing what a provider is.
  final void Function()? _onMembersChanged;

  StreamSubscription<WorkProgress>? _progress;
  Timer? _reload;

  int _fetchSeq = 0;

  StorylinesNotifier(
    this._store,
    this._service, {
    AiWorker? aiWorker,
    void Function()? onMembersChanged,
  })  : _worker = aiWorker,
        _onMembersChanged = onMembersChanged,
        super(const StorylinesInitial()) {
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
      rows = await _store.loadStorylines();
    } catch (e) {
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is StorylinesLoaded
          ? StorylinesLoaded(current.storylines, _staleStorylinesMessage)
          : StorylinesError('Could not read storylines: $e');
      return;
    }

    if (seq != _fetchSeq) return;
    _onMembersChanged?.call();
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
    await _service.keepSuggestion(id);
    await load();
  }

  Future<void> dismiss(String id) async {
    await _service.dismissSuggestion(id);
    await load();
  }

  Future<void> rename(String id, String title) async {
    await _service.rename(id, title);
    await load();
  }

  /// Saves the charter and starts the recruit it queued. The pump is what
  /// turns "queued" into "runs now" — the worker owns no timer, and without it
  /// the user's edit would sit until the next sync happened to drain the
  /// queue. Fire-and-forget: the pump handles its own failures, and the save
  /// this method reports on has already landed.
  Future<void> setCharter(String id, String charter) async {
    await _service.setCharter(id, charter);
    await load();
    unawaited(_worker?.pump());
  }

  Future<void> addThread(String id, String source, String conversationKey) async {
    await _service.addThread(id, source, conversationKey);
    await load();
  }

  Future<void> removeThread(
    String id,
    String source,
    String conversationKey,
  ) async {
    await _service.removeThread(id, source, conversationKey);
    await load();
  }

  /// Starts a storyline around one thread and returns its id, so the caller
  /// can select what it just made.
  Future<String> create(
    String title, {
    required String conversationKey,
    String source = _source,
  }) async {
    final id = await _service.createStoryline(
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
    onMembersChanged: () {
      ref.invalidate(storylineMembersProvider);
      ref.invalidate(storylineThreadIdsProvider);
      ref.invalidate(storylineBlockedThreadsProvider);
    },
  ),
);

/// One storyline's member threads.
///
/// A provider rather than a read the timeline pane makes for itself: the store
/// is asynchronous and a widget build cannot await one. The strip renders empty
/// for the frame before the read lands, which is what the pane already showed
/// for a storyline with no members yet.
///
/// Dropped and re-read after every list load — see [StorylinesNotifier].
final storylineMembersProvider =
    FutureProvider.autoDispose.family<List<StorylineMember>, String>(
  (ref, id) => ref.watch(messageStoreProvider).membersOf(id),
);

/// The threads the user blocked from one storyline, as
/// `'<source>\n<conversation_key>'` composites. Same caching rules as
/// [storylineMembersProvider], and invalidated with it: a removal writes a
/// block in the same transaction it deletes the membership.
final storylineBlockedThreadsProvider =
    FutureProvider.autoDispose.family<Set<String>, String>(
  (ref, id) => ref.watch(messageStoreProvider).blockedThreadsOf(id),
);

/// The storylines one thread is already filed under, so the "Add to storyline"
/// menu can leave them out. Same caching rules as [storylineMembersProvider].
final storylineThreadIdsProvider = FutureProvider.autoDispose
    .family<Set<String>, ({String source, String conversationKey})>(
  (ref, thread) async => (await ref
          .watch(messageStoreProvider)
          .storylineIdsFor(thread.source, thread.conversationKey))
      .toSet(),
);

// ── one storyline's thread episodes ────────────────────────────────────

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
  /// One episode per member thread, oldest activity first — the whole
  /// storyline, grouped the way it is read.
  final List<StorylineEpisode> episodes;

  final String? loadError;

  const StorylineTimelineLoaded(this.episodes, [this.loadError]);
}

class StorylineTimelineError extends StorylineTimelineState {
  final String message;

  const StorylineTimelineError(this.message);
}

/// One thread's rows while they are still being gathered. [StorylineEpisode]
/// is immutable and one of its fields — the triage summary — costs a second
/// read per thread, so the grouping pass fills one of these first.
class _EpisodeDraft {
  final String source;
  final String conversationKey;
  final List<Message> messages = [];
  final List<String> participants = [];
  final Set<String> _seen = {};

  String subject = '';
  String? latestAt;

  _EpisodeDraft(this.source, this.conversationKey);

  void add(Message message, String? rawSubject) {
    messages.add(message);

    // The FIRST non-empty subject in chronological order names the thread —
    // the same rule the conversation fold uses, so the label here matches the
    // one on the inbox row.
    if (subject.isEmpty) subject = stripReFw(rawSubject);

    final name = message.fromName?.isNotEmpty == true
        ? message.fromName!
        : (message.fromAddress ?? '');
    if (name.isNotEmpty && _seen.add(name)) participants.add(name);

    // Last one wins: the rows arrive oldest first, and a message with no
    // timestamp must not blank a stamp an earlier one supplied.
    final receivedAt = message.receivedAt;
    if (receivedAt != null) latestAt = receivedAt;
  }
}

class StorylineTimelineNotifier extends StateNotifier<StorylineTimelineState> {
  final MessageStore _store;
  final String storylineId;

  StreamSubscription<WorkProgress>? _progress;
  Timer? _reload;

  int _fetchSeq = 0;

  /// Listens to the same worker kinds the list does, for the same reason: an
  /// assignment or recruit pass filing a thread into THIS storyline must move
  /// the spine, not just the member strip — the strip's providers refresh on
  /// progress and a spine on a 60s poll would disagree with it for up to a
  /// minute. Same debounce, so both surfaces move together.
  StorylineTimelineNotifier(this._store, this.storylineId,
      {AiWorker? aiWorker})
      : super(const StorylineTimelineInitial()) {
    final worker = aiWorker;
    if (worker == null) return;
    _progress = worker.progress.listen((progress) {
      if (!StorylinesNotifier._kinds.contains(progress.kind)) return;
      _reload?.cancel();
      _reload = Timer(StorylinesNotifier._reloadDelay, () {
        if (!mounted) return;
        load();
      });
    });
  }

  @override
  void dispose() {
    _reload?.cancel();
    _progress?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final seq = ++_fetchSeq;
    if (state is! StorylineTimelineLoaded) {
      state = const StorylineTimelineLoading();
    }

    final episodes = <StorylineEpisode>[];
    try {
      // Every connector, not just mail: a chat thread can join a storyline
      // through the assignment pass, and a timeline that dropped its messages
      // would show a member strip listing a thread with nothing in it.
      final rows =
          await _store.storylineTimeline(storylineId, sources: inboxSources);
      if (seq != _fetchSeq) return;

      // The rows arrive received_at ASC, so first encounter is the order the
      // threads started in and every episode's messages are already oldest
      // first.
      final drafts = <String, _EpisodeDraft>{};
      for (final row in rows) {
        final key = row['conversation_key'] as String? ?? '';
        if (key.isEmpty) continue;
        final message = Message.fromRow(row);
        drafts
            .putIfAbsent(
              '${message.source}\n$key',
              () => _EpisodeDraft(message.source, key),
            )
            .add(message, row['subject'] as String?);
      }

      for (final draft in drafts.values) {
        final card = await _store.newestInboundCardData(
          draft.source,
          draft.conversationKey,
        );
        if (seq != _fetchSeq) return;
        final summary = card?['summary'] as String?;
        episodes.add(StorylineEpisode(
          source: draft.source,
          conversationKey: draft.conversationKey,
          subject: draft.subject,
          participants: draft.participants,
          messages: draft.messages,
          latestAt: draft.latestAt,
          // An empty summary is a triage pass that had nothing to say, which
          // the card renders the same way as one that has not run.
          summary: summary?.isEmpty == true ? null : summary,
        ));
      }
    } catch (e) {
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is StorylineTimelineLoaded
          ? StorylineTimelineLoaded(
              current.episodes,
              "Couldn't refresh this storyline just now.",
            )
          : StorylineTimelineError('Could not read this storyline: $e');
      return;
    }

    // Ascending, so the newest episode sits at the BOTTOM — the direction the
    // messages inside it already read in. An episode with no timestamp sorts
    // first, since nothing about it says it is the latest, and the thread key
    // breaks ties so one storyline always renders in one order.
    episodes.sort((a, b) {
      final byTime = (a.latestAt ?? '').compareTo(b.latestAt ?? '');
      return byTime != 0 ? byTime : a.threadKey.compareTo(b.threadKey);
    });

    if (seq != _fetchSeq) return;
    state = StorylineTimelineLoaded(episodes);
  }
}

/// Deliberately NOT autoDispose, for the reason `threadProvider` is not:
/// clicking back into a storyline should show its episodes, not a spinner
/// over a read that already ran this session.
final storylineTimelineProvider = StateNotifierProvider.family<
    StorylineTimelineNotifier, StorylineTimelineState, String>(
  (ref, storylineId) => StorylineTimelineNotifier(
    ref.watch(messageStoreProvider),
    storylineId,
    aiWorker: ref.watch(aiWorkerProvider),
  ),
);
