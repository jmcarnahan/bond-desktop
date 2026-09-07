import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart';
import '../models/message_models.dart' show Conversation, ConversationState;
import '../models/person.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/backend_types.dart';
import '../services/backend/mail_backend.dart';
import '../services/backend/teams_backend.dart';
import '../services/activity_log.dart';
import '../services/chat_roster.dart';
import '../services/conversation_state.dart'
    show conversationKeyFor, stateWaiting;
import '../services/graph_mail.dart' show GraphMailException;
import '../services/graph_teams.dart' show GraphTeamsException;
import '../services/mail_echo.dart' show firstLine, mailEchoRow, nowSecondsZ;
import '../services/outbound_chat.dart' show writeOutboundChatRow;
import '../services/pipeline_progress.dart';
import '../services/teams_sync.dart' show TeamsSync, teamsAddress;
import '../widgets/composer.dart' show SendCapability;
import 'app_providers.dart';

/// A message being written to people the app is not already in a thread with.
///
/// The counterpart of `DraftNotifier`, and deliberately NOT the same class: a
/// reply has a thread, a message to answer and a conversation row that already
/// exists, and every one of those is a thing this screen has to create. What
/// the two share is the network — `createDraft`/`sendDraft` for mail, a chat
/// post for Teams — and the row writes, which live in `mail_echo.dart` and
/// `outbound_chat.dart` so both callers write the same database.
///
/// **[ComposeNotifier.send] is the only method here that reaches the network**,
/// it is called from exactly one place (the composer's primary button), and it
/// takes what it sends from [ComposeState.body], which the screen writes from
/// the composer's own text before calling. Nothing here is on a timer.

/// What a finished [ComposeNotifier.send] did. Sealed so the screen's switch
/// over it has to name every rung of the capability ladder.
sealed class ComposeOutcome {
  const ComposeOutcome();
}

/// The message went, and the thread it went to is stored under these keys.
class ComposeSent extends ComposeOutcome {
  final String source;
  final String conversationKey;

  const ComposeSent(this.source, this.conversationKey);
}

/// `Mail.ReadWrite` without `Mail.Send`: the draft is in Outlook and the user
/// finishes it there. Nothing was written locally — the message has not gone.
class ComposeSavedToOutlook extends ComposeOutcome {
  const ComposeSavedToOutlook();
}

/// Neither grant: the text is on the clipboard.
class ComposeCopied extends ComposeOutcome {
  const ComposeCopied();
}

/// Nothing went. Why is in [ComposeState.error], and the screen shows it there
/// rather than being handed a second copy of the sentence.
class ComposeFailed extends ComposeOutcome {
  const ComposeFailed();
}

/// Everything the New message screen is holding.
@immutable
class ComposeState {
  final RecipientChannel channel;

  /// The people picked in To. Owned here; the field renders it and hands back
  /// a new list per change.
  final List<Person> to;

  /// Mail only — Teams has no Cc.
  final List<Person> cc;

  /// Mail only, and allowed to be empty: Outlook sends a subjectless message
  /// and refusing to would be this app inventing a rule Microsoft does not
  /// have.
  final String subject;

  /// The name for a NEW group chat. Teams only, and only when there are two or
  /// more people — a 1:1 chat has no topic to set.
  final String topic;

  final String body;

  final bool sending;

  /// The inline alert's text. Cleared by the next thing the user does, so a
  /// failure never outlives the state it was about.
  final String? error;

  /// An Outlook web link to offer beside [error] — the one failure where the
  /// user's words survive somewhere they can still be sent from: the draft
  /// exists, the send did not happen.
  final String? errorLink;

  /// What this grant may do with the message. [SendCapability.copyOnly] until
  /// the first scope read lands, which is the rung that promises least.
  final SendCapability capability;

  /// The Teams thread this message is going INTO, rather than a chat to be
  /// created. Set by picking a chat from the recipients field or from
  /// [candidateChats]; exclusive with [to] by construction.
  final Conversation? existingChat;

  /// Stored chats whose roster matches the picked people — the offer to send
  /// in a group they already have rather than start a second one beside it.
  /// Includes [RosterMatch.unknown] matches: a truncated roster the pick
  /// covers may BE this chat, and the screen offers both rather than choosing
  /// wrong. See `chat_roster.dart`.
  final List<Conversation> candidateChats;

  /// A group chat [ensureChat] already created for this message.
  ///
  /// Held because a group is created on EVERY `ensureChat` call: a send that
  /// fails after the chat exists must retry into the same group, not leave a
  /// trail of empty ones behind it. Cleared whenever the picked set changes,
  /// because a held group is then no longer the group the user is addressing.
  final String? groupChatId;

  const ComposeState({
    this.channel = RecipientChannel.mail,
    this.to = const [],
    this.cc = const [],
    this.subject = '',
    this.topic = '',
    this.body = '',
    this.sending = false,
    this.error,
    this.errorLink,
    this.capability = SendCapability.copyOnly,
    this.existingChat,
    this.candidateChats = const [],
    this.groupChatId,
  });

  bool get isMail => channel == RecipientChannel.mail;

  bool get isTeams => channel == RecipientChannel.teams;

  /// Whether sending would CREATE a group chat — two or more people and no
  /// thread picked to send into. What puts the Topic field on screen.
  bool get isNewGroup => isTeams && existingChat == null && to.length >= 2;

  /// Ready to send: words to send, somebody to send them to, nothing already
  /// in flight. An empty subject is deliberately not part of this.
  bool get canSend =>
      body.trim().isNotEmpty &&
      !sending &&
      (existingChat != null || to.isNotEmpty);

  ComposeState copyWith({
    RecipientChannel? channel,
    List<Person>? to,
    List<Person>? cc,
    String? subject,
    String? topic,
    String? body,
    bool? sending,
    Object? error = _unset,
    Object? errorLink = _unset,
    SendCapability? capability,
    Object? existingChat = _unset,
    List<Conversation>? candidateChats,
    Object? groupChatId = _unset,
  }) =>
      ComposeState(
        channel: channel ?? this.channel,
        to: to ?? this.to,
        cc: cc ?? this.cc,
        subject: subject ?? this.subject,
        topic: topic ?? this.topic,
        body: body ?? this.body,
        sending: sending ?? this.sending,
        error: identical(error, _unset) ? this.error : error as String?,
        errorLink:
            identical(errorLink, _unset) ? this.errorLink : errorLink as String?,
        capability: capability ?? this.capability,
        existingChat: identical(existingChat, _unset)
            ? this.existingChat
            : existingChat as Conversation?,
        candidateChats: candidateChats ?? this.candidateChats,
        groupChatId: identical(groupChatId, _unset)
            ? this.groupChatId
            : groupChatId as String?,
      );

  /// Separates "not passed" from "passed as null" on [copyWith], where the two
  /// mean opposite things for every nullable field. The same sentinel
  /// `DraftState` uses, and for the same reason.
  static const Object _unset = Object();
}

class ComposeNotifier extends StateNotifier<ComposeState> {
  final MessageStore _store;
  final AuthSession _auth;
  final MailBackend _mail;
  final TeamsBackend _teams;
  final ActivityLog _log;

  /// Where the needs-you exit is recorded when a message goes into a chat that
  /// was asking for one. Same reason the reply arm says it here rather than
  /// leaving it to a sync — see `DraftNotifier`.
  final PipelineProgress _pipeline;

  /// Opens a URL. Injected so a test can assert the Outlook hand-off without a
  /// browser.
  final Future<bool> Function(Uri url) _launch;

  /// Bumped by every [setTo]. A candidate-chat read that comes back after the
  /// user kept picking belongs to a set that no longer exists, and applying it
  /// would offer a chat for people who are no longer in the field.
  int _toSeq = 0;

  ComposeNotifier(
    this._store,
    this._auth,
    this._mail,
    this._teams, {
    ActivityLog? log,
    this._pipeline = const PipelineProgress.disabled(),
    Future<bool> Function(Uri url)? launch,
  })  : _log = log ?? ActivityLog.disabled(),
        _launch = launch ??
            ((url) => launchUrl(url, mode: LaunchMode.externalApplication)),
        super(const ComposeState()) {
    // The one thing construction does. Reading what the grant allows is what
    // decides which button the screen paints; nothing else here happens
    // without a click.
    unawaited(load());
  }

  /// Reads what this grant may do with a message on the current channel.
  /// Never throws: a keychain that will not open leaves the screen on the rung
  /// that needs no permission at all.
  Future<void> load() async {
    final channel = state.channel;
    final capability = await _capabilityFor(channel);
    // The channel can have moved while the keychain answered, and a mail
    // verdict painted over a Teams screen would offer a button that cannot
    // send.
    if (!mounted || state.channel != channel) return;
    state = state.copyWith(capability: capability);
  }

  Future<SendCapability> _capabilityFor(RecipientChannel channel) async {
    try {
      if (channel == RecipientChannel.teams) {
        // Two rungs rather than three: there is no Outlook drafts folder to
        // hand a chat message to, and no useful place to paste one either —
        // which is why the screen says so instead of offering Copy.
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

  /// Switches between mail and Teams.
  ///
  /// The recipients go with the channel, deliberately: a person picked out of
  /// the directory for mail may have no Graph id to open a chat with, and a
  /// Teams-only recent has no address to post mail to. The body and the
  /// subject stay — those are what the user wrote, and they are the same words
  /// whichever way they travel.
  void setChannel(RecipientChannel channel) {
    if (channel == state.channel) return;
    state = state.copyWith(
      channel: channel,
      to: const [],
      cc: const [],
      topic: '',
      existingChat: null,
      candidateChats: const [],
      groupChatId: null,
      error: null,
      errorLink: null,
    );
    unawaited(load());
  }

  /// The picked recipients changed.
  ///
  /// Returns a future because the Teams arm reads the stored chats to find the
  /// group these people may already have; callers that only render the chips
  /// can ignore it, which is what makes this assignable to the field's plain
  /// `onChanged`.
  Future<void> setTo(List<Person> people) async {
    final seq = ++_toSeq;
    state = state.copyWith(
      to: List<Person>.unmodifiable(people),
      error: null,
      errorLink: null,
      // A held group belongs to the set that was picked when it was created.
      groupChatId: null,
      // Picking people means composing TO them rather than into a thread. An
      // empty list is the field being cleared, which leaves a picked thread
      // alone — that is the one edit that is not a change of addressee.
      existingChat: people.isEmpty ? state.existingChat : null,
    );

    if (state.channel != RecipientChannel.teams) {
      if (state.candidateChats.isNotEmpty) {
        state = state.copyWith(candidateChats: const []);
      }
      return;
    }

    final ids = {
      for (final person in people)
        if (person.hasGraphId) person.id,
    };
    // One person is a 1:1, which `ensureChat` is idempotent for — there is no
    // duplicate to warn about, so nothing is offered.
    if (ids.length < 2) {
      state = state.copyWith(candidateChats: const []);
      return;
    }

    List<Conversation> matches;
    try {
      final chats = await _store.teamsChats();
      matches = [
        for (final chat in chats)
          if (rosterMatch(chat, ids) != RosterMatch.different) chat,
      ];
    } catch (_) {
      // A read that failed offers nothing rather than blocking the send: the
      // worst case is a second group chat, which is what happens today anyway.
      matches = const [];
    }
    if (!mounted || seq != _toSeq) return;
    state = state.copyWith(candidateChats: matches);
  }

  void setCc(List<Person> people) => state = state.copyWith(
        cc: List<Person>.unmodifiable(people),
        error: null,
      );

  void setSubject(String subject) => state = state.copyWith(subject: subject);

  void setTopic(String topic) => state = state.copyWith(topic: topic);

  void setBody(String body) => state = state.copyWith(body: body);

  /// Sends into a thread that already exists instead of opening a new one.
  /// The picked people go: the thread's members are the addressees now, and
  /// leaving chips beside it would claim the message goes to both sets.
  void pickExistingChat(Conversation chat) {
    state = state.copyWith(
      existingChat: chat,
      to: const [],
      candidateChats: const [],
      groupChatId: null,
      error: null,
      errorLink: null,
    );
  }

  /// Backs out of a picked thread, keeping whoever is in the field.
  void useNewGroup() => state = state.copyWith(
        existingChat: null,
        error: null,
        errorLink: null,
      );

  /// Opens the screen on somebody or something — an `OpenComposeIntent`.
  /// [chat] wins over [to]: a thread names its own members.
  ///
  /// The subject and the topic go with the recipients: the screen empties
  /// both boxes when an ask lands, and a subject kept here behind an empty
  /// box would go out on a message the user could not see it on. The body is
  /// the composer's own and is written fresh at send time.
  Future<void> prefill({
    RecipientChannel? channel,
    List<Person> to = const [],
    Conversation? chat,
  }) async {
    state = state.copyWith(
      channel: channel ?? state.channel,
      to: const [],
      cc: const [],
      subject: '',
      topic: '',
      existingChat: null,
      candidateChats: const [],
      groupChatId: null,
      error: null,
      errorLink: null,
    );
    await load();
    if (chat != null) {
      pickExistingChat(chat);
      return;
    }
    if (to.isNotEmpty) await setTo(to);
  }

  /// Sends what [ComposeState.body] holds — the one path in this file that
  /// reaches the network, and the only one that writes a row.
  ///
  /// The screen writes the composer's text into [setBody] immediately before
  /// calling this, because the composer's own `onEdited` is debounced and the
  /// stored body therefore lags the last word typed.
  Future<ComposeOutcome> send() async {
    if (state.sending) return const ComposeFailed();
    final text = state.body.trim();
    // An empty box is not an error to narrate — the button that reaches here
    // is disabled on one, so this is only ever a programmatic call.
    if (text.isEmpty) return const ComposeFailed();
    if (state.existingChat == null && state.to.isEmpty) {
      state = state.copyWith(error: 'Add somebody to send to.');
      return const ComposeFailed();
    }

    state = state.copyWith(sending: true, error: null, errorLink: null);
    try {
      return state.isMail ? await _sendMail(text) : await _sendChat(text);
    } on AuthException catch (e) {
      _fail(e.message);
      return const ComposeFailed();
    } on GraphMailException catch (e) {
      _fail(e.message);
      return const ComposeFailed();
    } on GraphTeamsException catch (e) {
      _fail(e.message);
      return const ComposeFailed();
    } catch (e) {
      _fail('Could not send: $e');
      return const ComposeFailed();
    } finally {
      // Every arm that returns cleanly has already cleared this; the catches
      // above and any throw from inside a write have not.
      if (mounted && state.sending) state = state.copyWith(sending: false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    state = state.copyWith(sending: false, error: message);
  }

  // ---------------------------------------------------------------- mail

  Future<ComposeOutcome> _sendMail(String text) async {
    final toAddresses = [
      for (final person in state.to)
        if (person.address.isNotEmpty) person.address,
    ];
    final ccAddresses = [
      for (final person in state.cc)
        if (person.address.isNotEmpty) person.address,
    ];
    if (toAddresses.isEmpty) {
      // A Teams-only recent picked on the mail channel: a real person with
      // nowhere to post mail to.
      _fail('Nobody in To has an email address.');
      return const ComposeFailed();
    }

    final subject = state.subject.trim();

    if (state.capability == SendCapability.copyOnly) {
      await Clipboard.setData(
        ClipboardData(text: _copyText(toAddresses, ccAddresses, subject, text)),
      );
      if (mounted) state = state.copyWith(sending: false);
      return const ComposeCopied();
    }

    final draft = await _mail.createDraft(
      to: toAddresses,
      cc: ccAddresses,
      subject: subject,
      body: text,
    );
    final draftId = draft['id'] as String? ?? '';
    final webLink = draft['webLink'] as String?;
    if (draftId.isEmpty) {
      throw const GraphMailException(
        'Microsoft Graph created a draft with no id.',
      );
    }

    if (state.capability == SendCapability.draftToOutlook) {
      // Nothing is written: the message has not gone, and a row claiming it
      // had would be the one lie this screen must never tell.
      final uri = webLink == null ? null : Uri.tryParse(webLink);
      if (uri != null) await _launch(uri);
      if (mounted) state = state.copyWith(sending: false);
      return const ComposeSavedToOutlook();
    }

    final SentDraft sent;
    try {
      sent = await _mail.sendDraft(draftId);
    } catch (_) {
      // The draft survives the failure, and it holds every word that was
      // typed — so the sentence names where it is rather than what broke.
      if (mounted) {
        state = state.copyWith(
          sending: false,
          error: 'Not sent. The draft is in your Outlook Drafts.',
          errorLink: webLink,
        );
      }
      return const ComposeFailed();
    }

    final key = conversationKeyFor(
      sent.conversationId ?? draft['conversationId'] as String?,
      draftId,
    );
    // Never allowed to fail the send: the message has gone, and a keychain
    // that will not open only costs the echo its sender column.
    AccountInfo? owner;
    try {
      owner = await _auth.storedAccount;
    } catch (_) {
      owner = null;
    }

    final sentAt = sent.sentAt ?? nowSecondsZ();
    final preview = firstLine(text);
    final rowSubject = (sent.subject ?? subject).trim();

    // The conversation FIRST, and every field of it written fresh: there is no
    // stored row to carry anything through, `foldOutboundSend` is a no-op
    // without one, and the counts recomputed below need it to exist. If a poll
    // beat this write with the Sent Items copy the row is already there and
    // this refreshes it, which is harmless — the echo insert below is the one
    // that notices and declines.
    await _store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': rowSubject.isEmpty ? null : rowSubject,
      'participants_json': jsonEncode(_mailParticipants()),
      'state': stateWaiting,
      'category': null,
      'cta_text': null,
      'cta_urgency': 'normal',
      // Placeholders — the recompute below is the real write.
      'message_count': 0,
      'inbound_count': 0,
      'last_inbound_at': null,
      'last_outbound_at': sentAt,
      'last_message_at': sentAt,
      'last_message_preview': preview,
    });
    await _store.insertLocalEcho(mailEchoRow(
      sent: sent,
      text: text,
      conversationKey: key,
      owner: owner,
    ));
    await _store.recomputeConversationCounts('email', key);
    await _record(
      channel: 'email',
      source: 'email',
      entityId: key,
      recipients: toAddresses.length + ccAddresses.length,
    );

    if (mounted) state = state.copyWith(sending: false);
    return ComposeSent('email', key);
  }

  /// What the clipboard rung hands over: the headers a person needs to
  /// reassemble the message wherever they were going to write it anyway.
  String _copyText(
    List<String> to,
    List<String> cc,
    String subject,
    String text,
  ) {
    final lines = <String>['To: ${to.join(', ')}'];
    if (cc.isNotEmpty) lines.add('Cc: ${cc.join(', ')}');
    if (subject.isNotEmpty) lines.add('Subject: $subject');
    return '${lines.join('\n')}\n\n$text';
  }

  /// To and Cc as the `conversations` table spells participants, deduped on
  /// the address and capped the way every stored roster in this app is.
  List<Map<String, Object?>> _mailParticipants() {
    final seen = <String>{};
    final participants = <Map<String, Object?>>[];
    for (final person in [...state.to, ...state.cc]) {
      final address = person.address;
      if (address.isEmpty) continue;
      if (!seen.add(address.toLowerCase())) continue;
      participants.add({
        'name': person.displayName.isEmpty ? null : person.displayName,
        'email': address,
      });
      if (participants.length >= teamsRosterCap) break;
    }
    return participants;
  }

  // --------------------------------------------------------------- teams

  Future<ComposeOutcome> _sendChat(String text) async {
    if (state.capability != SendCapability.send) {
      _fail('Teams sending is not enabled for this account.');
      return const ComposeFailed();
    }

    final chat = state.existingChat;
    if (chat != null) return _sendToExistingChat(chat, text);
    return _sendToNewChat(text);
  }

  Future<ComposeOutcome> _sendToExistingChat(
    Conversation chat,
    String text,
  ) async {
    final sent = await _teams.sendChatMessage(chat.id, text);
    return _finishStoredChat(
      chat.id,
      sent,
      text,
      recipients: chat.participants.length,
    );
  }

  /// The writes for a message posted into a chat this app already stores —
  /// whether the user picked the thread, or picked a person whose 1:1 chat
  /// turned out to be one the rail already had.
  ///
  /// A fold, never a fresh row: the stored subject, category and roster are
  /// the sync's work and survive, and the thread moves to the top of the rail
  /// the way a reply would. Then the same three writes the reply arm makes,
  /// for the same reason: a message leaving IS the needs-you exit and the
  /// CTA's answer, and for a chat this is the only place it can be said — the
  /// row written here is one the next pull deliberately skips as
  /// already-seen, so the sync's `resolvesAsk` arm never runs for it.
  Future<ComposeOutcome> _finishStoredChat(
    String chatId,
    Map<String, dynamic> sent,
    String text, {
    required int recipients,
  }) async {
    await writeOutboundChatRow(_store, sent, chatId, text);
    await _store.setConversationState(
      'teams',
      chatId,
      ConversationState.waiting,
    );
    await _store.clearCta('teams', chatId);
    await _pipeline.clearNeedsYou('teams', chatId);
    await _record(
      channel: 'teams',
      source: 'teams',
      entityId: chatId,
      recipients: recipients,
    );

    if (mounted) state = state.copyWith(sending: false, groupChatId: null);
    return ComposeSent('teams', chatId);
  }

  Future<ComposeOutcome> _sendToNewChat(String text) async {
    final people = state.to;
    final ids = [
      for (final person in people)
        if (person.hasGraphId) person.id,
    ];
    if (ids.length != people.length) {
      // A typed address, or a mail recent with no Graph id behind it. Named,
      // because "somebody here cannot be reached" is not something the user
      // can act on without knowing who.
      final offender = people.firstWhere((person) => !person.hasGraphId);
      final who = offender.displayName.isEmpty
          ? offender.address
          : offender.displayName;
      _fail('$who cannot be reached on Teams.');
      return const ComposeFailed();
    }

    var chatId = state.groupChatId;
    if (chatId == null) {
      final topic = state.topic.trim();
      final ensured = await _teams.ensureChat(
        ids,
        topic: ids.length > 1 && topic.isNotEmpty ? topic : null,
      );
      chatId = ensured.chatId;
      // Held BEFORE the send, not after it: a group is created on every
      // `ensureChat` call, so a send that fails from here has to retry into
      // this chat rather than open a second one beside it. A 1:1 is idempotent
      // and needs no holding.
      if (ensured.isGroup && mounted) {
        state = state.copyWith(groupChatId: chatId);
      }
    }

    final Map<String, dynamic> sent;
    try {
      sent = await _teams.sendChatMessage(chatId, text);
    } catch (_) {
      _fail('The chat was opened but the message did not send.');
      return const ComposeFailed();
    }

    // "New" was the user's framing, not necessarily the database's: a 1:1
    // `ensureChat` answers with the chat that already exists, and the person
    // picked by name may be somebody whose thread is already in the rail. A
    // fresh row over that one would reset its state, drop its category and
    // roster, and leave a needs-you chip nothing else can clear.
    if (await _store.getConversationRow('teams', chatId) != null) {
      return _finishStoredChat(chatId, sent, text, recipients: ids.length);
    }

    // Best effort, and the fallback is honest rather than empty: the people
    // the user picked ARE the members, minus whatever Graph would have added.
    // An answer with nobody in it — a roster read that lagged the creation —
    // is treated as no answer, for the same reason.
    List<Map<String, Object?>> participants = const [];
    try {
      final members = await _teams.chatMembers(chatId);
      final me = await _teams.myUserId();
      participants = [
        for (final member in members)
          if ((member['userId'] as String? ?? '') != me &&
              (member['userId'] as String? ?? '').isNotEmpty)
            {
              'name': member['displayName'],
              'email': teamsAddress(member['userId'] as String),
            },
      ];
    } catch (_) {
      // Handled below with the empty answer.
    }
    if (participants.isEmpty) {
      participants = [
        for (final person in people)
          {'name': person.displayName, 'email': person.teamsAddress},
      ];
    }
    if (participants.length > teamsRosterCap) {
      participants = participants.sublist(0, teamsRosterCap);
    }

    final row = TeamsSync.messageRow(sent, chatId, outbound: true);
    final at = row?['received_at'] as String? ?? nowSecondsZ();

    await _store.upsertConversation({
      'source': 'teams',
      'conversation_key': chatId,
      'subject': _chatSubject(participants, group: ids.length > 1),
      'participants_json': jsonEncode(participants),
      'state': stateWaiting,
      'category': null,
      'cta_text': null,
      'cta_urgency': 'normal',
      'message_count': 0,
      'inbound_count': 0,
      'last_inbound_at': null,
      'last_outbound_at': at,
      'last_message_at': at,
      'last_message_preview': firstLine(text),
    });
    // Null when Graph answered with something that is not a chat message. The
    // post still went, so the conversation above stands and the next pull
    // writes the transcript entry this could not.
    if (row != null) await _store.upsertMessage(row);
    await _store.recomputeConversationCounts('teams', chatId);
    await _record(
      channel: 'teams',
      source: 'teams',
      entityId: chatId,
      recipients: ids.length,
    );

    if (mounted) {
      // The chat exists and holds the message; a retry from here would be a
      // second message, not a second group.
      state = state.copyWith(sending: false, groupChatId: null);
    }
    return ComposeSent('teams', chatId);
  }

  /// What the rail calls a chat this app just opened: the topic when the user
  /// named one, else the members' names. Mirrors `TeamsSync`'s own rule — the
  /// next pull writes the subject that way, and two spellings of the same chat
  /// is a row that renames itself a minute after it appears.
  ///
  /// [group] is the PICK, not the roster: the topic was typed for the chat the
  /// user asked for, and a member list Graph answered short must not cost
  /// them the name they gave it.
  String? _chatSubject(
    List<Map<String, Object?>> participants, {
    required bool group,
  }) {
    final topic = state.topic.trim();
    if (topic.isNotEmpty && group) return topic;
    final names = [
      for (final participant in participants)
        (participant['name'] as String?) ?? (participant['email'] as String?) ??
            '',
    ]..removeWhere((name) => name.isEmpty);
    if (names.isEmpty) return null;
    if (names.length <= _maxSubjectNames) return names.join(', ');
    return '${names.take(_maxSubjectNames).join(', ')}…';
  }

  /// How many member names a chat's subject is built from before it trails
  /// off. `TeamsSync` holds the same number privately for the same rule.
  static const int _maxSubjectNames = 3;

  /// One row in the activity log per message that went. No addresses: the
  /// panel is user-visible and the channel and the count are what a person
  /// reads it for.
  Future<void> _record({
    required String channel,
    required String source,
    required String entityId,
    required int recipients,
  }) async {
    try {
      await _log.record(
        'compose',
        source: source,
        entityId: entityId,
        count: recipients,
        detail: {
          'channel': channel,
          'recipients': recipients,
          'outcome': 'sent',
        },
      );
    } catch (_) {
      // The message already went. A log row is not worth failing it over.
    }
  }
}

/// autoDispose, unlike `draftProvider`: a new message is memory-only by
/// decision, and leaving the screen drops what was typed rather than having it
/// reappear, half-addressed, the next time somebody opens compose.
final composeProvider =
    StateNotifierProvider.autoDispose<ComposeNotifier, ComposeState>(
  (ref) => ComposeNotifier(
    ref.watch(messageStoreProvider),
    ref.watch(authSessionProvider),
    ref.watch(mailBackendProvider),
    ref.watch(teamsBackendProvider),
    log: ref.watch(activityLogProvider),
    pipeline: ref.watch(pipelineProgressProvider),
  ),
);
