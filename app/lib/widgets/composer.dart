import 'dart:async';

import 'package:flutter/material.dart';

import '../models/draft_provenance.dart' show DraftProvenance, ProvenanceFile;
import '../models/person.dart' show Person, RecipientChannel;
import '../providers/recipient_search_provider.dart' show RecipientResults;
import '../services/profile_photos.dart' show ProfilePhotos;
import '../theme/tokens.dart';
import 'recipients_field.dart';

/// What this build is actually allowed to do with a reply, which depends
/// entirely on what Entra consented to.
///
/// The order is a ladder from best to worst, and the composer's primary button
/// says which rung it is on rather than offering a Send that would fail.
enum SendCapability {
  /// `Mail.Send`: the reply goes out from here.
  send,

  /// `Mail.ReadWrite` only: the reply is saved to Outlook Drafts and the user
  /// finishes it there.
  draftToOutlook,

  /// Neither: the text goes to the clipboard and the user pastes it wherever
  /// they were going to write the reply anyway.
  copyOnly,
}

/// "Follow up if nobody replies", chosen beside Send: none, or a To Do
/// reminder that many working days after the send, at 09:00.
enum FollowUpChoice {
  none,
  twoDays,
  oneWeek;

  String get label => switch (this) {
        FollowUpChoice.none => 'No follow-up',
        FollowUpChoice.twoDays => '2 days',
        FollowUpChoice.oneWeek => '1 week',
      };

  /// Working days (Monday to Friday) after the send.
  int get businessDays => switch (this) {
        FollowUpChoice.none => 0,
        FollowUpChoice.twoDays => 2,
        FollowUpChoice.oneWeek => 5,
      };
}

/// The reply box under a thread: a suggested draft the user edits, and the one
/// button that sends it.
///
/// **Nothing here sends on its own.** [onSend] fires from exactly one place —
/// the primary button's `onPressed` — and there is no timer, no autosave-then-
/// send, and no "accept" that turns into a send. A draft the user never clicks
/// stays text in a box.
///
/// The box starts EMPTY and one line tall, and grows as it is written in. A
/// suggestion is in it only because the HOST put it there — a card the reader
/// tapped, a draft they asked for — never because one happened to exist.
///
/// That suggested state is drawn as visibly *not yet theirs*: the text sits at
/// reduced opacity behind an accent rule, with a caption saying where it came
/// from. The first keystroke takes all of that away, because from that point on
/// the words are the user's and dressing them as a machine's suggestion would be
/// a lie about who wrote them.
class Composer extends StatefulWidget {
  /// The cached draft's body. Null means there is no suggestion — the field
  /// starts empty and the button offers to write one.
  final String? suggestedBody;

  /// One line above the field saying where the suggestion came from. Shown
  /// only while [suggestedBody] is untouched.
  final String? provenance;

  /// The directory files that draft read, as doors.
  ///
  /// The caption above says WHAT was read; a chip is the way INTO it. Chips
  /// rather than tappable spans inside the caption, because a [TextButton] has
  /// a hit target and a focus ring and a `TapGestureRecognizer` inside a two
  /// line caption has neither — and the caption is already ellipsised, so half
  /// the spans would be unreachable at a narrow width.
  ///
  /// Drawn under the same gate as the caption: once the reader types, the
  /// words are theirs and nothing about where a suggestion came from belongs
  /// over them.
  final List<ProvenanceFile> provenanceFiles;

  /// Opens one of [provenanceFiles]. Null draws them as nothing — a host with
  /// no side panel has nowhere to open one.
  final void Function(ProvenanceFile file)? onOpenProvenanceFile;

  /// The draft being written this moment, as far as it has got, or null when
  /// nothing is being written.
  ///
  /// Drawn ABOVE the box and never INTO it. The box holds what the host staged
  /// and what the reader typed, and streamed text that arrived in the
  /// controller would overwrite a sentence somebody was in the middle of
  /// writing — the stored row stages exactly as it always has, once it exists.
  final String? streamingBody;

  /// True while a draft is being written. The generate button becomes a
  /// spinner; the composer stays usable.
  final bool generating;

  /// What the primary button does and says.
  final SendCapability capability;

  /// Fires ONLY from the primary button. The one path out of this widget that
  /// can put mail in front of another human.
  final void Function(String body) onSend;

  /// Writes a draft, or replaces the one there. Null hides the button — for a
  /// host with no model wired.
  final VoidCallback? onGenerate;

  /// What the Improve button says, or null to hide it entirely.
  ///
  /// The HOST builds the words from the target's own name — "Improve with
  /// Claude" — because the name is the person's, typed when they added the
  /// target, and this widget reaches for no preferences. Null is what a stage
  /// pointed nowhere looks like here, and it is the normal state: a build
  /// with nothing routed shows no button at all rather than a disabled one
  /// explaining a setting the reader has never heard of.
  final String? improveLabel;

  /// Rewrites the draft in the box on that target. Only ever called from the
  /// Improve button.
  final VoidCallback? onImprove;

  /// True while that rewrite is in flight: the Improve button becomes a
  /// spinner and the draft already in the box stays readable.
  final bool improving;

  /// The ✕ was pressed: this empties the box. What that means for the STORED
  /// draft is the host's decision, not this widget's — today it means nothing,
  /// and the suggestion stays on its card in the transcript.
  final VoidCallback? onDismiss;

  /// Takes the cursor the moment the field MOUNTS. For the host that opened a
  /// thread beside and wants the reader typing in it at once: the box appears
  /// only after the draft's capability has been read, which is an async
  /// keychain read, so a focus requested on the frame after the open lands on
  /// a node that has nothing to attach to yet. Mount-time focus cannot miss.
  ///
  /// An explicit request rather than the field's own `autofocus`, which
  /// yields to whatever already holds focus — and on this screen something
  /// always does.
  final bool focusOnMount;

  /// The user started editing. Debounced, so it fires on pauses rather than on
  /// keystrokes.
  final void Function(String body)? onEdited;

  /// True while a send is in flight: the primary button disables and shows a
  /// spinner, so a second click cannot send the same reply twice.
  final bool sending;

  /// The empty field's placeholder. The default is generic; a host that knows
  /// who is being answered says so instead, which is the difference between a
  /// box and a box addressed to somebody.
  final String hint;

  /// The app's processing switch is off, so nothing would write this draft.
  ///
  /// [onGenerate] stays wired and the button stays visible, disabled with the
  /// reason in its tooltip: the button is how a reader learns the switch is
  /// down, and a control that vanished would read as a build without drafting
  /// at all. It has to be here rather than left to the host, because asking
  /// while off is not a no-op — the host writes the work row, the drain that
  /// would claim it returns at once, and the spinner clears with no draft.
  final bool processingOff;

  /// The HOST's focus node, never one of ours. This widget is rebuilt with a
  /// new key on every send epoch and on every change of thread, so a node owned
  /// here would be thrown away exactly when the cursor is meant to survive —
  /// after a send, or when a hover Reply asks for the box. Never disposed here
  /// for the same reason: it belongs to whoever passed it.
  final FocusNode? focusNode;

  // ── People added to this reply ─────────────────────────────────────────
  //
  // BOTH sources, meaning different things. On mail a person added is a Cc on
  // the reply; on a chat they are a real Teams mention entity, which notifies
  // them — never a plain-text `@Name` that notifies nobody, which would read
  // to the sender as though somebody was told. [recipientChannel] says which,
  // and a host with no directory behind it wires none of the fields below and
  // this composer draws nothing about recipients. See `_recipientsWired`,
  // which is the one place that decision is read.

  /// The people the owner has added to this reply so far, newest last.
  ///
  /// Owned by the HOST, like the body's staged suggestion: this widget is
  /// rebuilt with a fresh key on every send epoch and every staging, and a list
  /// held here would lose somebody the owner picked to a rebuild they did not
  /// cause.
  final List<Person> addedRecipients;

  /// Reports every change to that list. **Null leaves the whole recipients
  /// affordance out** — a host with no directory behind it, and every call
  /// site that predates it.
  final ValueChanged<List<Person>>? onRecipientsChanged;

  /// The typeahead's read side, handed in exactly as `new_message_screen.dart`
  /// hands it to a [RecipientsField]. Null leaves the affordance out for the
  /// same reason [onRecipientsChanged] does.
  final Future<RecipientResults> Function(String query)? recipientSearch;

  /// Whether this connection can actually apply added people to a reply —
  /// `MailBackendRecipients.canEditDraftRecipients` on mail, a Teams backend
  /// at all on a chat.
  ///
  /// False draws no picker and no dead control. It draws a sentence, and only
  /// once somebody reaches for the feature: the honest answer at the moment of
  /// the reach, rather than a caption on every reply box explaining a thing
  /// they were not trying to do.
  final bool canEditRecipients;

  /// Faces for the offered people. Null draws initials, which is what a host
  /// without a photo cache gets.
  final ProfilePhotos? recipientPhotos;

  /// Which kind of thread the people are added to: mail makes them Cc and
  /// takes a typed address; a chat mentions them, which needs a Graph id, so
  /// a typed address is no answer there.
  final RecipientChannel recipientChannel;

  /// The sentence refusing [person] on this thread, or null to accept them.
  ///
  /// A chat's mention reaches only somebody IN the chat, so a host that knows
  /// the whole roster refuses anybody outside it here, at the pick, rather
  /// than letting a send go out naming a person Teams will not notify.
  final String? Function(Person person)? refuseRecipient;

  /// The follow-up the next send sets, held by the HOST (which reads it at
  /// send time — [onSend] is unchanged) and drawn as three pills beside
  /// Send while [followUpAvailable] and [onFollowUpChanged] are both there.
  final FollowUpChoice followUp;
  final void Function(FollowUpChoice choice)? onFollowUpChanged;

  /// Whether To Do can carry a follow-up on this thread now. False hides the
  /// pills: no reminder is offered that could not be set.
  final bool followUpAvailable;

  const Composer({
    super.key,
    this.suggestedBody,
    this.provenance,
    this.provenanceFiles = const [],
    this.onOpenProvenanceFile,
    this.streamingBody,
    this.generating = false,
    this.capability = SendCapability.copyOnly,
    required this.onSend,
    this.onGenerate,
    this.improveLabel,
    this.onImprove,
    this.improving = false,
    this.onDismiss,
    this.focusOnMount = false,
    this.onEdited,
    this.sending = false,
    this.hint = 'Write a reply…',
    this.processingOff = false,
    this.focusNode,
    this.addedRecipients = const [],
    this.onRecipientsChanged,
    this.recipientSearch,
    this.canEditRecipients = true,
    this.recipientPhotos,
    this.recipientChannel = RecipientChannel.mail,
    this.refuseRecipient,
    this.followUp = FollowUpChoice.none,
    this.onFollowUpChanged,
    this.followUpAvailable = false,
  });

  /// Long enough that a normal typing rhythm does not write to sqlite between
  /// words, short enough that clicking away right after typing still saves.
  static const Duration editDebounce = Duration(milliseconds: 500);

  /// How present the text looks before anyone has touched it.
  static const double suggestedOpacity = 0.7;

  /// The live preview above the box, while a draft is being written.
  static const Key streamingPreviewKey = Key('composer-streaming-preview');

  /// The Improve button, and the spinner that replaces it while the target is
  /// writing. Keyed because "Improve with …" is half the target's own name,
  /// which a test cannot know.
  static const Key improveKey = Key('composer-improve');
  static const Key improvingKey = Key('composer-improving');

  /// The key of the chip that opens one file, by its `context_files.id`.
  static ValueKey<String> provenanceChipKeyFor(int fileId) =>
      ValueKey('provenance-chip-$fileId');

  /// The way in to the recipients row for a mouse: the `@` is the way in for a
  /// keyboard, and both open the same field.
  static const Key addPeopleKey = Key('composer-add-people');

  /// The picker itself, and the line above it saying who the reply is going to
  /// now. Both are drawn only where this connection can apply the additions.
  static const Key recipientsKey = Key('composer-recipients');
  static const Key recipientsScopeKey = Key('composer-recipients-scope');

  /// The sentence a connection that cannot amend a reply's recipients shows,
  /// once somebody has reached for the feature.
  static const Key recipientsRefusedKey = Key('composer-recipients-refused');

  /// The sentence under the scope line when a pick was turned away by
  /// [refuseRecipient].
  static const Key recipientPickRefusedKey =
      Key('composer-recipient-pick-refused');

  /// The follow-up pills beside Send, and each one by its choice.
  static const Key followUpKey = Key('composer-follow-up');
  static Key followUpChoiceKeyFor(FollowUpChoice choice) =>
      ValueKey('composer-follow-up-${choice.name}');

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final TextEditingController _body =
      TextEditingController(text: widget.suggestedBody ?? '');

  /// Whether the text in the field is still the machine's. Flips on the first
  /// edit and never flips back — a suggestion the user has rewritten does not
  /// become a suggestion again by being deleted.
  bool _touched = false;

  /// The suggestion was closed here, this frame. The host clears its own copy
  /// a beat later; without this the caption would flash back on in between.
  bool _dismissed = false;

  /// The recipients row has been asked for — by the button, or by an `@`.
  ///
  /// One-way: it does not close again when the last chip is removed. Somebody
  /// who opened it is working on who this goes to, and a field that vanished
  /// under them mid-edit would take the `@` they were answering with it.
  bool _showRecipients = false;

  /// The offset of the `@` a pick should turn into a name, or null when there
  /// is no pending one. Cleared by the pick, and by the caret moving off it.
  int? _mentionAt;

  /// Where the text a pick replaces ends: just past the `@` on a chat, and
  /// past the first letter typed after it on mail, which waits for that letter
  /// before it opens anything (see [_mentionAnchor]).
  int? _mentionEnd;

  /// What the body holds between a pending `@` and the end a pick replaces:
  /// the letter that opened the picker on mail, and nothing on a chat.
  String get _mentionQuery {
    final at = _mentionAt;
    final end = _mentionEnd;
    final text = _body.text;
    if (at == null || end == null || end > text.length || at + 1 > end) {
      return '';
    }
    return text.substring(at + 1, end);
  }

  /// Somebody reached for the feature on a connection that cannot apply it.
  ///
  /// Latched, because the reach is the thing worth answering: the sentence
  /// stays until the composer is rebuilt for another thread or another send,
  /// which is when the question is asked again from scratch.
  bool _recipientsRefused = false;

  /// Why the last pick was refused, by [Composer.refuseRecipient]; cleared by
  /// the next change the picker reports.
  String? _pickRefused;

  /// OURS, unlike [Composer.focusNode], and disposed here: it is the `@`
  /// keyboard path's whole implementation — a body keystroke has to be able to
  /// put the cursor in the picker — and nothing outside this widget has any
  /// reason to hold it.
  final FocusNode _recipientsFocus = FocusNode();

  /// Whether this host wired the recipients affordance at all.
  ///
  /// The one place the decision above is read: a host with no directory passes
  /// neither callback, so no part of this — not the button, not the `@`, not
  /// the refusal sentence — exists on its threads.
  bool get _recipientsWired =>
      widget.onRecipientsChanged != null && widget.recipientSearch != null;

  /// Whether the picker is on screen. People already added put it there without
  /// being asked: they are the state, and a chip nobody can see is a person
  /// silently on the reply.
  bool get _recipientsVisible =>
      _recipientsWired &&
      widget.canEditRecipients &&
      (_showRecipients || widget.addedRecipients.isNotEmpty);

  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      // After the first frame, so the node is attached to a scope by the
      // time it is asked for.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.focusNode?.requestFocus();
      });
    }
  }

  Timer? _editDebounce;

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new suggestion arrived — a regenerate landed, or the selection moved to
    // a thread whose draft was already cached. Typed-in text is never
    // overwritten: the user's own words outrank anything the model just wrote.
    if (widget.suggestedBody != oldWidget.suggestedBody && !_touched) {
      _body.text = widget.suggestedBody ?? '';
      _dismissed = false;
    }
  }

  @override
  void dispose() {
    _editDebounce?.cancel();
    _body.dispose();
    _recipientsFocus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (!_touched) setState(() => _touched = true);
    _noteMention(value);
    final notify = widget.onEdited;
    if (notify == null) return;
    _editDebounce?.cancel();
    _editDebounce = Timer(Composer.editDebounce, () {
      if (mounted) notify(_body.text);
    });
  }

  // ── Adding people ─────────────────────────────────────────────────────

  /// The `@` that means "who", if the caret has just asked for one: the offset
  /// of the `@` and the end of what a pick should replace.
  ///
  /// Read off the CARET rather than by diffing the text, so it answers the same
  /// whether the character was typed, pasted or arrowed back to. The `@` has to
  /// begin a word — the one before it is whitespace, or there is none — which is
  /// what keeps a typed address out of it: the caret after the `@` in
  /// `dana@example.com` is not a request for a people picker.
  ///
  /// On a chat the caret sitting right behind the `@` is the request, as it
  /// always was: a chat is written to its members, and `@` there means a name.
  /// On MAIL it waits one character. Mail is prose, and "meet @ 3pm" is a
  /// sentence, not a search: taking the cursor into the picker on the bare `@`
  /// turned " 3pm" into a directory query and left a dangling `@` in the body.
  /// So mail asks only once the character after the `@` is not whitespace,
  /// and that character stays in the body where it was typed, inside the
  /// range a pick replaces.
  ({int at, int end})? _mentionAnchor(String value) {
    final selection = _body.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final caret = selection.baseOffset;
    if (caret <= 0 || caret > value.length) return null;
    bool beginsWord(int at) => at == 0 || value[at - 1].trim().isEmpty;
    if (_isChat) {
      if (value[caret - 1] != '@' || !beginsWord(caret - 1)) return null;
      return (at: caret - 1, end: caret);
    }
    if (caret < 2) return null;
    if (value[caret - 2] != '@' || !beginsWord(caret - 2)) return null;
    if (value[caret - 1].trim().isEmpty) return null;
    return (at: caret - 2, end: caret);
  }

  /// What a body keystroke does about recipients: open the picker on an `@`
  /// that asks for one — on mail, only once a letter follows it — or, where
  /// the connection cannot apply people, say so at that same moment and leave
  /// the text alone.
  ///
  /// Saying so is the whole point of the branch. Swallowing the `@` and drawing
  /// nothing would read as a feature that does not exist; adding people that
  /// silently never reach the send is the one failure the owner could not see.
  void _noteMention(String value) {
    if (!_recipientsWired) return;
    final anchor = _mentionAnchor(value);
    if (anchor == null) {
      if (_mentionAt != null) setState(() => _mentionAt = null);
      return;
    }
    if (!widget.canEditRecipients) {
      if (!_recipientsRefused) setState(() => _recipientsRefused = true);
      return;
    }
    setState(() {
      _mentionAt = anchor.at;
      _mentionEnd = anchor.end;
      _showRecipients = true;
    });
    // After the frame that builds the field: a node that is not in the tree yet
    // has no scope to take focus from.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mentionAt != null) _recipientsFocus.requestFocus();
    });
  }

  void _revealRecipients() {
    setState(() => _showRecipients = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recipientsFocus.requestFocus();
    });
  }

  /// The picker reported a change. Forwarded to the host UNCHANGED — the list is
  /// theirs — after this widget has had its one look at it, for the name.
  ///
  /// Except a person [Composer.refuseRecipient] turns away: they are left out
  /// of what goes to the host, the sentence says why, and the `@` stays as
  /// typed. The host still gets a list — a fresh one — because the field keeps
  /// its own copy of the picks and resyncs only when the value it is handed
  /// changes.
  void _pickedRecipients(List<Person> next) {
    final refuse = widget.refuseRecipient;
    if (refuse != null) {
      final before = {for (final person in widget.addedRecipients) person.id};
      String? refused;
      final kept = <Person>[];
      for (final person in next) {
        final reason = before.contains(person.id) ? null : refuse(person);
        if (reason == null) {
          kept.add(person);
        } else {
          refused = reason;
        }
      }
      if (refused != _pickRefused) setState(() => _pickRefused = refused);
      if (refused != null) {
        setState(() => _mentionAt = null);
        widget.onRecipientsChanged!(List.of(kept));
        return;
      }
    }
    final person = _newlyAdded(next);
    if (person != null) _writeMentionName(person);
    widget.onRecipientsChanged!(next);
  }

  /// Whoever is in [next] and was not in [Composer.addedRecipients], or null for
  /// a removal.
  ///
  /// By [Person.id], which is `Person`'s own identity and is never empty —
  /// `addressKey` is empty for anyone with no address, and two of those would
  /// read as the same person here.
  Person? _newlyAdded(List<Person> next) {
    if (next.length <= widget.addedRecipients.length) return null;
    final before = {for (final person in widget.addedRecipients) person.id};
    for (final person in next.reversed) {
      if (!before.contains(person.id)) return person;
    }
    return null;
  }

  /// Turns the pending `@` into `@Name `, so the sentence somebody was writing
  /// reads as addressed to the person they just added.
  ///
  /// PLAIN TEXT and nothing more: it notifies nobody by itself, which is why it
  /// only ever accompanies a real Cc line on mail, or a real mention on a chat
  /// — where the send turns this very `@Name` into the mention's at-tag. A pick
  /// made from the button has no anchor and writes nothing into the body — they
  /// were adding a recipient, not naming one mid-sentence.
  void _writeMentionName(Person person) {
    final anchor = _mentionAt;
    if (anchor == null) return;
    final text = _body.text;
    if (anchor >= text.length || text[anchor] != '@') {
      setState(() => _mentionAt = null);
      return;
    }
    final name =
        person.displayName.isNotEmpty ? person.displayName : person.address;
    final written = '@$name ';
    // The `@` alone on a chat; on mail, the `@` and the letter that asked for
    // the picker, so "@d" becomes the name rather than the name followed by a
    // stray "d". Clamped, because the body may have been edited since.
    final end = (_mentionEnd ?? anchor + 1).clamp(anchor + 1, text.length);
    final next = text.replaceRange(anchor, end, written);
    _body.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: anchor + written.length),
    );
    setState(() => _mentionAt = null);
    // The host's debounced save has to learn about a change it did not see a
    // keystroke for; `onChanged` does not fire for a programmatic write.
    _onChanged(next);
    // Back into the sentence, which is where they were. The chip is already
    // drawn and the next word is more likely than the next recipient.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode?.requestFocus();
    });
  }

  void _dismiss() {
    _editDebounce?.cancel();
    _body.clear();
    setState(() {
      _touched = false;
      _dismissed = true;
    });
    widget.onDismiss?.call();
  }

  /// True while the field holds an untouched suggestion — the only state that
  /// draws the accent rule and the provenance caption.
  bool get _showingSuggestion =>
      !_touched && !_dismissed && (widget.suggestedBody?.isNotEmpty ?? false);

  String get _sendLabel => switch (widget.capability) {
        SendCapability.send => 'Send',
        SendCapability.draftToOutlook => 'Save to Outlook Drafts',
        SendCapability.copyOnly => 'Copy reply',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(BondSpacing.s12),
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showingSuggestion && widget.provenance != null) ...[
            _provenanceRow(widget.provenance!),
            const SizedBox(height: BondSpacing.s8),
          ],
          if (_showingSuggestion &&
              widget.provenanceFiles.isNotEmpty &&
              widget.onOpenProvenanceFile != null) ...[
            _provenanceChips(),
            const SizedBox(height: BondSpacing.s8),
          ],
          if ((widget.streamingBody ?? '').isNotEmpty) ...[
            _streamingPreview(widget.streamingBody!),
            const SizedBox(height: BondSpacing.s8),
          ],
          ?_recipients(),
          _field(),
          const SizedBox(height: BondSpacing.s8),
          _buttons(),
        ],
      ),
    );
  }

  /// The reply as the model is writing it: read-only, in the suggestion's own
  /// dress, behind the same accent rule the box draws around an untouched
  /// draft.
  ///
  /// Above the field rather than in it, on purpose. The controller belongs to
  /// the reader — a sentence they started while waiting must survive the draft
  /// landing — so nothing here touches it, and the finished suggestion arrives
  /// through the host's ordinary staging exactly as it did before any of this
  /// streamed.
  Widget _streamingPreview(String body) {
    return _suggestionRule(
      key: Composer.streamingPreviewKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Drafting…', style: BondType.caption),
          const SizedBox(height: 2),
          Text(
            // The block cursor is the whole of the "still being written"
            // signal: no animation, because nothing on this screen loops.
            '$body▍',
            style: BondType.body.copyWith(
              color: BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
            ),
          ),
        ],
      ),
    );
  }

  /// A rule down the left, the way a quoted passage is marked: what sits
  /// inside it is here to be read and changed, not to be signed off on.
  ///
  /// One helper because this widget draws it twice, around the two
  /// machine-written things it shows — the untouched suggestion IN the box,
  /// and the draft still arriving above it — and two copies of the mark that
  /// says "not yours yet" could drift into meaning two different things.
  Widget _suggestionRule({required Widget child, Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.only(left: BondSpacing.s8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: BondColors.seaGlassOnDark, width: 2),
        ),
      ),
      child: child,
    );
  }

  Widget _provenanceRow(String provenance) {
    return Row(
      children: [
        Expanded(
          child: Text(
            provenance,
            style: BondType.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          onPressed: widget.onDismiss == null ? null : _dismiss,
          icon: const Icon(Icons.close),
          iconSize: 16,
          tooltip: 'Clear the box',
          padding: const EdgeInsets.all(BondSpacing.s4),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// One small button per file the draft read, labelled the way the caption
  /// labels it — same path, same breadcrumb — so a chip is recognisably the
  /// thing the sentence above it just named.
  Widget _provenanceChips() {
    final open = widget.onOpenProvenanceFile!;
    return Wrap(
      spacing: BondSpacing.s4,
      children: [
        for (final file in widget.provenanceFiles)
          TextButton(
            key: Composer.provenanceChipKeyFor(file.fileId),
            onPressed: () => open(file),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: BondSpacing.s8,
                vertical: BondSpacing.s4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: BondType.caption,
            ),
            child: Text(
              file.locator.isEmpty
                  ? file.path
                  : '${file.path} § '
                      '${DraftProvenance.locatorLabel(file.locator)}',
              style: BondType.caption,
            ),
          ),
      ],
    );
  }

  /// Everything about who else this reply goes to, or null when there is
  /// nothing to say: a host with no directory behind it, or a connection that
  /// cannot apply people and nobody has asked yet.
  ///
  /// The null is what keeps a reply box a reply box. Every thread in the app
  /// would otherwise carry a standing line about recipients, and almost no reply
  /// adds anybody.
  Widget? _recipients() {
    if (!_recipientsWired) return null;

    if (!widget.canEditRecipients) {
      if (!_recipientsRefused) return null;
      return Padding(
        key: Composer.recipientsRefusedKey,
        padding: const EdgeInsets.only(bottom: BondSpacing.s8),
        child: Text(
          'This connection cannot add people to a reply, so this one goes to '
          'the sender only. Open it in Outlook to add anybody.',
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      );
    }

    if (!_recipientsVisible) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: Composer.addPeopleKey,
          onPressed: _revealRecipients,
          icon: const Icon(Icons.person_add_alt, size: 16),
          label: const Text('Add people'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: BondSpacing.s8,
              vertical: BondSpacing.s4,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            textStyle: BondType.caption,
          ),
        ),
      );
    }

    return Padding(
      key: Composer.recipientsKey,
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            key: Composer.recipientsScopeKey,
            _scopeLine,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
          if (_pickRefused != null) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(
              key: Composer.recipientPickRefusedKey,
              _pickRefused!,
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
          ],
          const SizedBox(height: BondSpacing.s4),
          RecipientsField(
            value: widget.addedRecipients,
            onChanged: _pickedRecipients,
            search: widget.recipientSearch!,
            // A typed address is a legitimate answer on mail in a way it is
            // not for a chat, where there is no Graph id behind one to
            // mention anybody with.
            channel: widget.recipientChannel,
            allowTypedAddress: !_isChat,
            focusNode: _recipientsFocus,
            photos: widget.recipientPhotos,
            // The letters typed after a mail `@`, which is what asked for this
            // field; empty on a chat, where the bare `@` asks, and from the
            // button. Read once, when the field is first built.
            initialQuery: _mentionQuery,
            hint: _isChat
                ? 'Mention people in this reply'
                : 'Add people to this reply',
          ),
        ],
      ),
    );
  }

  /// Who the reply is going to, said out loud.
  ///
  /// The server's own `/createReply` addresses the sender and nobody else, so
  /// this is never "Reply all" — it is that reply plus whoever the owner added,
  /// and the count is the honest way to say it while the chips sit underneath
  /// naming them.
  ///
  /// A chat has no sender-only reply to promise — everybody in it reads the
  /// message — so there the line counts who will be notified by name.
  String get _scopeLine {
    final count = widget.addedRecipients.length;
    final people = count == 1 ? '1 person' : '$count people';
    if (_isChat) {
      return count == 0
          ? 'Reply in this chat'
          : 'Reply in this chat, mentioning $people';
    }
    if (count == 0) return 'Reply to the sender only';
    return 'Reply to the sender, plus $people in Cc';
  }

  bool get _isChat => widget.recipientChannel == RecipientChannel.teams;

  Widget _field() {
    final field = TextField(
      controller: _body,
      focusNode: widget.focusNode,
      onChanged: _onChanged,
      // One line until there is something to hold: an empty box that opened
      // three lines tall claimed the space of a reply nobody had written yet.
      minLines: 1,
      maxLines: 10,
      style: _showingSuggestion
          ? BondType.body.copyWith(
              color: BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
            )
          : BondType.body,
      decoration: InputDecoration(
        hintText: widget.hint,
        border: InputBorder.none,
      ),
    );

    if (!_showingSuggestion) return field;
    return _suggestionRule(child: field);
  }

  /// Both buttons read the field, so both live under one listener: emptying
  /// the box has to disable Send AND turn Regenerate back into Draft reply, and
  /// `onChanged` alone rebuilds only on the first keystroke.
  Widget _buttons() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _body,
      builder: (context, value, _) {
        final text = value.text.trim();
        final row = Row(
          children: [
            if (widget.onGenerate != null) _generateButton(text.isNotEmpty),
            // Only beside a draft that exists: there is nothing to improve
            // until the local model has written something.
            //
            // FLEXIBLE, because the label carries a target's own name and this
            // row sits in a side panel: Improve a draft is always routed since
            // Round H, so the button is there on every draft and a long name
            // has to shorten rather than overflow the row.
            if (widget.improveLabel != null && text.isNotEmpty)
              Flexible(child: _improveButton()),
            const Spacer(),
            _sendButton(text.isNotEmpty, value.text),
          ],
        );
        if (!_followUpShown) return row;
        // A line of their own just above Send, right-aligned under the box:
        // in the row they would take Improve's room, which a side panel
        // does not have, and they scroll sideways rather than overflow.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: _followUpPills(),
              ),
            ),
            row,
          ],
        );
      },
    );
  }

  bool get _followUpShown =>
      widget.followUpAvailable && widget.onFollowUpChanged != null;

  /// No follow-up | 2 days | 1 week, the chosen one filled. A choice only:
  /// nothing is set until Send, and the host reads it then.
  Widget _followUpPills() {
    final change = widget.onFollowUpChanged!;
    return Tooltip(
      message: 'Follow up if nobody replies',
      waitDuration: const Duration(milliseconds: 300),
      child: Row(
        key: Composer.followUpKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.alarm_outlined,
              size: 16, color: BondColors.inkMuted),
          const SizedBox(width: BondSpacing.s4),
          for (final choice in FollowUpChoice.values)
            Semantics(
              selected: choice == widget.followUp,
              child: TextButton(
                key: Composer.followUpChoiceKeyFor(choice),
                onPressed: () => change(choice),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: BondType.caption,
                  backgroundColor: choice == widget.followUp
                      ? BondColors.primary.withValues(alpha: 0.12)
                      : null,
                ),
                child: Text(choice.label),
              ),
            ),
        ],
      ),
    );
  }

  Widget _generateButton(bool hasDraft) {
    if (widget.generating) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: BondSpacing.s12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final button = TextButton.icon(
      onPressed: widget.processingOff ? null : widget.onGenerate,
      icon: Icon(hasDraft ? Icons.refresh : Icons.auto_awesome, size: 16),
      label: Text(hasDraft ? 'Regenerate' : 'Draft reply'),
    );
    // Only while off. A tooltip on the working button would be a label saying
    // what the label already says.
    if (!widget.processingOff) return button;
    return Tooltip(message: 'Processing is off', child: button);
  }

  /// The same prompt on another target, replacing what is in the box.
  ///
  /// Disabled while the switch is off, for a reason of its own rather than
  /// [_generateButton]'s: Improve dials the handler directly and never a
  /// drain, so it WOULD run, and a person who turned processing off does not
  /// expect a paid call to another machine. Also disabled while a draft is
  /// being written: the two would be writing the same row.
  Widget _improveButton() {
    if (widget.improving) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: BondSpacing.s12),
        child: SizedBox(
          key: Composer.improvingKey,
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final button = TextButton.icon(
      key: Composer.improveKey,
      onPressed: (widget.processingOff || widget.generating)
          ? null
          : widget.onImprove,
      icon: const Icon(Icons.auto_fix_high, size: 16),
      label: Text(widget.improveLabel!, overflow: TextOverflow.ellipsis),
    );
    // Only while off, on the generate button's rule: a tooltip on a button
    // disabled for the obvious reason beside it would be noise.
    if (!widget.processingOff) return button;
    return Tooltip(message: 'Processing is off', child: button);
  }

  /// Disabled on an empty field, and while a send is already in flight. Both
  /// are the same rule: the button may only ever act on words that exist and
  /// have not been sent.
  ///
  /// This `onPressed` is the ONLY thing in this widget that calls
  /// [Composer.onSend].
  Widget _sendButton(bool hasText, String body) {
    final enabled = hasText && !widget.sending;
    return ElevatedButton(
      onPressed: enabled
          ? () {
              // A pending edit-save must not fire while the send is in
              // flight — the send is already carrying this exact text, and a
              // trailing markEdited would rewrite the record of it.
              _editDebounce?.cancel();
              widget.onSend(body);
            }
          : null,
      child: widget.sending
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(_sendLabel),
    );
  }
}
