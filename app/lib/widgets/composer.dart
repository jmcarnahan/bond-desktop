import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

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

/// The reply box under a thread: a suggested draft the user edits, and the one
/// button that sends it.
///
/// **Nothing here sends on its own.** [onSend] fires from exactly one place —
/// the primary button's `onPressed` — and there is no timer, no autosave-then-
/// send, and no "accept" that turns into a send. A draft the user never clicks
/// stays text in a box.
///
/// The suggested state is drawn as visibly *not yet theirs*: the text sits at
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

  /// Throws the suggestion away and leaves an empty box.
  final VoidCallback? onDismiss;

  /// The user started editing. Debounced, so it fires on pauses rather than on
  /// keystrokes.
  final void Function(String body)? onEdited;

  /// True while a send is in flight: the primary button disables and shows a
  /// spinner, so a second click cannot send the same reply twice.
  final bool sending;

  const Composer({
    super.key,
    this.suggestedBody,
    this.provenance,
    this.generating = false,
    this.capability = SendCapability.copyOnly,
    required this.onSend,
    this.onGenerate,
    this.onDismiss,
    this.onEdited,
    this.sending = false,
  });

  /// Long enough that a normal typing rhythm does not write to sqlite between
  /// words, short enough that clicking away right after typing still saves.
  static const Duration editDebounce = Duration(milliseconds: 500);

  /// How present the text looks before anyone has touched it.
  static const double suggestedOpacity = 0.7;

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
    super.dispose();
  }

  void _onChanged(String value) {
    if (!_touched) setState(() => _touched = true);
    final notify = widget.onEdited;
    if (notify == null) return;
    _editDebounce?.cancel();
    _editDebounce = Timer(Composer.editDebounce, () {
      if (mounted) notify(_body.text);
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
          _field(),
          const SizedBox(height: BondSpacing.s8),
          _buttons(),
        ],
      ),
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
          tooltip: 'Dismiss this suggestion',
          padding: const EdgeInsets.all(BondSpacing.s4),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _field() {
    final field = TextField(
      controller: _body,
      onChanged: _onChanged,
      minLines: 3,
      maxLines: 10,
      style: _showingSuggestion
          ? BondType.body.copyWith(
              color: BondColors.ink.withValues(alpha: Composer.suggestedOpacity),
            )
          : BondType.body,
      decoration: const InputDecoration(
        hintText: 'Write a reply…',
        border: InputBorder.none,
      ),
    );

    if (!_showingSuggestion) return field;

    // A rule down the left, the way a quoted passage is marked: this text is
    // here to be read and changed, not to be signed off on.
    return Container(
      padding: const EdgeInsets.only(left: BondSpacing.s8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: BondColors.seaGlassOnDark, width: 2),
        ),
      ),
      child: field,
    );
  }

  /// Both buttons read the field, so both live under one listener: emptying
  /// the box has to disable Send AND turn Regenerate back into Draft reply, and
  /// `onChanged` alone rebuilds only on the first keystroke.
  Widget _buttons() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _body,
      builder: (context, value, _) {
        final text = value.text.trim();
        return Row(
          children: [
            if (widget.onGenerate != null) _generateButton(text.isNotEmpty),
            const Spacer(),
            _sendButton(text.isNotEmpty, value.text),
          ],
        );
      },
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
    return TextButton.icon(
      onPressed: widget.onGenerate,
      icon: Icon(hasDraft ? Icons.refresh : Icons.auto_awesome, size: 16),
      label: Text(hasDraft ? 'Regenerate' : 'Draft reply'),
    );
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
