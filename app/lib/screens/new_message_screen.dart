import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/person.dart';
import '../providers/compose_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/recipient_search_provider.dart';
import '../theme/tokens.dart';
import '../widgets/chips.dart';
import '../widgets/composer.dart';
import '../widgets/inline_alert.dart';
import '../widgets/pane_surface.dart';
import '../widgets/recipients_field.dart';

/// Writing a message to somebody this app has no thread with.
///
/// A full pane like Settings rather than a popup, per the house rule, and it
/// holds nothing itself beyond two text controllers and whether Cc has been
/// asked for: everything that could be sent lives in [composeProvider], so the
/// send can be driven without a widget and a rebuild cannot lose a recipient.
///
/// The one asymmetry worth knowing about is the body. [Composer.onEdited] is
/// debounced by half a second, so `state.body` lags the last word typed — the
/// send therefore takes the composer's OWN text out of `onSend` and writes it
/// through [ComposeNotifier.setBody] immediately before calling
/// [ComposeNotifier.send]. Nothing on this screen may send from stored state.
class NewMessageScreen extends ConsumerStatefulWidget {
  final VoidCallback onBack;

  /// Straight to the landing screen. Null renders no home affordance.
  final VoidCallback? onHome;

  /// Who or what this screen was opened on, when something asked for it
  /// pre-filled.
  final OpenComposeIntent? prefill;

  const NewMessageScreen({
    super.key,
    required this.onBack,
    this.onHome,
    this.prefill,
  });

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  late final TextEditingController _subject;
  late final TextEditingController _topic;

  /// Whether the Cc field is on screen. Local because it is a disclosure, not
  /// a value: what is IN Cc lives in the notifier, and a compose flow that
  /// arrives carrying addresses reveals the field on its own below.
  bool _showCc = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(composeProvider);
    _subject = TextEditingController(text: state.subject);
    _topic = TextEditingController(text: state.topic);
    _showCc = state.cc.isNotEmpty;

    _applyPrefill(widget.prefill);
  }

  @override
  void didUpdateWidget(NewMessageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A second ask while the screen is already open — the rail's button, or
    // another `OpenComposeIntent`. The element is reused, so `initState` will
    // not run again and this is the only place the new ask can land. Identity,
    // not equality: intents deliberately carry no `==`, and two identical asks
    // are two asks.
    if (!identical(widget.prefill, oldWidget.prefill)) {
      _applyPrefill(widget.prefill);
    }
  }

  /// Hands an ask to the notifier AFTER the frame, never during it:
  /// [ComposeNotifier.prefill] writes before its first await, and Riverpod
  /// refuses a provider write from inside a widget life-cycle — the tree would
  /// be showing two states of the same provider in one build.
  void _applyPrefill(OpenComposeIntent? prefill) {
    if (prefill == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subject.clear();
      _topic.clear();
      unawaited(ref.read(composeProvider.notifier).prefill(
            channel: prefill.channel,
            to: prefill.to,
            chat: prefill.chat,
          ));
    });
  }

  @override
  void dispose() {
    _subject.dispose();
    _topic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(composeProvider);
    final notifier = ref.read(composeProvider.notifier);
    final chat = state.existingChat;

    return PaneSurface(
      title: 'New message',
      onBack: widget.onBack,
      onHome: widget.onHome,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(BondSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BondFilterPillRow<RecipientChannel>(
              key: const Key('compose-channel'),
              options: const [RecipientChannel.mail, RecipientChannel.teams],
              selected: state.channel,
              labelOf: (channel) =>
                  channel == RecipientChannel.mail ? 'Email' : 'Teams',
              onSelected: notifier.setChannel,
            ),
            const SizedBox(height: BondSpacing.s16),
            if (chat != null) ...[
              _existingChatBanner(chat.subject, notifier),
              const SizedBox(height: BondSpacing.s12),
            ] else ...[
              // Keyed on the channel and on nothing else: switching channel is
              // a legitimate remount (a different search, a different set of
              // rules about typed addresses), while a key that moved per pick
              // would remount `RawAutocomplete` and leak a focus listener each
              // time. See `recipients_field.dart`.
              RecipientsField(
                key: ValueKey('compose-to-${state.channel.name}'),
                value: state.to,
                onChanged: notifier.setTo,
                search: (query) => ref
                    .read(recipientSearchProvider)
                    .search(query, channel: state.channel),
                channel: state.channel,
                allowTypedAddress: state.isMail,
                hint: state.isMail ? 'To' : 'To (people or an existing chat)',
                // A chat is only ever offered on Teams, and only because this
                // screen can act on the pick.
                onChatPicked:
                    state.isTeams ? notifier.pickExistingChat : null,
              ),
              const SizedBox(height: BondSpacing.s12),
            ],
            if (state.isMail) ..._mailFields(state, notifier),
            if (state.isTeams && chat == null) ..._teamsFields(state, notifier),
            if (state.isTeams && state.capability != SendCapability.send) ...[
              const InlineAlert(
                severity: InlineAlertSeverity.attention,
                text: 'Teams sending is not enabled for this account.',
              ),
            ] else ...[
              if (state.error != null) ...[
                InlineAlert(
                  severity: InlineAlertSeverity.error,
                  text: state.error!,
                  maxLines: 3,
                  action: state.errorLink == null
                      ? null
                      : TextButton(
                          key: const Key('compose-error-link'),
                          onPressed: () => _open(state.errorLink!),
                          child: const Text('Open in Outlook'),
                        ),
                ),
                const SizedBox(height: BondSpacing.s12),
              ],
              Composer(
                // Same rule as the field above: a channel switch is a new
                // message, a pick is not.
                key: ValueKey('compose-body-${state.channel.name}'),
                capability: state.capability,
                sending: state.sending,
                onEdited: notifier.setBody,
                onSend: _send,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _existingChatBanner(String? subject, ComposeNotifier notifier) {
    final name = (subject ?? '').trim();
    return Row(
      children: [
        Expanded(
          child: Text(
            name.isEmpty ? 'Sending in this chat' : 'Sending in $name',
            style: BondType.caption.copyWith(color: BondColors.inkSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          key: const Key('compose-change-chat'),
          onPressed: notifier.useNewGroup,
          child: const Text('Change'),
        ),
      ],
    );
  }

  List<Widget> _mailFields(ComposeState state, ComposeNotifier notifier) {
    final showCc = _showCc || state.cc.isNotEmpty;
    return [
      if (showCc) ...[
        RecipientsField(
          key: const Key('compose-cc'),
          value: state.cc,
          onChanged: notifier.setCc,
          search: (query) => ref
              .read(recipientSearchProvider)
              .search(query, channel: RecipientChannel.mail),
          channel: RecipientChannel.mail,
          allowTypedAddress: true,
          hint: 'Cc',
        ),
        const SizedBox(height: BondSpacing.s12),
      ] else ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('compose-cc-toggle'),
            onPressed: () => setState(() => _showCc = true),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Cc'),
          ),
        ),
      ],
      TextField(
        key: const Key('compose-subject'),
        controller: _subject,
        onChanged: notifier.setSubject,
        style: BondType.body,
        decoration: const InputDecoration(
          hintText: 'Subject',
          isDense: true,
        ),
      ),
      const SizedBox(height: BondSpacing.s16),
    ];
  }

  List<Widget> _teamsFields(ComposeState state, ComposeNotifier notifier) {
    if (!state.isNewGroup) return const [];
    return [
      if (state.candidateChats.isNotEmpty) ...[
        Text(
          'You already have a chat with these people.',
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
        const SizedBox(height: BondSpacing.s4),
        for (final chat in state.candidateChats)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key('compose-candidate-${chat.id}'),
              onPressed: () => notifier.pickExistingChat(chat),
              child: Text('Send in ${chat.subject ?? 'this chat'}'),
            ),
          ),
        const SizedBox(height: BondSpacing.s4),
        Text(
          'Otherwise this starts a new group chat.',
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
      ] else
        Text(
          'This starts a new group chat.',
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
      const SizedBox(height: BondSpacing.s8),
      TextField(
        key: const Key('compose-topic'),
        controller: _topic,
        onChanged: notifier.setTopic,
        style: BondType.body,
        decoration: const InputDecoration(
          hintText: 'Topic (optional)',
          isDense: true,
        ),
      ),
      const SizedBox(height: BondSpacing.s16),
    ];
  }

  Future<void> _open(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// The composer's button, and the only path off this screen that sends.
  ///
  /// [body] is the composer's own text rather than `state.body`, because the
  /// notifier's copy is half a second behind the keyboard.
  Future<void> _send(String body) async {
    final notifier = ref.read(composeProvider.notifier);
    notifier.setBody(body);
    final outcome = await notifier.send();
    if (!mounted) return;

    switch (outcome) {
      case ComposeSent(:final source, :final conversationKey):
        // AWAITED before the intent, and the order is the whole trick: the
        // screen resolves a selection against the LOADED list and falls
        // through to Home when the key is not in it, so asking to open the
        // thread first would land on Home.
        await ref
            .read(conversationsProvider.notifier)
            .load(syncFirst: false);
        if (!mounted) return;
        _toast('Message sent.');
        ref
            .read(navIntentProvider.notifier)
            .request(OpenThreadIntent(source, conversationKey));
      case ComposeSavedToOutlook():
        _toast('Saved to your Outlook drafts.');
        widget.onBack();
      case ComposeCopied():
        _toast('Copied. Paste it into your mail app to send.');
      case ComposeFailed():
        // The inline alert already says why, beside the words it is about.
        break;
    }
  }

  void _toast(String message) {
    // `maybeOf`: a test can pump this screen without a Scaffold, and a missing
    // messenger is not a reason to fail a send that already went.
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
