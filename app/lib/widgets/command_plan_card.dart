import 'package:flutter/material.dart';

import '../models/calendar_models.dart' show CalendarDate, CalendarEvent;
import '../services/calendar/calendar_writes.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/command/command_planner.dart';
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
  });

  static const Key doKey = ValueKey('command-plan-do');
  static const Key subjectKey = ValueKey('command-plan-subject');
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
      child: Container(
        decoration: BoxDecoration(
          color: BondColors.surface,
          borderRadius: BondRadii.mdAll,
          border: Border.all(color: BondColors.border),
        ),
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
  /// [nameField], [summary] and [write] are the blank event's: the field
  /// above the summary, the summary as the name now reads, and the write
  /// under that name at the press.
  Widget _proposal(
    CalendarProposal p, {
    Widget? nameField,
    String? summary,
    CalendarWrite Function()? write,
  }) {
    final named = write;
    final overlaps = p.overlaps;
    final overlap = overlaps == null ? null : overlapLine(overlaps);
    final mayEmail = mayEmailFor(p.write, event: p.targetEvent);
    final emails = emailedLine(p.notifies, mayEmail: mayEmail);
    return CalendarWriteFlow(
      key: ValueKey('command-plan-flow-${identityHashCode(p)}'),
      writer: writer,
      onDone: onDone,
      onFailed: onFailed,
      builder: (context, start, busy) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (nameField != null) ...[
            nameField,
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
                onPressed: busy
                    ? null
                    : () => start(named?.call() ?? p.write,
                        summary: summary ?? p.summary,
                        // A named blank event's toast says the typed name.
                        doneMessage: named == null
                            ? p.doneMessage
                            : writeDoneMessage(named(),
                                shown: null, series: false, zone: zone),
                        mayEmail: mayEmail),
                child: Text(p.notifies.isEmpty ? 'Do it' : 'Send'),
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

/// A create proposal with a name to give it: the blank event picked on the
/// grid. Owns the field's controller; the face is the card's own.
class _NamedProposal extends StatefulWidget {
  const _NamedProposal({required this.card, required this.proposal});

  final CommandPlanCard card;
  final CalendarProposal proposal;

  @override
  State<_NamedProposal> createState() => _NamedProposalState();
}

class _NamedProposalState extends State<_NamedProposal> {
  late final TextEditingController _name = TextEditingController(
      text: (widget.proposal.write as CreateEvent).subject);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The write under the name as it now reads; empty keeps the default.
  CreateEvent _write() {
    final create = widget.proposal.write as CreateEvent;
    final name = _name.text.trim();
    return create.withSubject(name.isEmpty ? 'New event' : name);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return card._proposal(
      widget.proposal,
      nameField: TextField(
        key: CommandPlanCard.subjectKey,
        controller: _name,
        autofocus: true,
        maxLines: 1,
        style: BondType.small,
        decoration: const InputDecoration(
          hintText: 'Name this event',
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      ),
      summary: writeSummary(_write(),
          shown: const CalendarEvent(id: ''),
          series: false,
          zone: card.zone,
          today: card.today),
      write: _write,
    );
  }
}
