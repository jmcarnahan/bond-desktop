import 'package:flutter/material.dart';

import '../models/calendar_models.dart' show CalendarDate, CalendarEvent;
import '../services/calendar/calendar_writes.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/command/command_planner.dart';
import '../services/calendar/command/command_types.dart' show KnownPerson;
import '../services/calendar/command/people_matcher.dart' show matchPeople;
import '../services/calendar/calendar_sync.dart' show CalendarAvailability;
import '../services/calendar/day_items.dart'
    show formatEventRange, offlineCaption, overlapLine, shortDate;
import '../services/calendar/overlaps.dart' show FreeSlot;
import '../services/calendar/write_rules.dart'
    show emailedLine, mayEmailFor, writeDoneMessage, writeSummary;
import '../theme/tokens.dart';
import 'calendar_write_flow.dart';

/// What one Enter in the Day command bar produced, drawn inline under the
/// bar (docs/pipeline/14-calendar.md "Commands").
///
/// Prop-only: the host owns the plan and every step after a press. A
/// proposal starts its write through [CalendarWriteFlow], the one state
/// machine every calendar write shares, so a command that emails someone
/// waits on the same inline confirm strip a button press would, and a
/// private one goes straight on and offers the same Undo. Slots and choices
/// are handed back up: a pressed slot needs the planner's dry run
/// ([onPickSlot]), a pressed choice the router again with that choice bound
/// ([onChoose]), and both give the host a new plan to draw here.
///
/// The words on the card are the planner's: summaries, answers and reasons
/// arrive written. Subjects inside them are the organiser's text, so they
/// are plain [Text], never markup.
///
/// **Height.** A week's agenda is a long answer, so the card is capped —
/// [maxHeight], or less where its host says ([maxHeightIn]) — and scrolls
/// inside that rather than pushing the day off the pane or overflowing it.
class CommandPlanCard extends StatelessWidget {
  const CommandPlanCard({
    super.key,
    required this.plan,
    required this.zone,
    required this.today,
    required this.writer,
    required this.onDone,
    required this.onDismiss,
    required this.onPickSlot,
    required this.onChoose,
    this.onOpenEvent,
    this.onFailed,
    this.availability = CalendarAvailability.unknown,
    this.subjectEditable = false,
    this.onSubjectChanged,
    this.flash = 0,
    this.onWritingChanged,
    this.people = const [],
    this.searchPeople,
    this.onAttendeesChanged,
    this.initialAttendees = const [],
    this.initialSubject,
  });

  static const Key doKey = ValueKey('command-plan-do');
  static const Key subjectKey = ValueKey('command-plan-subject');
  static const Key withKey = ValueKey('command-plan-with');
  static const Key unknownPersonKey = ValueKey('command-plan-unknown-person');
  static Key chipKeyFor(String address) =>
      ValueKey('command-plan-chip-$address');
  static Key candidateKeyFor(int i) => ValueKey('command-plan-candidate-$i');
  static const Key flashKey = ValueKey('command-plan-flash');
  static const Key cancelKey = ValueKey('command-plan-cancel');
  static const Key answerKey = ValueKey('command-plan-answer');
  static const Key reasonKey = ValueKey('command-plan-reason');
  static const Key summaryKey = ValueKey('command-plan-summary');
  static const Key overlapKey = ValueKey('command-plan-overlap');
  static const Key emailsKey = ValueKey('command-plan-emails');
  static const Key titleKey = ValueKey('command-plan-title');
  static Key slotKeyFor(int i) => ValueKey('command-plan-slot-$i');
  static Key optionKeyFor(int i) => ValueKey('command-plan-option-$i');
  static Key linkKeyFor(String eventId) =>
      ValueKey('command-plan-link-$eventId');

  /// The tallest the card ever draws.
  static const double maxHeight = 320;

  /// The cap in a pane [paneHeight] tall: [maxHeight], or 40% of the pane
  /// when that is less. An unbounded pane gets [maxHeight].
  static double maxHeightIn(double paneHeight) {
    if (!paneHeight.isFinite) return maxHeight;
    final share = paneHeight * 0.4;
    return share < maxHeight ? share : maxHeight;
  }

  /// The caption under a [SlotChoice]'s buttons, by where the slots came
  /// from.
  static const String localCaption = 'from your calendar';
  static const String graphCaption = 'when everyone is free';

  final CommandPlan plan;
  final CalendarZone zone;
  final CalendarDate today;
  final CalendarWriter writer;

  /// A write went through: the host toasts [message], offers [undo] when
  /// non-null, and drops the plan.
  final void Function(String message, CalendarWrite? undo) onDone;

  /// A write that failed after the card had gone (a new Enter replaced it):
  /// the host toasts [CalendarWriteFlow.onFailed]'s sentence.
  final void Function(String message)? onFailed;

  /// The calendar's availability as the host reads it. Offline, a plan drawn
  /// from the mirror (an answer, slots, a proposal) says so in one line.
  final CalendarAvailability availability;

  static const Key offlineKey = ValueKey('command-plan-offline');

  /// Cancel and ✕: the host drops the plan.
  final VoidCallback onDismiss;

  /// A slot pressed: the host dry-runs `choice.buildWrite(slot)` and draws
  /// the proposal that comes back.
  final Future<void> Function(SlotChoice choice, FreeSlot slot) onPickSlot;

  /// A [NeedsChoice] option pressed: the host submits the same text again
  /// with the option bound.
  final Future<void> Function(CommandOption option) onChoose;

  /// Opens one event beside, from an [Answer]'s link. Null draws the links
  /// as plain words.
  final void Function(String eventId)? onOpenEvent;

  /// A blank event picked on the grid: a create proposal's face gains a
  /// name field above the summary, and the press writes the create under
  /// the typed name (`New event` when left empty) and its own transaction
  /// id. The dry run stands as it was — a name changes nobody it emails.
  final bool subjectEditable;

  /// The blank event's name as it is typed, so the host can draw the grid's
  /// ghost under the same name.
  final ValueChanged<String>? onSubjectChanged;

  /// Bumped by the host to flash the card once (its ghost was tapped): a
  /// 600 ms fade of a primary border back to the plain one, run once per
  /// new value and never looping. Zero is no flash.
  final int flash;

  /// True as a proposal's real write goes out, false once its flow is idle
  /// again (done, failed or dismissed): the host keeps the grid's ghost
  /// still meanwhile, so the write in the air is the one the card shows.
  final ValueChanged<bool>? onWritingChanged;

  /// The blank event's With line matches typed names against these — the
  /// People directory, the same set the command bar's names come from
  /// (`matchPeople`).
  final List<KnownPerson> people;

  /// Looks up a name [people] does not have, on Enter, as the command bar
  /// does (`PeopleBackend.searchPeople`). Null refuses an unknown name with
  /// the planner's own sentence. A throw is said as [directoryFailedText],
  /// never as a name nobody has.
  final Future<List<KnownPerson>> Function(String query)? searchPeople;

  /// The blank event's guests as the chips now read: lowercased addresses,
  /// told after every change, so the host can carry them into a
  /// re-proposal.
  final ValueChanged<List<String>>? onAttendeesChanged;

  /// The guests a re-proposal carries over; the chips start from these.
  final List<String> initialAttendees;

  /// The name a re-proposal carries over, as the field last read: the
  /// re-proposal's card is a new one (its key moves with the serial) built
  /// while its dry run is out, so without this its field would start from
  /// the old write's subject and a name typed meanwhile would be lost. Null
  /// starts from the write's subject.
  final String? initialSubject;

  /// The caption under the With line when the directory search threw.
  static const String directoryFailedText = "Couldn't search the directory.";

  @override
  Widget build(BuildContext context) {
    final Widget planBody = switch (plan) {
      final CalendarProposal p
          when subjectEditable && p.write is CreateEvent =>
        _NamedProposal(card: this, proposal: p),
      final CalendarProposal p => _proposal(p),
      final SlotChoice c => _slots(c),
      final Answer a => _answer(a),
      final NeedsChoice c => _choice(c),
      final CannotDo c => _cannot(c),
    };
    final fromMirror =
        plan is CalendarProposal || plan is SlotChoice || plan is Answer;
    final body = availability == CalendarAvailability.unavailable && fromMirror
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                offlineCaption,
                key: offlineKey,
                style: BondType.caption.copyWith(color: BondColors.inkMuted),
              ),
              const SizedBox(height: BondSpacing.s8),
              planBody,
            ],
          )
        : planBody;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: maxHeight),
      child: _FlashFrame(
        flash: flash,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(BondSpacing.s12),
          child: body,
        ),
      ),
    );
  }

  Widget _cancel() => TextButton(
        key: cancelKey,
        onPressed: onDismiss,
        child: const Text('Cancel'),
      );

  Widget _close() => IconButton(
        key: cancelKey,
        tooltip: 'Dismiss',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        onPressed: onDismiss,
        icon: const Icon(Icons.close),
      );

  /// The dry-run write, its overlap and who it emails, and Do it. The flow
  /// runs the dry run again on the press — the calendar may have moved
  /// since Enter — and shows its own strip when that says confirm.
  ///
  /// [fields], [summary] and [write] are the blank event's: the name and
  /// With lines above the summary (drawn off while the flow is busy, so
  /// what goes out is what the card shows), the summary as the name now
  /// reads, and the write under that name and those guests at the press.
  /// Who it may email is read off that write, so a guest added on the card
  /// is said here and on the strip although the dry run at the grid press
  /// had nobody to name.
  ///
  /// [ready] runs first on the press and may refuse it (the With line's
  /// pending text that did not resolve); [held] keeps the button off (a
  /// directory lookup still out).
  Widget _proposal(
    CalendarProposal p, {
    Widget Function(bool busy)? fields,
    String? summary,
    CalendarWrite Function()? write,
    Future<bool> Function()? ready,
    bool held = false,
  }) {
    final named = write;
    final overlaps = p.overlaps;
    final overlap = overlaps == null ? null : overlapLine(overlaps);
    final mayEmail = mayEmailFor(named?.call() ?? p.write, event: p.targetEvent);
    final emails = emailedLine(p.notifies, mayEmail: mayEmail);
    return CalendarWriteFlow(
      key: ValueKey('command-plan-flow-${identityHashCode(p)}'),
      writer: writer,
      onDone: onDone,
      onFailed: onFailed,
      onCommitting: onWritingChanged == null
          ? null
          : () => onWritingChanged!(true),
      onIdle: onWritingChanged == null ? null : () => onWritingChanged!(false),
      builder: (context, start, busy) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fields != null) ...[
            fields(busy),
            const SizedBox(height: BondSpacing.s8),
          ],
          Text(summary ?? p.summary, key: summaryKey, style: BondType.small),
          if (overlap != null) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(
              overlap,
              key: overlapKey,
              style: BondType.caption.copyWith(color: BondColors.attention),
            ),
          ],
          // The strip names the same people once it is up; said here only
          // until the press, so the card never says it twice.
          if (emails != null && !busy) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(
              emails,
              key: emailsKey,
              style: BondType.caption.copyWith(color: BondColors.inkSecondary),
            ),
          ],
          const SizedBox(height: BondSpacing.s8),
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                key: doKey,
                onPressed: busy || held
                    ? null
                    : () async {
                        if (ready != null && !await ready()) return;
                        // Read at the press, after [ready]: a name it took
                        // is on the write, the summary and who it emails.
                        final w = named?.call() ?? p.write;
                        start(w,
                            summary: named == null
                                ? (summary ?? p.summary)
                                : writeSummary(w,
                                    shown: const CalendarEvent(id: ''),
                                    series: false,
                                    zone: zone,
                                    today: today),
                            // A named blank event's toast says the typed name.
                            doneMessage: named == null
                                ? p.doneMessage
                                : writeDoneMessage(w,
                                    shown: null, series: false, zone: zone),
                            mayEmail: named == null
                                ? mayEmail
                                : mayEmailFor(w, event: p.targetEvent));
                      },
                // A blank event with guests sends invites, so it says Send
                // although its dry run named nobody.
                child: Text(p.notifies.isEmpty &&
                        (named == null || mayEmail.isEmpty)
                    ? 'Do it'
                    : 'Send'),
              ),
              TextButton(
                key: cancelKey,
                onPressed: busy ? null : onDismiss,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slots(SlotChoice c) {
    final slots = c.slots.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(c.title, key: titleKey, style: BondType.small),
        const SizedBox(height: BondSpacing.s8),
        Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < slots.length; i++)
              OutlinedButton(
                key: slotKeyFor(i),
                onPressed: () => onPickSlot(c, slots[i]),
                child: Text('${shortDate(zone.dateOf(slots[i].startUtc))} · '
                    '${formatEventRange(zone, slots[i].startUtc, slots[i].endUtc)}'),
              ),
            _cancel(),
          ],
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(
          c.source == 'graph' ? graphCaption : localCaption,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
    );
  }

  Widget _answer(Answer a) {
    final open = onOpenEvent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(a.text, key: answerKey, style: BondType.small),
              if (a.links.isNotEmpty) ...[
                const SizedBox(height: BondSpacing.s8),
                Wrap(
                  spacing: BondSpacing.s4,
                  runSpacing: BondSpacing.s4,
                  children: [
                    for (final link in a.links)
                      ActionChip(
                        key: linkKeyFor(link.eventId),
                        label: Text(link.label, style: BondType.caption),
                        visualDensity: VisualDensity.compact,
                        onPressed: open == null
                            ? null
                            : () => open(link.eventId),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        _close(),
      ],
    );
  }

  Widget _choice(NeedsChoice c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.question, key: titleKey, style: BondType.small),
          const SizedBox(height: BondSpacing.s8),
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < c.options.length; i++)
                OutlinedButton(
                  key: optionKeyFor(i),
                  onPressed: () => onChoose(c.options[i]),
                  child: Text(c.options[i].label),
                ),
              _cancel(),
            ],
          ),
        ],
      );

  Widget _cannot(CannotDo c) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              c.reason,
              key: reasonKey,
              style: BondType.small.copyWith(color: BondColors.inkSecondary),
            ),
          ),
          _close(),
        ],
      );
}

/// The card's frame and its flash: a primary border and tint that fade back
/// to the plain ones over 600 ms, once per new [flash] value.
///
/// Only the frame animates. [child] — the card's body — is handed through
/// the same element every frame and is never keyed by the flash, so a ghost
/// tap leaves everything inside standing: a typed name, a confirm strip that
/// is up, a write in the air. Keying the body by the flash value rebuilt it
/// from scratch on every tap, which reset the name field under the host's
/// copy of it, took a standing strip down, and disposed a committing flow
/// before it could say it was idle again.
class _FlashFrame extends StatefulWidget {
  const _FlashFrame({required this.flash, required this.child});

  final int flash;
  final Widget child;

  @override
  State<_FlashFrame> createState() => _FlashFrameState();
}

class _FlashFrameState extends State<_FlashFrame>
    with SingleTickerProviderStateMixin {
  /// 1 at the start of a flash, 0 at rest; a card built fresh rests, whatever
  /// value the host's counter holds.
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: 0,
  );

  @override
  void didUpdateWidget(_FlashFrame old) {
    super.didUpdateWidget(old);
    if (widget.flash != old.flash && widget.flash != 0) {
      _t.reverse(from: 1);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (context, child) {
          final t = _t.value;
          return Container(
            key: CommandPlanCard.flashKey,
            decoration: BoxDecoration(
              color: Color.lerp(BondColors.surface,
                  BondColors.primary.withValues(alpha: 0.08), t),
              borderRadius: BondRadii.mdAll,
              // A fixed width: only the colour moves, so nothing inside
              // shifts by a pixel as it fades.
              border: Border.all(
                color: Color.lerp(BondColors.border, BondColors.primary, t)!,
                width: 2,
              ),
            ),
            child: child,
          );
        },
      );
}

/// A create proposal with a name and guests to give it: the blank event
/// picked on the grid. Owns the fields' controllers and the chips; the face
/// is the card's own.
///
/// The name field starts EMPTY under its hint: prefilled, the cursor sat
/// after "New event" and the first keystroke wrote "New eventL". Blank still
/// writes `New event`, and the summary says so while it is blank.
///
/// The With line takes names the way the command bar does: on Enter or a
/// comma, each name goes through `matchPeople` against the directory; one
/// person is a chip, several are buttons to pick from, an address is that
/// address, and a name the directory lacks is looked up
/// ([CommandPlanCard.searchPeople]) or refused in the planner's own
/// sentence. With anyone on it the create confirms (`needsConfirm`), so the
/// press shows the strip and names them; with nobody it goes straight on and
/// offers Undo, as before.
class _NamedProposal extends StatefulWidget {
  const _NamedProposal({required this.card, required this.proposal});

  final CommandPlanCard card;
  final CalendarProposal proposal;

  @override
  State<_NamedProposal> createState() => _NamedProposalState();
}

class _NamedProposalState extends State<_NamedProposal> {
  /// A re-proposal carries the typed name in its write; the default is the
  /// blank field's stand-in, never text in it.
  late final TextEditingController _name = TextEditingController(
      text: widget.card.initialSubject ??
          () {
            final subject = (widget.proposal.write as CreateEvent).subject;
            return subject == blankEventSubject ? '' : subject;
          }());
  final TextEditingController _with = TextEditingController();

  /// The chips, in the order chosen.
  late final List<KnownPerson> _chips = [
    for (final a in widget.card.initialAttendees.isNotEmpty
        ? widget.card.initialAttendees
        : (widget.proposal.write as CreateEvent).attendees)
      _personFor(a),
  ];

  /// Candidates for the last name that meant several people.
  List<KnownPerson> _candidates = const [];

  /// The caption for the last name nobody had, or null.
  String? _unknown;

  /// A directory lookup is out: Do it waits for it.
  bool _looking = false;

  /// Whether the card's write is out, as the flow last built the fields:
  /// a lookup answering after the press adds nobody to a write already
  /// gone.
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _with.dispose();
    super.dispose();
  }

  /// [address] as the directory knows it, or the bare address.
  KnownPerson _personFor(String address) {
    final a = address.trim().toLowerCase();
    for (final p in widget.card.people) {
      if (p.address == a) return p;
    }
    return KnownPerson(name: '', address: a);
  }

  /// The write under the name and guests as they now read; an empty name
  /// keeps the default.
  CreateEvent _write() {
    final create = widget.proposal.write as CreateEvent;
    final name = _name.text.trim();
    return create
        .withSubject(name.isEmpty ? blankEventSubject : name)
        .withAttendees([for (final p in _chips) p.address]);
  }

  void _setChips(void Function(List<KnownPerson> chips) change) {
    setState(() => change(_chips));
    widget.card.onAttendeesChanged
        ?.call([for (final p in _chips) p.address]);
  }

  void _add(Iterable<KnownPerson> people) {
    final fresh = <KnownPerson>[];
    for (final p in people) {
      if (!_chips.any((c) => c.address == p.address) &&
          !fresh.any((c) => c.address == p.address)) {
        fresh.add(p);
      }
    }
    if (fresh.isNotEmpty) _setChips((chips) => chips.addAll(fresh));
  }

  /// What the With field holds, taken as one or more names: by commas and
  /// "and", each matched on its own. A name the matcher covers only in part
  /// ("Dana Kim" when only Dana Reyes is known) is a name it does not know,
  /// never the part it did.
  ///
  /// True when every name became a chip (nothing left to pick, nobody
  /// unknown, no lookup failed) — what the press waits on for text typed
  /// without an Enter.
  Future<bool> _take(String text) async {
    final parts = text
        .split(RegExp(r'[,;]|\s+and\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return true;
    setState(() {
      _with.clear();
      _candidates = const [];
      _unknown = null;
    });
    final people = widget.card.people;
    final found = <KnownPerson>[];
    final choices = <KnownPerson>[];
    final unknown = <String>[];
    for (final part in parts) {
      final m = matchPeople(part, people);
      if (m.isEmpty || m.unresolved.isNotEmpty || !_covers(part, m.spans)) {
        unknown.add(part);
        continue;
      }
      found.addAll(m.matched);
      for (final group in m.ambiguous) {
        for (final p in group) {
          if (!choices.contains(p)) choices.add(p);
        }
      }
    }
    _add(found);
    final search = widget.card.searchPeople;
    var settled = true;
    for (final name in unknown) {
      List<KnownPerson> hits;
      if (search == null) {
        hits = const [];
      } else {
        setState(() => _looking = true);
        try {
          hits = await search(name);
        } on Object {
          if (!mounted) return false;
          setState(() {
            _looking = false;
            _unknown = CommandPlanCard.directoryFailedText;
          });
          settled = false;
          continue;
        }
        if (!mounted) return false;
        setState(() => _looking = false);
      }
      // The write went out while the lookup was out: it adds nobody now.
      if (_busy) return false;
      if (hits.length == 1) {
        _add(hits);
      } else if (hits.isEmpty) {
        setState(() => _unknown = unknownPersonSentence(name));
        settled = false;
      } else {
        for (final p in hits) {
          if (!choices.contains(p)) choices.add(p);
        }
      }
    }
    if (choices.isNotEmpty) {
      setState(() => _candidates = choices);
      settled = false;
    }
    return settled;
  }

  /// The press: a name typed without an Enter is taken first, and the write
  /// goes only when it resolved — never a private event in place of the
  /// invite the owner typed a name for.
  Future<bool> _ready() async {
    final pending = _with.text.trim();
    if (pending.isEmpty) return true;
    return _take(pending);
  }

  /// Whether [spans] cover every letter and digit of [text].
  static bool _covers(String text, List<(int, int)> spans) {
    for (var i = 0; i < text.length; i++) {
      if (!RegExp(r'[A-Za-z0-9]').hasMatch(text[i])) continue;
      if (!spans.any((s) => s.$1 <= i && i < s.$2)) return false;
    }
    return true;
  }

  Widget _fields(bool busy) {
    _busy = busy;
    final card = widget.card;
    final caption = BondType.caption.copyWith(color: BondColors.inkSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: CommandPlanCard.subjectKey,
          controller: _name,
          enabled: !busy,
          autofocus: true,
          maxLines: 1,
          style: BondType.small,
          decoration: const InputDecoration(
            hintText: 'Name this event',
            isDense: true,
          ),
          onChanged: (text) {
            setState(() {});
            card.onSubjectChanged?.call(text);
          },
        ),
        const SizedBox(height: BondSpacing.s8),
        TextField(
          key: CommandPlanCard.withKey,
          controller: _with,
          enabled: !busy,
          maxLines: 1,
          style: BondType.small,
          decoration: const InputDecoration(
            hintText: 'With — a name or address',
            isDense: true,
          ),
          onChanged: (text) {
            if (text.contains(',')) _take(text);
          },
          onSubmitted: _take,
          // Enter takes the name and leaves the keyboard here for the next.
          onEditingComplete: () {},
        ),
        if (_unknown case final unknown?) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(unknown, key: CommandPlanCard.unknownPersonKey, style: caption),
        ],
        if (_candidates.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s4),
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s4,
            children: [
              for (var i = 0; i < _candidates.length; i++)
                OutlinedButton(
                  key: CommandPlanCard.candidateKeyFor(i),
                  onPressed: busy
                      ? null
                      : () {
                          final p = _candidates[i];
                          setState(() => _candidates = const []);
                          _add([p]);
                        },
                  child: Text(_candidates[i].name.isEmpty
                      ? _candidates[i].address
                      : '${_candidates[i].name} · ${_candidates[i].address}'),
                ),
            ],
          ),
        ],
        if (_chips.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s4),
          Wrap(
            spacing: BondSpacing.s4,
            runSpacing: BondSpacing.s4,
            children: [
              for (final p in _chips)
                InputChip(
                  key: CommandPlanCard.chipKeyFor(p.address),
                  label: Text(p.name.isEmpty ? p.address : p.name,
                      style: BondType.caption),
                  tooltip: p.address,
                  visualDensity: VisualDensity.compact,
                  isEnabled: !busy,
                  deleteButtonTooltipMessage: 'Remove ${p.address}',
                  onDeleted: () => _setChips((chips) =>
                      chips.removeWhere((c) => c.address == p.address)),
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return card._proposal(
      widget.proposal,
      fields: _fields,
      summary: writeSummary(_write(),
          shown: const CalendarEvent(id: ''),
          series: false,
          zone: card.zone,
          today: card.today),
      write: _write,
      ready: _ready,
      held: _looking,
    );
  }
}
