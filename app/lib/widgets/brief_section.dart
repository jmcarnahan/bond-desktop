import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../theme/tokens.dart';
import 'time_format.dart';

/// The Brief section of the event panel: what is open with the people in a
/// meeting, written before it starts — or the one sentence that says why
/// there is no brief yet.
///
/// Prop-only. The host reads [view] through `eventBriefProvider` and passes
/// `now`, so a test pins both. Every string in a brief is model output over
/// other people's mail, so it is plain [Text]: nothing in it is a link, and
/// the only things that open anything are the chips: a thread chip opens a
/// thread this app stored, by its key, and a material chip opens a file this
/// app stored, by its ids ([onOpenMaterial]).
///
/// [compact] is the agenda's face, drawn under a meeting row whose glance
/// already shows the headline: a ready brief's body — the catch-up, in the
/// order it is read: Briefing, From the materials, People, Questions, Prep,
/// Open asks, at most [compactPointsCap] References — and one Regenerate,
/// with no heading, headline or footer. In any other state it draws nothing
/// but the one sentence that says the files sent ahead are still being read
/// (the event panel is where the other states say why). The panel draws the
/// headline, the same body in the same order with every point, and the
/// Generated line. The compact briefing is [BondType.body] on purpose,
/// larger than the row's glance above it: the catch-up is read, the glance
/// is scanned.
///
/// The states, in the order they win:
/// 0. declined or cancelled ([eligible] false with that reason) — even over
///    a ready brief, since the owner is not going;
/// 1. a ready brief — shown even while a new one is being written, because
///    the old one is still the best answer until the new one lands;
/// 2. queued, with processing on — "Writing the brief…";
/// 3. processing off — the switch is why nothing is coming;
/// 4. waiting on the files while the quick check says no — its reason;
/// 5. skipped — the rule that kept the meeting out, with Write a brief when
///    that rule was no mail or too far off;
/// 6. failed — with Regenerate;
/// 7. known ineligible ([eligible] false) with nothing stored, in the words
///    of [ineligibleReason] when it has some — with Write a brief when the
///    meeting is too far off;
/// 8. otherwise — a brief comes after the next calendar sync, with Write a
///    brief to have it now.
///
/// Write a brief ([onWrite]) is offered only with processing on, and never
/// for a meeting that has started, was cancelled or declined, has nobody
/// else or too many people: a person's request lifts the horizon and the
/// mail rule, nothing else.
class BriefSection extends StatelessWidget {
  const BriefSection({
    super.key,
    required this.view,
    required this.now,
    required this.onOpenThread,
    required this.onRegenerate,
    this.onWrite,
    this.eligible,
    this.ineligibleReason,
    this.onOpenMaterial,
    this.compact = false,
    this.padding = EdgeInsets.zero,
  });

  static const Key headlineKey = ValueKey('brief-headline');
  static const Key statusKey = ValueKey('brief-status');
  static const Key regenerateKey = ValueKey('brief-regenerate');
  static const Key writeKey = ValueKey('brief-write');
  static Key pointKeyFor(int i) => ValueKey('brief-point-$i');
  static Key askKeyFor(int i) => ValueKey('brief-ask-$i');
  static Key pointThreadKeyFor(int i) => ValueKey('brief-point-thread-$i');
  static Key askThreadKeyFor(int i) => ValueKey('brief-ask-thread-$i');
  static Key materialKeyFor(int i) => ValueKey('brief-material-$i');
  static Key materialTextKeyFor(int i) => ValueKey('brief-material-text-$i');
  static Key materialPointKeyFor(int i, int j) =>
      ValueKey('brief-material-point-$i-$j');
  static Key personKeyFor(int i) => ValueKey('brief-person-$i');
  static const Key briefingKey = ValueKey('brief-briefing');
  static Key questionKeyFor(int i) => ValueKey('brief-question-$i');

  /// How many points the agenda's face shows under References; the panel
  /// shows them all.
  static const int compactPointsCap = 3;

  static const String writingText = 'Writing the brief…';
  static const String rewritingText = 'Rewriting…';
  static const String pausedText =
      'Briefs are paused while processing is off.';
  static const String noMailText =
      'No brief — no recent mail with these people.';
  static const String noOthersText = 'No brief — nobody else is invited.';
  static const String tooManyText = 'No brief — too many people for a brief.';
  static const String tooFarText = 'Briefs are written for today and tomorrow.';
  static const String startedText = 'No brief — this meeting has started.';
  static const String ineligibleText = 'No brief for this meeting.';
  static const String materialsPendingText =
      'Reading the files sent ahead — brief coming.';
  static const String failedText = "The brief couldn't be written.";
  static const String comingText =
      'Brief coming after the next calendar sync.';
  static const String writeLabel = 'Write a brief';

  /// Null while the read is in flight, which draws nothing rather than a
  /// sentence that may be about to be wrong.
  final EventBriefView? view;

  /// Whether the meeting passes the rules that need no store read (the host
  /// asks `briefQuickCheck`): false says so when nothing is stored; null is
  /// not known.
  final bool? eligible;

  /// The wire word of the quick check that said no (`too_far`, `no_others`,
  /// …), for the sentence under [eligible] false; null says it generically.
  final String? ineligibleReason;

  final DateTime now;
  final void Function(String source, String conversationKey) onOpenThread;
  final VoidCallback onRegenerate;

  /// Asks for a brief the rules did not write: too far off, no mail, or none
  /// yet. Null draws no button.
  final VoidCallback? onWrite;

  /// Opens one of the brief's files. Null draws the file names as plain
  /// text.
  final void Function(BriefMaterialRef ref)? onOpenMaterial;

  /// The agenda's face; see the class comment.
  final bool compact;

  /// Around the whole section when it draws anything. The agenda indents the
  /// compact body under its row's subject column; the panel needs none.
  final EdgeInsets padding;

  static final TextStyle _muted =
      BondType.small.copyWith(color: BondColors.inkMuted);

  @override
  Widget build(BuildContext context) {
    final drawn = compact ? _compact() : _panel();
    if (drawn == null) return const SizedBox.shrink();
    return padding == EdgeInsets.zero
        ? drawn
        : Padding(padding: padding, child: drawn);
  }

  /// The agenda's face: a ready brief's body; a brief waiting on its files
  /// says so; else nothing.
  Widget? _compact() {
    final v = view;
    final brief = v?.brief?.brief;
    if (v == null || brief == null || brief.headline.isEmpty) {
      return v?.brief?.skipReason == 'materials_pending'
          ? Text(materialsPendingText,
              key: statusKey,
              style: BondType.caption.copyWith(color: BondColors.inkMuted))
          : null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._body(brief),
        // The panel footer's rule: a rewrite already asked for says so
        // rather than offering a second press.
        Align(
          alignment: Alignment.centerLeft,
          child: v.queued
              ? Padding(
                  padding: const EdgeInsets.only(top: BondSpacing.s4),
                  child: Text(v.processingOn ? rewritingText : pausedText,
                      style: BondType.caption
                          .copyWith(color: BondColors.inkMuted)),
                )
              : _regenerate(),
        ),
      ],
    );
  }

  Widget? _panel() {
    final v = view;
    if (v == null) return null;
    // A meeting the owner declined or that was cancelled is not one they are
    // going to: a brief stored before that stops being offered.
    if (eligible == false && _ends.contains(ineligibleReason)) {
      return _status(reasonText(ineligibleReason));
    }
    final stored = v.brief;
    final brief = stored?.brief;
    if (stored != null && brief != null && brief.headline.isNotEmpty) {
      return _ready(stored, brief, v);
    }
    if (v.queued && v.processingOn) return _status(writingText);
    if (!v.processingOn) return _status(pausedText);
    // A wait for the files ends in a brief only while the quick check still
    // passes: a meeting that has started says so, not "brief coming".
    if (stored?.skipReason == 'materials_pending' && eligible == false) {
      return _status(reasonText(ineligibleReason));
    }
    // Write a brief stands in for the rules a person's request lifts — and
    // only while the quick check is not saying no for a reason it does not
    // lift: a stored no_mail row over a meeting that has since started
    // offers nothing.
    final lifts = eligible != false || ineligibleReason == 'too_far';
    final offer = onWrite != null && v.processingOn && lifts;
    if (stored?.status == EventBrief.skipped) {
      final reason = stored!.skipReason;
      return offer && (reason == 'no_mail' || reason == 'too_far')
          ? _statusWith(reasonText(reason), _write())
          : _status(reasonText(reason));
    }
    if (stored?.status == EventBrief.failed) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(failedText, key: statusKey, style: _muted),
          _regenerate(),
        ],
      );
    }
    if (eligible == false) {
      return offer && ineligibleReason == 'too_far'
          ? _statusWith(reasonText(ineligibleReason), _write())
          : _status(reasonText(ineligibleReason));
    }
    return offer ? _statusWith(comingText, _write()) : _status(comingText);
  }

  /// The sentence for an ineligibility wire word; a word with none of its
  /// own (cancelled, declined, gone, or null) says it generically.
  static String reasonText(String? reason) => switch (reason) {
        'no_mail' => noMailText,
        'no_others' => noOthersText,
        'too_many' => tooManyText,
        'too_far' => tooFarText,
        'past' => startedText,
        'materials_pending' => materialsPendingText,
        _ => ineligibleText,
      };

  /// The quick-check words that outrank even a ready brief.
  static const Set<String> _ends = {'declined', 'cancelled'};

  Widget _status(String text) => Text(text, key: statusKey, style: _muted);

  /// [text] with [button] after it, wrapping under it when the panel is
  /// narrow — the failed state's shape.
  Widget _statusWith(String text, Widget button) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [Text(text, key: statusKey, style: _muted), button],
      );

  Widget _write() => TextButton(
        key: writeKey,
        onPressed: onWrite,
        child: const Text(writeLabel),
      );

  Widget _regenerate() => TextButton(
        key: regenerateKey,
        onPressed: onRegenerate,
        child: const Text('Regenerate'),
      );

  Widget _ready(EventBrief stored, MeetingBrief brief, EventBriefView v) {
    final age = relativeTime(stored.generatedAt, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          brief.headline,
          key: headlineKey,
          style: BondType.body.copyWith(fontWeight: FontWeight.w600),
        ),
        ..._body(brief),
        const SizedBox(height: BondSpacing.s4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              age == null ? 'Generated' : 'Generated $age',
              key: statusKey,
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
            Text(' · ',
                style: BondType.caption.copyWith(color: BondColors.inkMuted)),
            // Offered with processing off too: the request waits in the
            // queue and runs when the switch comes back, like any other.
            if (v.queued)
              Text(v.processingOn ? rewritingText : pausedText,
                  style: BondType.caption.copyWith(color: BondColors.inkMuted))
            else
              _regenerate(),
          ],
        ),
      ],
    );
  }

  /// What both faces draw under the headline, in the order a catch-up is
  /// read: the briefing as one paragraph, what each file sent ahead says,
  /// the people, the questions, the prep, the open asks, then the points
  /// under References — what it rests on last. The compact face shows at
  /// most [compactPointsCap] points; the panel shows them all.
  List<Widget> _body(MeetingBrief brief) {
    final points = compact && brief.points.length > compactPointsCap
        ? compactPointsCap
        : brief.points.length;
    return [
      if (brief.briefing.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('Briefing', style: BondType.label),
        Padding(
          padding: const EdgeInsets.only(top: BondSpacing.s4),
          // A sentence cut at its cap ends mid-thought: an ellipsis keeps
          // it from running into the next.
          child: SelectableText(
              brief.briefing.map(_closed).join(' '),
              key: briefingKey, style: BondType.body),
        ),
      ],
      if (brief.materials.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('From the materials', style: BondType.label),
        for (var i = 0; i < brief.materials.length; i++)
          _material(
              i, brief.materials[i], brief.materialAt(brief.materials[i].file)),
      ],
      if (brief.people.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('People', style: BondType.label),
        for (var i = 0; i < brief.people.length; i++)
          Padding(
            key: personKeyFor(i),
            padding: const EdgeInsets.only(top: BondSpacing.s4),
            // A person with no name is the line alone, never a dangling dash.
            child: Text.rich(
              TextSpan(children: [
                if (brief.people[i].name.trim().isNotEmpty) ...[
                  TextSpan(
                    text: brief.people[i].name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: ' — '),
                ],
                TextSpan(text: brief.people[i].line),
              ]),
              style: BondType.small,
            ),
          ),
      ],
      if (brief.questions.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('Questions', style: BondType.label),
        for (var i = 0; i < brief.questions.length; i++)
          Padding(
            key: questionKeyFor(i),
            padding: const EdgeInsets.only(top: BondSpacing.s4),
            child:
                Text('${i + 1}. ${brief.questions[i]}', style: BondType.small),
          ),
      ],
      if (brief.prep.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('Prep', style: BondType.label),
        for (final p in brief.prep)
          Padding(
            padding: const EdgeInsets.only(top: BondSpacing.s4),
            child: Text('• $p', style: BondType.small),
          ),
      ],
      if (brief.openAsks.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('Open asks', style: BondType.label),
        for (var i = 0; i < brief.openAsks.length; i++)
          _line(
            key: askKeyFor(i),
            text: brief.openAsks[i].person.isEmpty
                ? brief.openAsks[i].ask
                : '${brief.openAsks[i].person}: ${brief.openAsks[i].ask}',
            thread: brief.threadAt(brief.openAsks[i].thread),
            chipKey: askThreadKeyFor(i),
          ),
      ],
      if (points > 0) ...[
        const SizedBox(height: BondSpacing.s8),
        Text('References', style: BondType.label),
        for (var i = 0; i < points; i++)
          _line(
            key: pointKeyFor(i),
            text: '• ${brief.points[i].text}',
            thread: brief.threadAt(brief.points[i].thread),
            chipKey: pointThreadKeyFor(i),
          ),
      ],
    ];
  }

  /// [s] as it reads in the paragraph: ending in its own punctuation, else
  /// in an ellipsis.
  static String _closed(String s) =>
      _closedEnd.hasMatch(s) ? s : '$s…';
  static final RegExp _closedEnd = RegExp(r'''[.!?…]["')”’]*$''');

  /// One material: the file's chip when the brief still holds its ref, then
  /// what the file says, one bullet per point. Points whose ref is missing
  /// (a row from an older build) are drawn alone rather than dropped. The
  /// chip's label is the file name as stored with the brief — the sender's
  /// text, so plain.
  Widget _material(int i, BriefMaterialOut m, BriefMaterialRef? ref) {
    final open = onOpenMaterial;
    final name = ref == null || ref.name.isEmpty ? '(no name)' : ref.name;
    final label = Text(
      name,
      style: BondType.caption.copyWith(
        fontWeight: FontWeight.w600,
        color: open == null ? BondColors.inkSecondary : BondColors.primary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ref != null)
          Padding(
            padding: const EdgeInsets.only(top: BondSpacing.s4),
            child: open == null
                ? label
                : Tooltip(
                    message: 'Open the file',
                    child: InkWell(
                      key: materialKeyFor(i),
                      onTap: () => open(ref),
                      borderRadius: BondRadii.smAll,
                      child: label,
                    ),
                  ),
          ),
        Column(
          key: materialTextKeyFor(i),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < m.points.length; j++)
              Padding(
                key: materialPointKeyFor(i, j),
                padding: const EdgeInsets.only(top: BondSpacing.s4),
                child: Text('• ${m.points[j]}', style: BondType.small),
              ),
          ],
        ),
      ],
    );
  }

  /// One point or ask, with a chip naming its thread when it has one. The
  /// chip's label is the thread's subject as stored with the brief.
  Widget _line({
    required Key key,
    required String text,
    required BriefThreadRef? thread,
    required Key chipKey,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(top: BondSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(text, style: BondType.small)),
          if (thread != null) ...[
            const SizedBox(width: BondSpacing.s8),
            Flexible(
              child: Tooltip(
                message: 'Open the thread',
                child: InkWell(
                  key: chipKey,
                  onTap: () => onOpenThread(thread.source, thread.conversationKey),
                  borderRadius: BondRadii.smAll,
                  child: Text(
                    thread.subject.isEmpty ? '(no subject)' : thread.subject,
                    style: BondType.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: BondColors.primary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
