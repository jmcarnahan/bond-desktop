import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/message_models.dart';
import '../services/ai_worker.dart';
import '../services/graph_auth.dart';
import '../services/sync_service.dart';
import '../services/triage_queue.dart';
import 'app_providers.dart';

/// The inbox's read model.
///
/// One rule shapes every notifier in this file: **once loaded, never blank.**
/// A refresh that fails does not throw the list away and does not fall back
/// to a spinner. It keeps the rows already on screen and hangs a one-line
/// explanation off them. A mail app that empties itself when the wifi drops
/// reads as data loss, and users treat it as data loss.
///
/// The other rule is the sequence guard. Both notifiers stamp a fetch number
/// BEFORE their first await and check it on every path back — success and
/// failure alike. Without the check on the failure path, a slow refresh that
/// eventually fails would stamp its error over a newer refresh that already
/// succeeded.

/// Shown when a refresh failed but there is still an inbox to look at.
const String _staleInboxMessage =
    "Couldn't refresh just now — showing the last inbox.";
const String _staleThreadMessage =
    "Couldn't refresh just now — showing the last version.";

@immutable
sealed class ConversationsState {
  const ConversationsState();
}

class ConversationsInitial extends ConversationsState {
  const ConversationsInitial();
}

class ConversationsLoading extends ConversationsState {
  const ConversationsLoading();
}

class ConversationsLoaded extends ConversationsState {
  final List<Conversation> conversations;

  /// Non-null when the newest refresh failed. The rows above it are still
  /// real — they are just older than the user asked for.
  final String? loadError;

  const ConversationsLoaded(this.conversations, [this.loadError]);

  ConversationsLoaded withRows(List<Conversation> rows, String? error) =>
      ConversationsLoaded(rows, error);
}

/// Nothing to show at all. [signedOut] separates the one failure the user can
/// act on — the session ended — from every transient one.
class ConversationsError extends ConversationsState {
  final String message;
  final bool signedOut;

  const ConversationsError(this.message, {this.signedOut = false});
}

class ConversationsNotifier extends StateNotifier<ConversationsState> {
  /// Triage annotates roughly one message every seventeen seconds and reports
  /// each one. The debounce is what keeps a burst — a gated run skips messages
  /// in milliseconds — from turning into a burst of full list reads.
  static const Duration _triageReloadDelay = Duration(milliseconds: 400);

  final MessageStore _store;
  final MailSync _sync;

  /// Null in tests that exercise only the read model. When present, every sync
  /// kicks it and every result it lands reloads the list.
  final TriageQueue? _triage;

  /// The AI queue, kicked after triage rather than beside it — see [load].
  /// Nothing on screen listens to its progress yet.
  final AiWorker? _aiWorker;

  StreamSubscription<TriageProgress>? _triageProgress;
  Timer? _triageReload;

  /// Incremented per [load]; a load whose number is stale writes nothing.
  int _fetchSeq = 0;

  ConversationsNotifier(
    this._store,
    this._sync, {
    TriageQueue? triage,
    AiWorker? aiWorker,
    Future<String?>? userAddress,
  })  : _triage = triage,
        _aiWorker = aiWorker,
        super(const ConversationsInitial()) {
    final queue = triage;
    if (queue == null) return;
    if (userAddress != null) {
      // Fire-and-forget, and a failure is survivable: without the address the
      // self gate is off, which costs a few model calls on the LO's own mail
      // and nothing else.
      unawaited(
        userAddress.then<void>((address) {
          queue.userAddress = address;
        }).catchError((Object _) {}),
      );
    }
    _triageProgress = queue.progress.listen((_) => _scheduleReload());
  }

  /// Re-reads the list from sqlite alone — no sync — so a CTA appears under
  /// the row it belongs to as soon as the model writes it.
  void _scheduleReload() {
    _triageReload?.cancel();
    _triageReload = Timer(_triageReloadDelay, () {
      if (!mounted) return;
      load(syncFirst: false);
    });
  }

  @override
  void dispose() {
    _triageReload?.cancel();
    _triageProgress?.cancel();
    super.dispose();
  }

  Future<void> load({bool syncFirst = true}) async {
    // Stamped before the first await, so a load started later always wins
    // however the two finish.
    final seq = ++_fetchSeq;

    // A spinner is only ever shown when there is genuinely nothing behind
    // it. A periodic refresh over a live inbox must not flash one.
    if (state is! ConversationsLoaded) state = const ConversationsLoading();

    String? loadError;
    var sessionEnded = false;

    if (syncFirst) {
      try {
        await _sync.syncNow();
        // Started, never awaited: triage takes about seventeen seconds a
        // message, and the mail that just synced must render now. Results
        // arrive later through the progress stream.
        //
        // The AI queue is CHAINED behind triage rather than started beside it.
        // Both are serial queues in front of the same single-threaded model
        // server, so running them together would not finish either sooner — it
        // would halve the speed of both and throw away the prompt cache
        // between every pair of requests. Triage goes first because its output
        // is what the user is looking at.
        final pump = _triage?.pump();
        if (pump != null) {
          unawaited(
            pump.then<void>((_) => _aiWorker?.pump()).catchError(
              // Both pumps handle their own failures; anything reaching here
              // is a bug worth a trace, not worth crashing the zone over.
              (Object e) => debugPrint('queue pump chain failed: $e'),
            ),
          );
        } else {
          final ai = _aiWorker?.pump();
          if (ai != null) unawaited(ai);
        }
      } on AuthException catch (e) {
        if (seq != _fetchSeq) return;
        // Only these two mean "sign in again". A generic AuthException is a
        // 5xx or an offline laptop, and signing a user out over one would
        // cost them their session for a dropped packet.
        sessionEnded = e is NotSignedIn || e is ReconsentRequired;
        loadError = sessionEnded ? e.message : _staleInboxMessage;
      } catch (_) {
        if (seq != _fetchSeq) return;
        loadError = _staleInboxMessage;
      }
    }

    if (seq != _fetchSeq) return;

    final List<Conversation> rows;
    try {
      rows = _store.loadConversations(sources: const ['email']);
    } catch (e) {
      // The database itself failed. There is no stale-but-valid answer to
      // fall back to beyond whatever is already on screen.
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is ConversationsLoaded
          ? current.withRows(current.conversations, _staleInboxMessage)
          : ConversationsError('Could not read the local inbox: $e');
      return;
    }

    if (seq != _fetchSeq) return;

    // Signed out AND nothing stored: there is no inbox to keep, so route to
    // sign-in. With rows in hand the banner says the session ended and the
    // user keeps reading what they already had.
    if (sessionEnded && rows.isEmpty) {
      state = ConversationsError(loadError ?? 'Sign in again.', signedOut: true);
      return;
    }

    state = ConversationsLoaded(rows, loadError);
  }

  /// Flips a thread to done, on screen first.
  ///
  /// Optimistic because the write is local and effectively instantaneous —
  /// waiting on it would only add a frame of lag to a button whose whole job
  /// is to feel immediate. A failure puts the row back exactly as it was.
  Future<void> markDone(String conversationKey) async {
    final current = state;
    if (current is! ConversationsLoaded) return;

    state = current.withRows([
      for (final c in current.conversations)
        if (c.id == conversationKey)
          c.copyWith(state: ConversationState.done)
        else
          c,
    ], current.loadError);

    try {
      _store.setConversationState(
        'email',
        conversationKey,
        ConversationState.done,
      );
    } catch (_) {
      final latest = state;
      if (latest is! ConversationsLoaded) return;
      state = latest.withRows(
        current.conversations,
        "Couldn't save that just now — the thread is unchanged.",
      );
    }
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, ConversationsState>(
  (ref) => ConversationsNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(syncServiceProvider),
    triage: ref.watch(triageQueueProvider),
    aiWorker: ref.watch(aiWorkerProvider),
    // A future, not a value: the account is a keychain read, and the inbox
    // must not wait on it to render. Until it resolves the self gate is off.
    userAddress: ref.watch(graphAuthProvider).storedAccount.then(
          (account) => account?.mail ?? account?.userPrincipalName,
        ),
  ),
);

// ── One thread ─────────────────────────────────────────────────────────

@immutable
sealed class ThreadState {
  const ThreadState();
}

class ThreadInitial extends ThreadState {
  const ThreadInitial();
}

class ThreadLoading extends ThreadState {
  const ThreadLoading();
}

class ThreadLoaded extends ThreadState {
  final List<Message> messages;
  final String? loadError;

  const ThreadLoaded(this.messages, [this.loadError]);
}

class ThreadError extends ThreadState {
  final String message;

  const ThreadError(this.message);
}

class ThreadNotifier extends StateNotifier<ThreadState> {
  final MessageStore _store;
  final MailSync _sync;
  final String conversationKey;

  int _fetchSeq = 0;

  ThreadNotifier(this._store, this._sync, this.conversationKey)
      : super(const ThreadInitial());

  /// Bodies first, then the read. [fetchBodies] false skips the network
  /// entirely — what a re-render wants when the transcript is already whole.
  Future<void> load({bool fetchBodies = true}) async {
    final seq = ++_fetchSeq;
    if (state is! ThreadLoaded) state = const ThreadLoading();

    String? loadError;
    if (fetchBodies) {
      try {
        await _sync.ensureBodies(conversationKey);
      } catch (_) {
        if (seq != _fetchSeq) return;
        // Including the auth failures: the inbox notifier is the one that
        // routes those, and two banners saying the same thing is one too
        // many. The bodies already stored still render.
        loadError = _staleThreadMessage;
      }
    }

    if (seq != _fetchSeq) return;

    final List<Message> messages;
    try {
      messages = _store.loadThread(conversationKey, sources: const ['email']);
    } catch (e) {
      if (seq != _fetchSeq) return;
      final current = state;
      state = current is ThreadLoaded
          ? ThreadLoaded(current.messages, _staleThreadMessage)
          : ThreadError('Could not read this thread: $e');
      return;
    }

    if (seq != _fetchSeq) return;
    state = ThreadLoaded(messages, loadError);
  }
}

/// Deliberately NOT autoDispose: clicking back to a thread should show its
/// transcript, not a spinner over a fetch that already ran this session.
final threadProvider =
    StateNotifierProvider.family<ThreadNotifier, ThreadState, String>(
  (ref, conversationKey) => ThreadNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(syncServiceProvider),
    conversationKey,
  ),
);
