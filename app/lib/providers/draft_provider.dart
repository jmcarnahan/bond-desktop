import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart';
import '../models/message_models.dart' show ConversationState, Message;
import '../services/ai_worker.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/backend_types.dart';
import '../services/backend/mail_backend.dart';
import '../services/backend/teams_backend.dart';
import '../services/graph_mail.dart';
import '../services/graph_teams.dart' show GraphTeamsException;
import '../services/llm/draft_task.dart' show DraftOption;
import '../services/mail_echo.dart' show firstLine, mailEchoRow, nowSecondsZ;
import '../services/outbound_chat.dart'
    show queueRecapFor, writeOutboundChatRow;
import '../services/pipeline_progress.dart';
import '../services/teams_sync.dart' show TeamsSync;
import '../widgets/composer.dart' show SendCapability;
import 'app_providers.dart';
import 'conversations_provider.dart';

/// One conversation's suggested replies, and the send that a person — and only
/// a person — can trigger.
///
/// A suggestion belongs to the MESSAGE it answers, never to the thread: the
/// `drafts` table is keyed on `(source, reply_to_message_id)`, and a thread
/// accumulates one row per message the model drafted for. [DraftState.draft] is
/// simply the one the composer surface shows — the answer to the newest inbound
/// message — while [DraftState.threadDrafts] carries every row the conversation
/// holds, so the transcript can put each suggestion under the message it
/// answers.
///
/// The invariant this file exists to hold: [DraftNotifier.send] is the only
/// method that reaches [GraphMail.sendDraft] or [TeamsBackend.sendChatMessage],
/// nothing inside this file calls it except the undo timer a person started,
/// and it takes the body as an argument rather than reading the stored draft —
/// so a send can only ever carry text that was on screen in front of whoever
/// pressed the button.
///
/// Both arms write the reply into the transcript before returning. A chat
/// stores the message Graph handed back, id and all. Mail stores a `local:`
/// echo built from what `sendDraft` reported, which the Sent Items copy
/// replaces on the next drain, matched on the internet message id — the whole
/// contract is in `mail_echo.dart`. The user watched the reply leave; it is on
/// screen from that moment, and it survives a restart.

/// Which conversation a draft belongs to.
///
/// The source rides along with the key because a conversation key is only
/// unique WITHIN a source — chats will be drafted for too, and a bare key
/// would collide a chat with the mail thread that happens to share it. A
/// record, so the family keys on value rather than identity.
typedef DraftTarget = ({String source, String conversationKey});

/// A send the user has triggered and can still take back: the exact text that
/// will go out, and the moment it will.
///
/// It lives in memory and NOWHERE else. A queued send that a quit interrupts
/// is simply lost, which is the right way round — the opposite would put mail
/// in front of somebody after a restart the user believed had cancelled it.
typedef PendingSend = ({String body, DateTime sendsAt});

/// What one pass over the `drafts` table answers: the row the composer surface
/// shows, and every row the conversation holds keyed by the message it answers.
/// The two always move together — see [DraftNotifier._reloadDrafts].
typedef _DraftRead = ({
  Map<String, Object?>? newest,
  Map<String, Map<String, Object?>> byMessage,
});

/// The short ready-to-send replies stored on one `drafts` row, at most two.
///
/// Top-level because the cards are drawn per MESSAGE now: the transcript reads
/// rows straight out of [DraftState.threadDrafts] and has to answer the same
/// question about each of them, with exactly the same guards the composer's own
/// row gets. Empty for the three states a body reads as absent in — no row,
/// dismissed, sent — plus the fourth that belongs to the options alone: the user
/// closed the cards but kept the draft. Malformed JSON reads as no options; a
/// row written by a version that did not have them reads the same way.
List<DraftOption> draftOptionsOf(Map<String, Object?> row) {
  final status = row['status'] as String?;
  if (status == 'dismissed' || status == 'sent') return const [];
  if ((row['options_dismissed'] as int? ?? 0) == 1) return const [];
  final raw = row['options_json'] as String? ?? '';
  if (raw.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  return [
    for (final entry in decoded)
      if (entry is Map)
        DraftOption(
          stance: (entry['stance'] as Object?)?.toString() ?? '',
          body: (entry['body'] as Object?)?.toString() ?? '',
        ),
  ];
}

/// What a send actually did, so the screen can say so.
enum SendOutcome {
  /// The reply left the building.
  sent,

  /// Saved to Outlook Drafts and opened there — what a `Mail.ReadWrite`-only
  /// grant can manage.
  savedToOutlook,

  /// Copied to the clipboard, which is all an unconsented build can do.
  copied,

  /// Nothing happened; [DraftState.error] says why.
  failed,
}

@immutable
class DraftState {
  /// The stored `drafts` row the composer surface is holding: the answer to the
  /// thread's newest inbound message, or null when that message has none.
  ///
  /// One row out of [threadDrafts], not the thread's whole answer — a draft
  /// belongs to the message it answers, and this is the one the reply box would
  /// open with.
  final Map<String, Object?>? draft;

  /// Every suggestion this conversation holds, keyed by the message it answers
  /// — `reply_to_message_id`, which is exactly a `Message.id`.
  ///
  /// Whatever their status: a sent or dismissed row is still what happened to
  /// that message, and the transcript is the layer that decides which of them
  /// are still worth drawing.
  final Map<String, Map<String, Object?>> threadDrafts;

  /// A draft is being written right now.
  final bool generating;

  /// A send is in flight. The composer's button disables on this, which is
  /// what stops a double click sending twice.
  final bool sending;

  /// What this build's Entra grant permits. Starts at [SendCapability.copyOnly]
  /// — the safe answer before the keychain has been read, and the only one that
  /// cannot fail.
  final SendCapability capability;

  /// Shown above the composer. Cleared by the next action.
  final String? error;

  /// Bumped once per SUCCESSFUL send, and only then. The screen keys the
  /// composer on it, so a completed send rebuilds a fresh empty reply box —
  /// the sent text must not sit there behind a re-enabled button, one stray
  /// click from going out a second time.
  final int sendEpoch;

  /// Non-null exactly while an undo window is open — a send the user has asked
  /// for that has not left yet.
  final PendingSend? pending;

  /// The text of a send that has left the undo window but has not finished
  /// landing — set when the timer fires, cleared once the send returns.
  ///
  /// It exists so the bubble the undo window was showing OUTLIVES the network
  /// call. Without it the reply blinks out at the moment [pending] clears and
  /// blinks back when the stored row arrives, which reads as a send that
  /// failed. Read through [bubbleBody], never directly.
  final String? inFlightBody;

  const DraftState({
    this.draft,
    this.threadDrafts = const {},
    this.generating = false,
    this.sending = false,
    this.capability = SendCapability.copyOnly,
    this.error,
    this.sendEpoch = 0,
    this.pending,
    this.inFlightBody,
  });

  /// The optimistic bubble to draw under [messages], or null for none.
  ///
  /// One unbroken bubble from the click to the stored row, and — this is the
  /// half a bare `pending ?? inFlightBody` gets wrong — exactly ONE copy of
  /// the reply on screen at a time. Both send arms store their row BEFORE
  /// `onSent`, and the screen re-reads the transcript on the epoch bump, so
  /// the row can arrive while the send is still finishing its list sync.
  /// Without this check the user would see their reply twice for the length of
  /// that sync, which can be seconds.
  ///
  /// Matched on the body rather than on an id, because the id is the one thing
  /// the two do not share: the bubble never had one, and the row's is either a
  /// `local:` echo or, once the drain has been through, the server's.
  String? bubbleBody(List<Message> messages) {
    final queued = pending?.body;
    if (queued != null) return queued;
    final body = inFlightBody;
    if (body == null) return null;
    for (final message in messages) {
      if (message.outbound && message.bodyText == body) return null;
    }
    return body;
  }

  /// The draft's body, or null when there is none. A dismissed draft reads as
  /// no draft: the row survives so the enqueue does not immediately write
  /// another, but the composer must show an empty box. A SENT draft reads the
  /// same way — the reply is out, and offering its text again is how a
  /// duplicate gets sent.
  String? get body {
    final row = draft;
    if (row == null) return null;
    final status = row['status'] as String?;
    if (status == 'dismissed' || status == 'sent') return null;
    final text = row['body'] as String? ?? '';
    return text.isEmpty ? null : text;
  }

  /// The stored inventory of what this draft was written from — the D11 JSON
  /// the handler wrote. Null on a draft written before there was one, which
  /// is what leaves the composer on its constant caption.
  String? get contextJson {
    final value = draft?['context_json'] as String? ?? '';
    return value.isEmpty ? null : value;
  }

  /// The model's one-sentence account of what this reply answers, for the
  /// provenance tooltip.
  String? get evidence {
    final value = draft?['evidence'] as String? ?? '';
    return value.isEmpty ? null : value;
  }

  /// The short ready-to-send replies on the composer's own row, at most two.
  /// [draftOptionsOf] answers the same question for every other message's row.
  List<DraftOption> get options {
    final row = draft;
    if (row == null) return const [];
    return draftOptionsOf(row);
  }

  /// Whether "Suggest a reply" may run [DraftNotifier.generate] here. The
  /// question is about [draft] alone — generate answers the newest inbound
  /// message, so the row it would overwrite is that message's: only one whose
  /// suggestions were closed — status 'dismissed', or a 'suggested' row whose
  /// cards were waved off — or a message never drafted for at all.
  /// An 'edited' row is the user's own words and a 'sent' one is history;
  /// generate() deletes the row, so offering it beside either would offer to
  /// destroy it.
  bool get suggestable {
    final row = draft;
    if (row == null) return true;
    final status = row['status'] as String?;
    return status == 'dismissed' ||
        (status == 'suggested' && (row['options_dismissed'] as int? ?? 0) == 1);
  }

  String? get graphDraftId => draft?['graph_draft_id'] as String?;

  String? get replyToMessageId => draft?['reply_to_message_id'] as String?;

  DraftState copyWith({
    Object? draft = _unset,
    Map<String, Map<String, Object?>>? threadDrafts,
    bool? generating,
    bool? sending,
    SendCapability? capability,
    Object? error = _unset,
    int? sendEpoch,
    Object? pending = _unset,
    Object? inFlightBody = _unset,
  }) =>
      DraftState(
        draft: identical(draft, _unset)
            ? this.draft
            : draft as Map<String, Object?>?,
        threadDrafts: threadDrafts ?? this.threadDrafts,
        generating: generating ?? this.generating,
        sending: sending ?? this.sending,
        capability: capability ?? this.capability,
        error: identical(error, _unset) ? this.error : error as String?,
        sendEpoch: sendEpoch ?? this.sendEpoch,
        pending: identical(pending, _unset)
            ? this.pending
            : pending as PendingSend?,
        inFlightBody: identical(inFlightBody, _unset)
            ? this.inFlightBody
            : inFlightBody as String?,
      );

  /// Separates "not passed" from "passed as null" on [copyWith], where the two
  /// mean opposite things for every nullable field.
  static const Object _unset = Object();
}

class DraftNotifier extends StateNotifier<DraftState> {
  /// Matches the inbox's own reload debounce: the worker reports every item it
  /// finishes, and a full re-read behind each one would be a burst of queries
  /// for one row.
  static const Duration _reloadDelay = Duration(milliseconds: 400);

  /// How long a queued send stays undoable. The snackbar reads its duration
  /// FROM here so the bar cannot outlive the window it offers to cancel.
  static const Duration undoWindow = Duration(seconds: 5);

  final MessageStore _store;
  final AuthSession _auth;
  final MailBackend _mail;

  /// Where a chat reply goes. Optional because only the Teams branch of [send]
  /// reads it, so every test that exercises a mail draft can leave it out —
  /// and a chat that reached [send] without one is a wiring bug, which is why
  /// that branch throws rather than degrading.
  final TeamsBackend? _teams;

  final AiWorker? _worker;

  /// Where the needs-you exit is recorded when a reply leaves FROM HERE.
  ///
  /// The sync's `resolvesAsk` arm covers a reply sent anywhere else, but it
  /// cannot cover this one for chats: the chat send writes its own outbound
  /// row, and the next pull deliberately skips a row it already has — so the
  /// fold that would have cleared the chip never runs. Mail would only be a
  /// sync late, but late for mail and never for chats are both worse than
  /// saying it now.
  final PipelineProgress _pipeline;

  /// Called after a successful send, so the sent message folds in from
  /// `sentitems` on the next sync and the thread stops saying it needs a
  /// reply. Null in tests that exercise the draft alone.
  final Future<void> Function()? _onSent;

  /// Opens a URL. Injected so a test can assert the Outlook hand-off without a
  /// browser.
  final Future<bool> Function(Uri url) _launch;

  /// Which source's conversation this is — `email` today, and the reason the
  /// family key carries it.
  final String _source;

  final String conversationKey;

  /// This notifier's own copy of [undoWindow]. Injectable so a test can hold a
  /// fifty-millisecond window instead of blocking a suite for five seconds per
  /// send; production never passes it.
  final Duration _undoWindow;

  StreamSubscription<WorkProgress>? _progress;
  Timer? _reload;
  Timer? _pendingSend;

  DraftNotifier(
    this._store,
    this._auth,
    this._mail,
    DraftTarget target, {
    this._teams,
    AiWorker? worker,
    this._pipeline = const PipelineProgress.disabled(),
    this._onSent,
    Future<bool> Function(Uri url)? launch,
    Duration? undoWindow,
  })  : _source = target.source,
        conversationKey = target.conversationKey,
        _worker = worker,
        _undoWindow = undoWindow ?? DraftNotifier.undoWindow,
        _launch = launch ??
            ((url) => launchUrl(url, mode: LaunchMode.externalApplication)),
        super(const DraftState()) {
    _progress = worker?.progress.listen((progress) {
      if (progress.kind != 'draft') return;
      _scheduleReload();
    });
    // Reading is the only thing construction does. A composer that appears
    // holding the draft the queue already wrote is the point of caching it;
    // asking for a NEW one is always somebody's click.
    unawaited(load());
  }

  void _scheduleReload() {
    _reload?.cancel();
    _reload = Timer(_reloadDelay, () {
      if (mounted) load();
    });
  }

  @override
  void dispose() {
    _reload?.cancel();
    _progress?.cancel();
    // Cancelled, NOT flushed. A thread closing while an undo window is open
    // takes the queued reply with it: the last thing the user did was navigate
    // away, and firing a send on the way out is the one behaviour nobody could
    // have taken back.
    _pendingSend?.cancel();
    super.dispose();
  }

  /// Reads the stored draft and what this build may do with it. Never throws:
  /// a database or keychain failure leaves the composer usable and unarmed.
  Future<void> load() async {
    final read = await _readDrafts();
    // The read is a round trip now, and this notifier can be disposed across
    // one — a thread closed while its draft was being read.
    if (!mounted) return;
    // Whatever was being generated has landed, or has stopped.
    final settled = read.newest != null && read.newest!['body'] != null;
    state = state.copyWith(
      draft: read.newest,
      threadDrafts: read.byMessage,
      generating: settled ? false : state.generating,
    );

    final capability = await _capability();
    if (!mounted) return;
    state = state.copyWith(capability: capability);
  }

  /// Re-reads both views of this conversation's suggestions after a write.
  ///
  /// Both, always: the composer's row and the transcript's cards come out of
  /// the same table, and refreshing one alone is how an inline card goes on
  /// offering options a dismissal already closed.
  Future<void> _reloadDrafts() async {
    final read = await _readDrafts();
    if (!mounted) return;
    state = state.copyWith(draft: read.newest, threadDrafts: read.byMessage);
  }

  /// The two reads behind every refresh: the newest inbound message's
  /// suggestion, and every suggestion the conversation holds. A read that
  /// throws answers with what state already had, which is what keeps [load]'s
  /// never-throws contract.
  Future<_DraftRead> _readDrafts() async {
    try {
      final newest = await _store.getDraft(_source, conversationKey);
      final rows =
          await _store.draftsForConversation(_source, conversationKey);
      return (
        newest: newest,
        byMessage: {
          for (final row in rows)
            if ((row['reply_to_message_id'] as String? ?? '').isNotEmpty)
              row['reply_to_message_id'] as String: row,
        },
      );
    } catch (_) {
      return (newest: state.draft, byMessage: state.threadDrafts);
    }
  }

  /// Which stored draft row this pane is holding: the message it answers, or
  /// null when there is no suggestion to write to.
  ///
  /// Every write to `drafts` goes through this. The table is keyed on the
  /// message, so a write addressed by conversation would land on every
  /// suggestion the thread has ever collected — including the answers to
  /// messages the user did nothing about.
  String? get _draftKey {
    if (state.draft == null) return null;
    final id = state.replyToMessageId;
    return (id == null || id.isEmpty) ? null : id;
  }

  /// The best thing this grant can do with a reply. Falls to
  /// [SendCapability.copyOnly] on any failure, which is the rung that needs no
  /// permission at all.
  ///
  /// A chat has two rungs rather than three: there is no Outlook drafts folder
  /// to hand a Teams message off to, so the ladder is send-or-copy. It is also
  /// what decides whether a chat thread gets a reply surface at all — the
  /// screen renders one for a chat only on the top rung, so a grant without
  /// `Chat.ReadWrite` sees the honest caption instead of a box that could not
  /// send.
  Future<SendCapability> _capability() async {
    try {
      if (_source == 'teams') {
        return await _auth.hasScope('chat.readwrite')
            ? SendCapability.send
            : SendCapability.copyOnly;
      }
      if (await _auth.hasScope('mail.send')) return SendCapability.send;
      if (await _auth.hasScope('mail.readwrite')) {
        return SendCapability.draftToOutlook;
      }
    } on Object {
      // A keychain that will not open is not a reason to hide the composer.
    }
    return SendCapability.copyOnly;
  }

  /// Asks for a draft, or for a different one.
  ///
  /// The work is keyed on the MESSAGE, so this resolves the thread's newest
  /// inbound one first — the same message the handler would have answered, and
  /// the same message this pane is showing a suggestion for.
  ///
  /// The requeue is what makes Regenerate work at all: the work row for a
  /// message that has already been drafted is `done`, and `enqueueWork` would
  /// ignore it forever. The existing draft is deleted first for the same
  /// reason — the handler returns early when one is already stored.
  ///
  /// [pinnedAttachmentIds] is "Use in reply" and [contextFileIds] is "Consult
  /// for the reply": the documents and the directory files the user named,
  /// carried to the handler on the work row's payload so each retriever floats
  /// what it was told about to the front of what it quotes. A plain Regenerate
  /// passes neither, and the requeue OVERWRITES the payload — asking again
  /// without naming a file has to mean the last file is no longer named, and
  /// that rule now covers both lists.
  ///
  /// The payload carries only the keys that have something in them, so a
  /// consulted file and a pinned document never have to be asked for together
  /// to be asked for at all.
  Future<void> generate({
    List<String> pinnedAttachmentIds = const [],
    List<int> contextFileIds = const [],
  }) async {
    if (state.generating) return;
    state = state.copyWith(generating: true, error: null);
    try {
      final newest =
          await _store.newestInboundMessage(_source, conversationKey);
      final messageId = newest?['source_message_id'] as String?;
      if (messageId == null || messageId.isEmpty) {
        // A thread of the user's own sent mail, or one whose messages are not
        // stored. There is nothing to answer, which is a sentence rather than
        // a spinner that never stops.
        state = state.copyWith(
          generating: false,
          error: 'There is nothing to reply to in this thread yet.',
        );
        return;
      }
      await _store.deleteDraftForMessage(_source, messageId);
      await _store.requeueWork(
        'draft',
        _source,
        messageId,
        payloadJson:
            (pinnedAttachmentIds.isEmpty && contextFileIds.isEmpty)
                ? null
                : jsonEncode({
                    if (pinnedAttachmentIds.isNotEmpty)
                      'pinned_attachment_ids': pinnedAttachmentIds,
                    if (contextFileIds.isNotEmpty)
                      'context_file_ids': contextFileIds,
                  }),
      );
    } catch (e) {
      state = state.copyWith(
        generating: false,
        error: 'Could not ask for a draft: $e',
      );
      return;
    }
    state = state.copyWith(draft: null);

    final pump = _worker?.pump();
    if (pump == null) {
      state = state.copyWith(generating: false);
      return;
    }
    // Not awaited: the queue drains several kinds of work and this thread's
    // draft usually lands long before it finishes. The progress subscription
    // above reloads the moment it does; this only makes sure the spinner stops
    // when the drain gives up — a model server that is not running parks the
    // queue in about a millisecond.
    unawaited(
      pump.whenComplete(() {
        if (mounted) state = state.copyWith(generating: false);
      }),
    );
  }

  /// The user changed the text. Records it so the suggestion stops being the
  /// model's — and so a reopened thread shows what they typed, not what was
  /// suggested.
  Future<void> markEdited(String body) async {
    // The row this pane is showing, by the message it answers — every write
    // below keys on that, because a thread-scoped one would rewrite the
    // answers to every message the thread ever collected.
    final replyTo = _draftKey;
    if (replyTo == null) return;
    // A sent reply's record must never be rewritten to "edited" by the
    // composer's trailing debounce — what reached the recipient is what the
    // row has to keep saying was sent.
    if ((state.draft?['status'] as String?) == 'sent') return;
    try {
      await _store.updateDraftStatus(
        _source,
        replyTo,
        status: 'edited',
        body: body,
      );
    } catch (_) {
      // The text is still on screen and still sendable. A failed autosave is
      // not worth a banner over a composer the user is mid-sentence in.
      return;
    }
    await _reloadDrafts();
  }

  /// Throws the suggestion away. The row stays, marked `dismissed`, so the
  /// enqueue on the next list load does not immediately write another one.
  Future<void> dismiss() async {
    final replyTo = _draftKey;
    if (replyTo == null) return;
    await _store.updateDraftStatus(
      _source,
      replyTo,
      status: 'dismissed',
    );
    await _reloadDrafts();
    if (!mounted) return;
    state = state.copyWith(error: null);
  }

  /// Closes the short replies and leaves the draft alone. The row survives so
  /// the next enqueue does not write the same two cards straight back.
  Future<void> dismissOptions() async {
    final replyTo = _draftKey;
    if (replyTo == null) return;
    await _store.dismissDraftOptions(_source, replyTo);
    await _reloadDrafts();
    if (!mounted) return;
    state = state.copyWith(error: null);
  }

  /// Closes one message's suggestion cards — the inline card's ×.
  ///
  /// Addressed by the message rather than by the thread because that is what
  /// the user closed: a transcript can be showing several cards at once, and a
  /// dismissal that landed on [_draftKey] would take the newest message's cards
  /// away whichever card the × belonged to.
  Future<void> dismissOptionsFor(String replyToMessageId) async {
    if (replyToMessageId.isEmpty) return;
    await _store.dismissDraftOptions(_source, replyToMessageId);
    await _reloadDrafts();
    if (!mounted) return;
    state = state.copyWith(error: null);
  }

  /// Arms [send] to run in [undoWindow], and shows that it is armed.
  ///
  /// This is what a quick-reply card does, and it does not widen what the app
  /// can do: [send] is still the only code that reaches the network, it is
  /// still behind a human's click, and for five seconds that click is
  /// reversible. NOTHING is persisted — see [PendingSend] — so a queued send
  /// an app quit interrupts is lost rather than delivered later.
  ///
  /// Refused while a send is in flight or another is already queued: a second
  /// pending send would need a second undo, and the bar only offers one.
  ///
  /// [replyTo] is the message the card that armed this belongs to. It rides in
  /// the timer's closure rather than on [PendingSend], which stays exactly what
  /// the undo row needs to draw: the text and the moment it goes.
  Future<void> queueSend(String body, {String? replyTo}) async {
    if (state.sending || state.pending != null) return;
    final text = body.trim();
    if (text.isEmpty) return;

    state = state.copyWith(
      pending: (body: text, sendsAt: DateTime.now().add(_undoWindow)),
      error: null,
    );
    _pendingSend?.cancel();
    _pendingSend = Timer(_undoWindow, () {
      if (!mounted) return;
      // Cleared FIRST, so [cancelQueuedSend] arriving a millisecond late is a
      // no-op against a send already on the wire rather than a cancel that
      // appears to have worked. The text moves across to [inFlightBody] in the
      // same write: the two together are what keep one unbroken bubble on
      // screen from the click to the stored row.
      state = state.copyWith(pending: null, inFlightBody: text);
      unawaited(send(text, replyTo: replyTo));
    });
  }

  /// Takes back a queued send. Idempotent, and safe after the window has
  /// closed — the timer clears the pending state before it sends, so a late
  /// undo cancels nothing rather than half-cancelling a reply that has gone.
  void cancelQueuedSend() {
    _pendingSend?.cancel();
    _pendingSend = null;
    if (state.pending == null) return;
    state = state.copyWith(pending: null);
  }

  /// Sends, saves, or copies [body] — whichever this grant allows.
  ///
  /// **The only path in this app that puts mail in front of another person.**
  /// It is called from exactly one place: the composer's primary button. There
  /// is no timer here, nothing calls it on a state change, and it takes the
  /// body as an argument rather than reading the stored draft, so what goes out
  /// is what was on screen.
  ///
  /// [replyTo] names the message being answered, for a card that belongs to one
  /// — the transcript draws a card under every message that still has a live
  /// suggestion, and a reply armed from an older one must go to that message
  /// rather than to whatever the thread's newest is.
  Future<SendOutcome> send(String body, {String? replyTo}) async {
    final text = body.trim();
    if (text.isEmpty || state.sending) return SendOutcome.failed;

    if (state.capability == SendCapability.copyOnly) {
      await Clipboard.setData(ClipboardData(text: text));
      // Nothing left the machine, so nothing is in flight. Cleared explicitly
      // because a queued send that lands on this rung set the bubble on its
      // way here, and a clipboard copy must not leave one hanging.
      if (mounted) state = state.copyWith(inFlightBody: null);
      return SendOutcome.copied;
    }

    // Before the mail path, because none of it applies: a chat has no draft to
    // create, no message to reply TO, and no Outlook rung to fall back to.
    if (_source == 'teams') return _sendChat(text, replyTo: replyTo);

    // The card's own message first, then the composer's row. A thread only
    // earns a generated draft when it ranks high enough, but the user can reply
    // to ANY thread — so a missing draft row falls back to the newest inbound
    // message, which is exactly what the draft handler itself replies to.
    var target = replyTo;
    if (target == null || target.isEmpty) target = state.replyToMessageId;
    if (target == null || target.isEmpty) {
      final newest = await _store.newestInboundMessage(_source, conversationKey);
      target = newest?['source_message_id'] as String?;
    }
    if (target == null || target.isEmpty) {
      state = state.copyWith(
        error: 'There is nothing to reply to in this thread yet.',
      );
      return SendOutcome.failed;
    }

    state = state.copyWith(sending: true, error: null);
    try {
      final draft = await _mail.createReplyDraft(target);
      final draftId = draft['id'] as String? ?? '';
      final webLink = draft['webLink'] as String?;
      if (draftId.isEmpty) {
        throw const GraphMailException(
          'Microsoft Graph created a draft with no id.',
        );
      }
      await _mail.updateDraftBody(draftId, text);

      if (state.capability == SendCapability.draftToOutlook) {
        return await _handOffToOutlook(target, draftId, webLink, text);
      }

      final sent = await _mail.sendDraft(draftId);
      // Read AFTER the send, and never allowed to fail it: the reply has gone,
      // and a keychain that will not open is no reason to report a sent reply
      // as failed. An echo with no owner renders as `You` like every other
      // outbound row, so the only thing a null costs is the sender column.
      AccountInfo? owner;
      try {
        owner = await _auth.storedAccount;
      } catch (_) {
        owner = null;
      }
      // On screen NOW, from what the server said went out. The reply is real
      // mail the moment `sendDraft` returns; waiting a minute for `sentitems`
      // to confirm it reads as a send that failed, and gets sent again.
      //
      // The write is refused when the Sent Items copy has already landed — a
      // poll that started before this send can beat it — and is replaced by
      // that copy when it does land, matched on the internet message id. See
      // `mail_echo.dart` for the whole contract.
      await _store.insertLocalEcho(mailEchoRow(
        sent: sent,
        text: text,
        conversationKey: conversationKey,
        owner: owner,
      ));
      // Counts alone would leave the thread where it was in the rail, still
      // previewing the message it just answered — and it would never heal,
      // because the fold below is the only one this row will ever get.
      await _store.foldOutboundSend(
        _source,
        conversationKey,
        receivedAt: sent.sentAt ?? nowSecondsZ(),
        preview: firstLine(text),
        subject: sent.subject,
      );
      await _queueRecap();
      // Keyed on the message just replied to — which is the message the stored
      // draft answers whenever there is one, and the newest inbound message
      // when there is not. A thread with no suggestion has no row to update
      // and this write lands on nothing, which is the same as it always was.
      await _store.updateDraftStatus(
        _source,
        target,
        status: 'sent',
        body: text,
        graphDraftId: draftId,
      );
      // The strongest positive signal the app collects, and implicit rather
      // than explicit: the user did not press a rating, they answered the mail.
      await _logSent();
      // The reply leaving IS the needs-you exit, and it says so now rather
      // than whenever the next sync gets around to folding the sent copy in.
      // Both writes are idempotent: the sync's own fold to `waiting` lands on
      // a thread already there, and clearing the CTA is exactly what "the ask
      // was answered" means — the user just answered it.
      await _store.setConversationState(
        _source,
        conversationKey,
        ConversationState.waiting,
      );
      await _store.clearCta(_source, conversationKey);
      // The chip goes with the CTA — from here, not a sync later. The sync's
      // own `resolvesAsk` clear will land on rows already at zero.
      await _pipeline.clearNeedsYou(_source, conversationKey);
      await _reloadDrafts();
      state = state.copyWith(
        sending: false,
        sendEpoch: state.sendEpoch + 1,
      );
      // The list, last: everything this thread needed has already been
      // written, and the echo above is what the transcript shows until the
      // Sent Items copy folds in and takes its place.
      await _onSent?.call();
      return SendOutcome.sent;
    } on AuthException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return SendOutcome.failed;
    } on GraphMailException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return SendOutcome.failed;
    } catch (e) {
      state = state.copyWith(sending: false, error: 'Could not send: $e');
      return SendOutcome.failed;
    } finally {
      // The stored row is already in place by here, so [DraftState.bubbleBody]
      // takes over the moment the transcript re-reads. On a failure it clears
      // too: the error is on the inline alert, and a bubble beside it would
      // say the opposite.
      if (mounted) state = state.copyWith(inFlightBody: null);
    }
  }

  /// Posts [text] to a chat and writes the reply into the transcript.
  ///
  /// A chat post answers with the message Graph stored, id and all, so the row
  /// written here is byte for byte the row the next pull would have folded —
  /// [TeamsSync.messageRow] builds both. That shared id is what makes the fold
  /// happen exactly once: `TeamsSync` asks [MessageStore.hasMessage] before
  /// folding, sees this row, and counts the reply as history rather than as
  /// news that reopens the thread.
  ///
  /// Mail writes its own row too now, but a PROVISIONAL one: `sendDraft`
  /// answers with the ids of a draft that no longer exists, so the mail arm
  /// stores a `local:` echo that the Sent Items copy replaces on the next
  /// drain. A chat reply never needs replacing — see `mail_echo.dart`.
  Future<SendOutcome> _sendChat(String text, {String? replyTo}) async {
    final teams = _teams;
    if (teams == null) {
      // Wiring, not a runtime condition: `draftProvider` always supplies the
      // backend, and nothing but this branch reads it.
      throw StateError('A chat draft was built without a Teams backend.');
    }

    state = state.copyWith(sending: true, error: null);
    try {
      final sent = await teams.sendChatMessage(conversationKey, text);
      // The row, the fold and the recap, all in the writer compose-new shares
      // — see `outbound_chat.dart` for why a chat's own row is written here at
      // all, and for the null the writer answers when Graph hands back
      // something that is not a chat message.
      await writeOutboundChatRow(_store, sent, conversationKey, text);
      // A chat send never marked a draft row before. That was fine while only
      // the newest suggestion was tappable — the row it would have marked was
      // the only one on screen — and it is wrong now that an older message's
      // card can send: without this, that card's row stays 'suggested' and the
      // transcript offers the reply again straight after it went.
      if (replyTo != null && replyTo.isNotEmpty) {
        await _store.updateDraftStatus(
          _source,
          replyTo,
          status: 'sent',
          body: text,
        );
      }
      // Same two writes the mail path makes, and for the same reason: the reply
      // leaving IS the needs-you exit and the CTA's answer, said now rather
      // than whenever the user next refreshes Teams — which, under Microsoft's
      // polling terms, may be a while.
      await _store.setConversationState(
        _source,
        conversationKey,
        ConversationState.waiting,
      );
      await _store.clearCta(_source, conversationKey);
      // For a chat this clear can ONLY happen here: the outbound row written
      // above is one the next pull deliberately skips as already-seen, so the
      // sync's `resolvesAsk` arm never runs for it and a chip left to that
      // path would never come off.
      await _pipeline.clearNeedsYou(_source, conversationKey);
      await _logSent();
      await _reloadDrafts();
      state = state.copyWith(
        sending: false,
        sendEpoch: state.sendEpoch + 1,
      );
      await _onSent?.call();
      return SendOutcome.sent;
    } on AuthException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return SendOutcome.failed;
    } on GraphTeamsException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
      return SendOutcome.failed;
    } catch (e) {
      state = state.copyWith(sending: false, error: 'Could not send: $e');
      return SendOutcome.failed;
    } finally {
      // Same rule as the mail arm: the row is stored by here, so
      // [DraftState.bubbleBody] hands the bubble over rather than dropping it.
      if (mounted) state = state.copyWith(inFlightBody: null);
    }
  }

  /// Wakes the recap of every storyline this thread is filed in, because the
  /// user just changed the answer to the question a recap exists to ask.
  ///
  /// The mail arm's call; the chat arm reaches the same code through
  /// [writeOutboundChatRow]. The reasoning lives with the function in
  /// `outbound_chat.dart`.
  Future<void> _queueRecap() =>
      queueRecapFor(_store, _source, conversationKey);

  /// `Mail.ReadWrite` without `Mail.Send`: the reply exists in Outlook and the
  /// user finishes it there. The stored draft stays `suggested` — it was not
  /// sent, and marking it so would be a lie the next reader acts on.
  Future<SendOutcome> _handOffToOutlook(
    String replyToMessageId,
    String draftId,
    String? webLink,
    String text,
  ) async {
    await _store.updateDraftStatus(
      _source,
      replyToMessageId,
      status: 'suggested',
      body: text,
      graphDraftId: draftId,
      webLink: webLink,
    );
    await _reloadDrafts();
    state = state.copyWith(sending: false);
    if (webLink != null && webLink.isNotEmpty) {
      final uri = Uri.tryParse(webLink);
      if (uri != null) await _launch(uri);
    }
    return SendOutcome.savedToOutlook;
  }

  Future<void> _logSent() async {
    try {
      await _store.recordFeedback(
        scope: 'thread',
        scopeKey: conversationKey,
        direction: 'up',
        origin: 'implicit',
      );
    } catch (_) {
      // Deliberately silent — the reply already went.
    }
  }
}

/// Deliberately NOT autoDispose, matching `threadProvider`: clicking back to a
/// thread should show the draft that was already written for it.
final draftProvider =
    StateNotifierProvider.family<DraftNotifier, DraftState, DraftTarget>(
  (ref, target) => DraftNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(authSessionProvider),
    ref.watch(mailBackendProvider),
    target,
    teams: ref.watch(teamsBackendProvider),
    worker: ref.watch(aiWorkerProvider),
    pipeline: ref.watch(pipelineProgressProvider),
    onSent: () => ref.read(conversationsProvider.notifier).load(),
  ),
);
