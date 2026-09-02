import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/message_models.dart';
import '../services/ai_worker.dart';
import '../services/attention.dart';
import '../services/attention_service.dart';
import '../services/backend/backend_types.dart';
import '../services/read_ack_queue.dart';
import '../services/sync_service.dart';
import '../services/teams_sync.dart';
import '../services/triage_queue.dart';
import 'app_providers.dart';
import 'prefs_provider.dart' show attentionThresholdKey;

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

/// Its own sentence, and not the inbox one. A Teams refresh failing while the
/// mail sync is fine is a partial outage, and a banner that said "couldn't
/// refresh" would have the user doubting mail that is perfectly current.
const String _staleTeamsMessage = "Couldn't refresh Teams just now.";

/// Every connector the inbox reads. One list, because the list read, the
/// scoring pass and the thread transcript must agree about what is in the
/// inbox — three separately-maintained copies would drift, and the symptom
/// would be a thread that ranks but does not render.
const List<String> inboxSources = ['email', 'teams'];

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

  /// The Teams connector, or null where there is none.
  ///
  /// Reached ONLY from [refreshTeams], which only ever runs off the rail's
  /// refresh button or an app-focus resume. Nothing on the timer path so much
  /// as reads this field — Microsoft's terms for the Teams messaging endpoints
  /// forbid polling them, and `teams_poll_test.dart` holds that line.
  final TeamsSync? _teamsSync;

  /// Null in tests that exercise only the read model. When present, every sync
  /// kicks it and every result it lands reloads the list.
  final TriageQueue? _triage;

  /// The AI queue, kicked after triage rather than beside it — see [load].
  final AiWorker? _aiWorker;

  /// Scores and re-files the mailbox immediately before every read. Null in
  /// tests that only exercise the read model; the list then renders whatever
  /// scores and buckets were last written.
  final AttentionService? _attention;

  /// Tells the server what [markRead] has already flipped locally. Reached
  /// ONLY from [markRead] — never from [load], which a sixty-second timer
  /// calls: this queue carries Teams acks too, and Microsoft's terms forbid a
  /// timer reaching those endpoints. `teams_refresh_test.dart` holds that line.
  final ReadAckQueue? _readAcks;

  StreamSubscription<TriageProgress>? _triageProgress;

  /// The AI queue's progress, on the same debounce as triage's. Some cycles
  /// have no triage in them at all — a CTA landing from extract, a thread
  /// joining a storyline — and before this the list only found out about them
  /// on the next sync.
  StreamSubscription<WorkProgress>? _aiProgress;

  Timer? _triageReload;

  /// Incremented per [load]; a load whose number is stale writes nothing.
  int _fetchSeq = 0;

  ConversationsNotifier(
    this._store,
    this._sync, {
    TeamsSync? teamsSync,
    TriageQueue? triage,
    AiWorker? aiWorker,
    AttentionService? attention,
    ReadAckQueue? readAcks,
    Future<String?>? userAddress,
  })  : _teamsSync = teamsSync,
        _triage = triage,
        _aiWorker = aiWorker,
        _attention = attention,
        _readAcks = readAcks,
        super(const ConversationsInitial()) {
    // Subscribed before the triage early-return below, because a notifier can
    // be wired with an AI queue and no triage queue at all.
    _aiProgress = aiWorker?.progress.listen((_) => _scheduleReload());

    final queue = triage;
    if (queue == null) return;
    if (userAddress != null) {
      // Fire-and-forget, and a failure is survivable: without the address the
      // self gate is off, which costs a few model calls on the user's own mail
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
    _aiProgress?.cancel();
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
            pump.then<void>((_) async {
              await _aiWorker?.pump();
              await _afterPump();
            }).catchError(
              // Both pumps handle their own failures; anything reaching here
              // is a bug worth a trace, not worth crashing the zone over.
              (Object e) => debugPrint('queue pump chain failed: $e'),
            ),
          );
        } else {
          final ai = _aiWorker?.pump();
          if (ai != null) {
            unawaited(
              ai.then<void>((_) => _afterPump()).catchError(
                (Object e) => debugPrint('queue pump chain failed: $e'),
              ),
            );
          }
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
      // Immediately before the read rather than on a timer of its own: it is
      // four indexed queries and some arithmetic, and running it anywhere
      // else would mean the rows about to render could carry scores
      // computed against a sender rule the user has since changed. Inside the
      // same try as the read because both are the same database — a failure in
      // either is "could not read the local inbox".
      await _attention?.recomputeAll(sources: inboxSources);
      rows = await _store.loadConversations(sources: inboxSources);
      await _enqueueDrafts();
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

  /// Pulls Teams chats, then re-reads the list.
  ///
  /// **The only entry point to Teams, and it is only ever called from
  /// something the user did** — the rail's refresh button, or the app coming
  /// back to the foreground after long enough. [load] never calls it, which is
  /// what keeps the sixty-second poll timer off endpoints Microsoft's terms say
  /// must not be polled.
  ///
  /// It reloads even when the pull failed: the mail rows and whatever Teams
  /// managed to store before it stopped are still the freshest thing there is,
  /// and the banner goes on afterwards so [load]'s own clean result cannot
  /// erase it.
  ///
  /// A build with no Teams connector, and a tenant that never granted
  /// `Chat.Read`, both do nothing at all — the second inside
  /// [TeamsSync.syncNow], before any request.
  Future<void> refreshTeams() async {
    final teams = _teamsSync;
    if (teams == null) return;

    String? error;
    try {
      await teams.syncNow();
      // The same chain [load] starts after a mail sync, for the same reason:
      // the chats this pull just re-pended should be triaged and drafted now,
      // not whenever the poll timer next happens to come round. Chained rather
      // than run beside each other — one model server, one queue at a time,
      // triage first because its output is what the user is looking at.
      final pump = _triage?.pump();
      if (pump != null) {
        unawaited(
          pump.then<void>((_) async {
            await _aiWorker?.pump();
            await _afterPump();
          }).catchError(
            (Object e) => debugPrint('queue pump chain failed: $e'),
          ),
        );
      } else {
        final ai = _aiWorker?.pump();
        if (ai != null) {
          unawaited(
            ai.then<void>((_) => _afterPump()).catchError(
              (Object e) => debugPrint('queue pump chain failed: $e'),
            ),
          );
        }
      }
    } on AuthException {
      // Deliberately the same banner as any other failure: the inbox load is
      // what routes a dead session to sign-in, and a second opinion from the
      // Teams path would mean two banners saying different things about one
      // sign-out.
      error = _staleTeamsMessage;
    } catch (_) {
      error = _staleTeamsMessage;
    }

    await load(syncFirst: false);
    if (error == null) return;

    final current = state;
    if (current is ConversationsLoaded) {
      state = current.withRows(current.conversations, error);
    }
  }

  /// The settle pass: what the inbox does once both queues have drained.
  ///
  /// [load] scores and enqueues BEFORE the pumps it starts have finished,
  /// which is right for the frame the user is looking at and wrong for the
  /// mail the model was still reading. A thread only crosses the draft
  /// threshold once triage has said something about it, so scoring the
  /// mailbox a second time here is what lets that thread be drafted in the
  /// same cycle instead of waiting for the next sync — which on a quiet
  /// afternoon is a minute away, and on a Teams-only session never comes.
  ///
  /// The load-time [AttentionService.recomputeAll] STAYS. It is the pass that
  /// makes a sender correction show up in the frame the user made it in;
  /// this one is about what the model learned since.
  ///
  /// The inner pump is deliberately NOT chained back into another settle pass.
  /// One extra drain empties the drafts this pass just queued, and a settle
  /// that re-settled itself would be a loop with a model call in it.
  Future<void> _afterPump() async {
    await _attention?.recomputeAll(sources: inboxSources);
    final queued = await _enqueueDrafts();
    if (queued > 0) {
      await _aiWorker?.pump();
    }
    if (!mounted) return;
    await load(syncFirst: false);
  }

  /// Queues a suggested reply for the threads that have earned one. Returns
  /// how many threads it queued one for — what the settle pass reads to decide
  /// whether there is anything new for the AI queue to drain.
  ///
  /// Immediately after the scoring pass, because it reads the scores that pass
  /// just wrote. On EVERY load rather than only after a sync, and that is
  /// cheap: [MessageStore.needsDraftKeys] excludes any thread that already has
  /// a draft, so a thread appears here exactly once, and `requeueWork` only
  /// revives rows that are already `done` or `error`. The queue itself does not
  /// drain until something pumps it, which is the sync path.
  ///
  /// Nothing here sends anything. It writes work rows; the handler behind them
  /// writes text into sqlite.
  ///
  /// It swallows its own failures. The rows are already read by the time this
  /// runs, and letting a failed queue write fall into the "could not read the
  /// local inbox" path would cost the user the mail they can see over a
  /// suggestion they have not asked for yet.
  Future<int> _enqueueDrafts() async {
    try {
      final stored = await _store.getPref(attentionThresholdKey);
      final threshold = (stored == null ? null : double.tryParse(stored)) ??
          AttentionTuning.defaultThreshold;
      var queued = 0;
      for (final row in await _store.needsDraftKeys(threshold: threshold)) {
        await _store.requeueWork('draft', row.source, row.conversationKey);
        queued++;
      }
      return queued;
    } catch (e) {
      debugPrint('draft enqueue failed: $e');
      return 0;
    }
  }

  /// Flips a thread to done, on screen first.
  ///
  /// Optimistic because the write is local and effectively instantaneous —
  /// waiting on it would only add a frame of lag to a button whose whole job
  /// is to feel immediate. A failure puts the row back exactly as it was.
  Future<void> markDone(String conversationKey) async {
    final current = state;
    if (current is! ConversationsLoaded) return;

    // The row's own source, not a literal: with a second connector in the list
    // a hard-coded `'email'` would write the done flag against a thread that
    // does not exist and leave the chat open behind an optimistic tick.
    String? source;
    for (final c in current.conversations) {
      if (c.id == conversationKey) source = c.source;
    }
    if (source == null) return;

    state = current.withRows([
      for (final c in current.conversations)
        if (c.id == conversationKey)
          c.copyWith(state: ConversationState.done)
        else
          c,
    ], current.loadError);

    try {
      await _store.setConversationState(
        source,
        conversationKey,
        ConversationState.done,
      );
      // On the success path only. Closing a thread is the quietest "I am done
      // with this" the user ever gives, and it is worth recording — but recording
      // one for a write that failed would teach the app from something that
      // never happened.
      await _logImplicit('thread', conversationKey, 'down');
    } catch (_) {
      final latest = state;
      if (latest is! ConversationsLoaded) return;
      state = latest.withRows(
        current.conversations,
        "Couldn't save that just now — the thread is unchanged.",
      );
    }
  }

  /// The user opened this thread, so it is read. Locally first and instantly —
  /// the server ack is a queued row somebody else drains.
  ///
  /// Optimistic for [markDone]'s reason, and with the same fallback: the store
  /// is the truth about what is unread, so a failed write is answered by
  /// re-reading it rather than by guessing what the count went back to.
  ///
  /// [source] is passed rather than resolved from the list because the caller
  /// already knows it — the screen resolved the row before it opened it.
  Future<void> markRead(String source, String conversationKey) async {
    final current = state;
    if (current is! ConversationsLoaded) return;

    state = current.withRows([
      for (final c in current.conversations)
        if (c.id == conversationKey && c.source == source)
          c.copyWith(unreadCount: 0)
        else
          c,
    ], current.loadError);

    try {
      await _store.markConversationRead(source, conversationKey);
      // Fire-and-forget, on the success path only: the queue drains the row
      // that write just left, and there is nothing to drain if it did not
      // land. Nothing on screen waits for the ack — the thread is already
      // unbold, and this is the app telling Microsoft about it afterwards.
      final ack = _readAcks?.pump();
      if (ack != null) {
        unawaited(
          ack.catchError((Object e) => debugPrint('read-ack pump failed: $e')),
        );
      }
    } catch (_) {
      await load(syncFirst: false);
    }
  }

  // ── corrections ──────────────────────────────────────────────────────
  //
  // Every explicit correction does the same three things in the same order:
  // record what the person said, apply it, then reload so the list agrees with
  // them in the same frame. The record comes first because it is the part that
  // must survive — an event with no effect is recoverable, an effect nobody
  // wrote down is not.

  /// One sender's mail belongs in the inbox. Returns how many of their threads
  /// came back out of Later.
  ///
  /// [source] is the source whose rows the rule re-files — a Teams sender's
  /// threads live under `teams`, and re-filing the email rows for their
  /// address would move nothing and report zero.
  Future<int> keepSenderInInbox(String address,
      {String source = 'email'}) async {
    await _store.recordFeedback(
      scope: 'sender',
      scopeKey: address.toLowerCase(),
      direction: 'up',
      origin: 'explicit',
    );
    await _store.setSenderPref(address, 'keep');
    final affected =
        await _store.rebucketSender(address, bucket: null, source: source);
    await load(syncFirst: false);
    return affected;
  }

  /// One sender's mail belongs in Later. Returns how many of their threads
  /// moved. [source] as on [keepSenderInInbox].
  Future<int> sendSenderToLater(String address,
      {String source = 'email'}) async {
    await _store.recordFeedback(
      scope: 'sender',
      scopeKey: address.toLowerCase(),
      direction: 'down',
      origin: 'explicit',
    );
    await _store.setSenderPref(address, 'later');
    final affected =
        await _store.rebucketSender(address, bucket: 'later', source: source);
    await load(syncFirst: false);
    return affected;
  }

  /// Puts one sender's rule back where it was, and re-files their threads from
  /// the restored rule. What UNDO calls.
  ///
  /// Approximate, deliberately: it restores the RULE, then re-derives every
  /// affected thread's bucket from it. A thread that was individually deferred
  /// before the correction and then swept up by it comes back to whatever the
  /// restored rule says, not to the bucket it personally had. Undoing a
  /// sender-wide action by replaying a sender-wide action is the only inverse
  /// that stays one statement; remembering per-thread state to restore would
  /// mean a second history table for a button pressed seconds ago.
  Future<void> restoreSenderPref(String address, String? disposition,
      {String source = 'email'}) async {
    await _store.recordFeedback(
      scope: 'sender',
      scopeKey: address.toLowerCase(),
      // An undo is itself a correction, in the opposite direction of whatever
      // it is undoing. Recording it keeps the event log honest: the history
      // says what the person actually did, mistakes included.
      direction: disposition == 'later' ? 'down' : 'up',
      origin: 'explicit',
    );
    await _store.setSenderPref(address, disposition);
    await _store.rebucketSender(
      address,
      bucket: disposition == 'later' ? 'later' : null,
      source: source,
    );
    await load(syncFirst: false);
  }

  /// This one thread belongs in the inbox, whatever its sender's rule says.
  ///
  /// The `user` reason is written on a NULL bucket, which is what makes the
  /// exemption stick: without it the very next load would see the sender rule
  /// still in force and defer the thread again, and the button would look
  /// broken. A later explicit sender-wide correction still overrides it — that
  /// is a newer instruction about a wider set, and the person giving it means
  /// all of that sender's mail.
  Future<void> keepThreadInInbox(String source, String conversationKey) async {
    await _store.recordFeedback(
      scope: 'thread',
      scopeKey: conversationKey,
      direction: 'up',
      origin: 'explicit',
    );
    await _store.setConversationBucket(
      source,
      conversationKey,
      bucket: null,
      reason: 'user',
    );
    await load(syncFirst: false);
  }

  /// This one thread belongs in Later. The `user` reason is what tells the
  /// scoring sweep to leave it alone in both directions.
  Future<void> sendThreadToLater(String source, String conversationKey) async {
    await _store.recordFeedback(
      scope: 'thread',
      scopeKey: conversationKey,
      direction: 'down',
      origin: 'explicit',
    );
    await _store.setConversationBucket(
      source,
      conversationKey,
      bucket: 'later',
      reason: 'user',
    );
    await load(syncFirst: false);
  }

  /// The sender's rule as it stands, so a caller can capture it before
  /// overwriting and hand it back to [restoreSenderPref].
  Future<String?> senderPref(String address) => _store.getSenderPref(address);

  /// Records something the user did rather than something they said — opening a
  /// thread, closing one. Fire-and-forget and never reloads: these fire on
  /// every click, and a list read behind each one would make the app feel
  /// slower for a signal nothing on screen reads yet.
  ///
  /// It swallows its own failures for the same reason. A correction that fails
  /// is worth telling someone about; a background signal that fails is not
  /// worth interrupting them mid-click.
  Future<void> _logImplicit(
    String scope,
    String scopeKey,
    String direction,
  ) async {
    try {
      await _store.recordFeedback(
        scope: scope,
        scopeKey: scopeKey,
        direction: direction,
        origin: 'implicit',
      );
    } catch (_) {
      // Deliberately silent.
    }
  }

  /// The user opened this thread. The weakest positive signal there is, and the
  /// most plentiful.
  Future<void> noteThreadOpened(String conversationKey) =>
      _logImplicit('thread', conversationKey, 'up');
}

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, ConversationsState>(
  (ref) => ConversationsNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(syncServiceProvider),
    teamsSync: ref.watch(teamsSyncProvider),
    triage: ref.watch(triageQueueProvider),
    aiWorker: ref.watch(aiWorkerProvider),
    attention: ref.watch(attentionServiceProvider),
    readAcks: ref.watch(readAckQueueProvider),
    // A future, not a value: the account is a keychain read, and the inbox
    // must not wait on it to render. Until it resolves the self gate is off.
    userAddress: ref.watch(authSessionProvider).storedAccount.then(
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
        // Inert for a Teams thread rather than special-cased: [MailSync]
        // resolves the messages to fetch by loading the thread for source
        // `email`, and a chat id matches none of them. A chat message's body
        // arrives whole with the message, so there is nothing to fill in.
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
      messages =
          await _store.loadThread(conversationKey, sources: inboxSources);
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
