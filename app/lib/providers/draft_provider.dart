import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart';
import '../services/ai_worker.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/backend_types.dart';
import '../services/backend/mail_backend.dart';
import '../services/graph_mail.dart';
import '../widgets/composer.dart' show SendCapability;
import 'app_providers.dart';
import 'conversations_provider.dart';

/// One conversation's suggested reply, and the send that a person — and only a
/// person — can trigger.
///
/// The invariant this file exists to hold: [DraftNotifier.send] is the only
/// method that reaches [GraphMail.sendDraft], it is not called from anywhere
/// inside this file, and it takes the body as an argument rather than reading
/// the stored draft — so a send can only ever carry text that was on screen in
/// front of whoever pressed the button.

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
  /// The stored `drafts` row, or null when this conversation has no
  /// suggestion.
  final Map<String, Object?>? draft;

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

  const DraftState({
    this.draft,
    this.generating = false,
    this.sending = false,
    this.capability = SendCapability.copyOnly,
    this.error,
    this.sendEpoch = 0,
  });

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

  /// The model's one-sentence account of what this reply answers, for the
  /// provenance tooltip.
  String? get evidence {
    final value = draft?['evidence'] as String? ?? '';
    return value.isEmpty ? null : value;
  }

  String? get graphDraftId => draft?['graph_draft_id'] as String?;

  String? get replyToMessageId => draft?['reply_to_message_id'] as String?;

  DraftState copyWith({
    Object? draft = _unset,
    bool? generating,
    bool? sending,
    SendCapability? capability,
    Object? error = _unset,
    int? sendEpoch,
  }) =>
      DraftState(
        draft: identical(draft, _unset)
            ? this.draft
            : draft as Map<String, Object?>?,
        generating: generating ?? this.generating,
        sending: sending ?? this.sending,
        capability: capability ?? this.capability,
        error: identical(error, _unset) ? this.error : error as String?,
        sendEpoch: sendEpoch ?? this.sendEpoch,
      );

  /// Separates "not passed" from "passed as null" on [copyWith], where the two
  /// mean opposite things for both nullable fields.
  static const Object _unset = Object();
}

class DraftNotifier extends StateNotifier<DraftState> {
  static const String _source = 'email';

  /// Matches the inbox's own reload debounce: the worker reports every item it
  /// finishes, and a full re-read behind each one would be a burst of queries
  /// for one row.
  static const Duration _reloadDelay = Duration(milliseconds: 400);

  final MessageStore _store;
  final AuthSession _auth;
  final MailBackend _mail;
  final AiWorker? _worker;

  /// Called after a successful send, so the sent message folds in from
  /// `sentitems` on the next sync and the thread stops saying it needs a
  /// reply. Null in tests that exercise the draft alone.
  final Future<void> Function()? _onSent;

  /// Opens a URL. Injected so a test can assert the Outlook hand-off without a
  /// browser.
  final Future<bool> Function(Uri url) _launch;

  final String conversationKey;

  StreamSubscription<WorkProgress>? _progress;
  Timer? _reload;

  DraftNotifier(
    this._store,
    this._auth,
    this._mail,
    this.conversationKey, {
    AiWorker? worker,
    Future<void> Function()? onSent,
    Future<bool> Function(Uri url)? launch,
  })  : _worker = worker,
        _onSent = onSent,
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
    super.dispose();
  }

  /// Reads the stored draft and what this build may do with it. Never throws:
  /// a database or keychain failure leaves the composer usable and unarmed.
  Future<void> load() async {
    Map<String, Object?>? row;
    try {
      row = await _store.getDraft(_source, conversationKey);
    } catch (_) {
      row = state.draft;
    }
    // The read is a round trip now, and this notifier can be disposed across
    // one — a thread closed while its draft was being read.
    if (!mounted) return;
    // Whatever was being generated has landed, or has stopped.
    final settled = row != null && row['body'] != null;
    state = state.copyWith(
      draft: row,
      generating: settled ? false : state.generating,
    );

    final capability = await _capability();
    if (!mounted) return;
    state = state.copyWith(capability: capability);
  }

  /// The best thing this grant can do with a reply. Falls to
  /// [SendCapability.copyOnly] on any failure, which is the rung that needs no
  /// permission at all.
  Future<SendCapability> _capability() async {
    try {
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
  /// The requeue is what makes Regenerate work at all: the work row for a
  /// thread that has already been drafted is `done`, and `enqueueWork` would
  /// ignore it forever. The existing draft is deleted first for the same
  /// reason — the handler returns early when one is already stored.
  Future<void> generate() async {
    if (state.generating) return;
    state = state.copyWith(generating: true, error: null);
    try {
      await _store.deleteDraft(_source, conversationKey);
      await _store.requeueWork('draft', _source, conversationKey);
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

  /// The LO changed the text. Records it so the suggestion stops being the
  /// model's — and so a reopened thread shows what they typed, not what was
  /// suggested.
  Future<void> markEdited(String body) async {
    if (state.draft == null) return;
    // A sent reply's record must never be rewritten to "edited" by the
    // composer's trailing debounce — what reached the recipient is what the
    // row has to keep saying was sent.
    if ((state.draft?['status'] as String?) == 'sent') return;
    try {
      await _store.updateDraftStatus(
        _source,
        conversationKey,
        status: 'edited',
        body: body,
      );
    } catch (_) {
      // The text is still on screen and still sendable. A failed autosave is
      // not worth a banner over a composer the user is mid-sentence in.
      return;
    }
    final row = await _store.getDraft(_source, conversationKey);
    if (!mounted) return;
    state = state.copyWith(draft: row);
  }

  /// Throws the suggestion away. The row stays, marked `dismissed`, so the
  /// enqueue on the next list load does not immediately write another one.
  Future<void> dismiss() async {
    if (state.draft == null) return;
    await _store.updateDraftStatus(
      _source,
      conversationKey,
      status: 'dismissed',
    );
    final row = await _store.getDraft(_source, conversationKey);
    if (!mounted) return;
    state = state.copyWith(draft: row, error: null);
  }

  /// Sends, saves, or copies [body] — whichever this grant allows.
  ///
  /// **The only path in this app that puts mail in front of another person.**
  /// It is called from exactly one place: the composer's primary button. There
  /// is no timer here, nothing calls it on a state change, and it takes the
  /// body as an argument rather than reading the stored draft, so what goes out
  /// is what was on screen.
  Future<SendOutcome> send(String body) async {
    final text = body.trim();
    if (text.isEmpty || state.sending) return SendOutcome.failed;

    if (state.capability == SendCapability.copyOnly) {
      await Clipboard.setData(ClipboardData(text: text));
      return SendOutcome.copied;
    }

    // A thread only earns a generated draft when it ranks high enough, but
    // the LO can reply to ANY thread — so a missing draft row falls back to
    // the newest inbound message, which is exactly what the draft handler
    // itself replies to.
    var replyTo = state.replyToMessageId;
    if (replyTo == null || replyTo.isEmpty) {
      final newest = await _store.newestInboundMessage(_source, conversationKey);
      replyTo = newest?['source_message_id'] as String?;
    }
    if (replyTo == null || replyTo.isEmpty) {
      state = state.copyWith(
        error: 'There is nothing to reply to in this thread yet.',
      );
      return SendOutcome.failed;
    }

    state = state.copyWith(sending: true, error: null);
    try {
      final draft = await _mail.createReplyDraft(replyTo);
      final draftId = draft['id'] as String? ?? '';
      final webLink = draft['webLink'] as String?;
      if (draftId.isEmpty) {
        throw const GraphMailException(
          'Microsoft Graph created a draft with no id.',
        );
      }
      await _mail.updateDraftBody(draftId, text);

      if (state.capability == SendCapability.draftToOutlook) {
        return await _handOffToOutlook(draftId, webLink, text);
      }

      await _mail.sendDraft(draftId);
      await _store.updateDraftStatus(
        _source,
        conversationKey,
        status: 'sent',
        body: text,
        graphDraftId: draftId,
      );
      // The strongest positive signal the app collects, and implicit rather
      // than explicit: the LO did not press a rating, they answered the mail.
      await _logSent();
      state = state.copyWith(
        sending: false,
        draft: await _store.getDraft(_source, conversationKey),
        sendEpoch: state.sendEpoch + 1,
      );
      // The sent message lands in `sentitems` and folds in normally, which is
      // what flips the thread out of "needs reply" — no optimistic row is
      // written here, so nothing can be left behind if the sync disagrees.
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
    }
  }

  /// `Mail.ReadWrite` without `Mail.Send`: the reply exists in Outlook and the
  /// user finishes it there. The stored draft stays `suggested` — it was not
  /// sent, and marking it so would be a lie the next reader acts on.
  Future<SendOutcome> _handOffToOutlook(
    String draftId,
    String? webLink,
    String text,
  ) async {
    await _store.updateDraftStatus(
      _source,
      conversationKey,
      status: 'suggested',
      body: text,
      graphDraftId: draftId,
      webLink: webLink,
    );
    state = state.copyWith(
      sending: false,
      draft: await _store.getDraft(_source, conversationKey),
    );
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
    StateNotifierProvider.family<DraftNotifier, DraftState, String>(
  (ref, conversationKey) => DraftNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(authSessionProvider),
    ref.watch(mailBackendProvider),
    conversationKey,
    worker: ref.watch(aiWorkerProvider),
    onSent: () => ref.read(conversationsProvider.notifier).load(),
  ),
);
