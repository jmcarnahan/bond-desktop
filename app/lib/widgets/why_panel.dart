import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../services/deadline_parse.dart' show showableDeadline;
import '../services/decision/needs_you_predicate.dart';
import '../services/decision/stored_decision.dart';
import '../services/decision/decision_policy.dart'
    show DecisionPolicy, learnedGateReasons;
import '../models/extraction_models.dart';
import '../theme/tokens.dart';
import 'home_result.dart' show homeDropLabels;
import 'needs_you_reason.dart'
    show needsYouFromEarlierModel, needsYouPercentWords;
import 'time_format.dart';

/// Why one message got the verdict it did, in plain words.
///
/// The app decides things about mail — this one needs you, that one can wait,
/// this thread scores 1.4 — and until now every one of those decisions was
/// invisible. A reader who disagreed with the rail had nothing to disagree
/// WITH. This panel is the answer beside the message: what the needs-you pass
/// said and why, what triage read, what is being asked, how the thread scores
/// against the reader's own threshold, and what the model pulled out of it.
///
/// Two rules it never breaks.
///
/// It renders SENTENCES, never the stored shapes. No JSON, no enum names
/// dressed as prose, no field names — a panel that answered "why" with
/// `{"intent":"request"}` would be showing its working rather than explaining
/// itself, and `why_panel_test` asserts no brace ever reaches the screen.
///
/// It is read-only, and nothing it shows feeds back anywhere. This reads model
/// OUTPUT that has already been through the untrusted-data fence upstream; it
/// writes nothing, sends nothing and prompts nothing, so there is no second
/// fence to build here. The owner's own Needs You answer is SHOWN here — "you
/// removed it", and the sentence saying whether it was this message or one
/// like it — but it is taken on the thread's action bar, never in this panel.
class WhyPanelBody extends StatelessWidget {
  /// The message being explained. Null — synced away, wiped — says so and
  /// draws nothing else: an explanation of a message nobody has is a page of
  /// "not judged yet" that means nothing.
  final Message? message;

  /// The thread the message sits in, where it is still in the list. Null
  /// costs the attention block its score, not the panel.
  final Conversation? conversation;

  final ExtractionResult? extraction;

  /// The thread's raw `conversation_ai` row — bucket, reason, date. Raw
  /// because three columns is not a model.
  final Map<String, Object?>? ai;

  /// The decision model's stored answers, or null when it never read this
  /// message. One line under the verdict when present.
  final StoredDecision? decision;

  /// The reader's own needs-you threshold, so the message's probability is
  /// judged against the line they actually set rather than against a default.
  final double threshold;

  final DateTime now;

  /// The door to the full history of this thread — the deep dive with the
  /// levers on it. Null draws nothing at all: this panel is the quick read
  /// beside a message, and a dead link to a screen this build does not have
  /// would be worse than no link.
  final VoidCallback? onWhatHappened;

  const WhyPanelBody({
    super.key,
    required this.message,
    required this.conversation,
    required this.extraction,
    required this.ai,
    required this.threshold,
    required this.now,
    this.onWhatHappened,
    this.decision,
  });

  static const Key verdictKey = ValueKey('why-verdict');
  static const Key triageKey = ValueKey('why-triage');
  static const Key asksKey = ValueKey('why-asks');
  static const Key attentionKey = ValueKey('why-attention');
  static const Key extractionKey = ValueKey('why-extraction');
  static const Key whatHappenedKey = ValueKey('why-what-happened');

  /// The one status that means triage actually ran. Everything else —
  /// `pending`, `processing`, `skipped`, `error` — is a message whose labels
  /// below would be empty or stale, and the panel says so rather than
  /// rendering blanks.
  static const String _triaged = 'triaged';

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m == null) {
      return Padding(
        padding: const EdgeInsets.all(BondSpacing.s16),
        child: Text(
          'This message is no longer stored.',
          style: BondType.small,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s12,
        BondSpacing.s16,
        BondSpacing.s24,
      ),
      children: [
        _block(verdictKey, 'VERDICT', _verdictLines(m), headline: _headline(m)),
        _block(triageKey, 'TRIAGE', _triageLines(m)),
        _block(asksKey, 'ASKS', _askLines(m)),
        _block(attentionKey, 'ATTENTION', _attentionLines()),
        _block(extractionKey, 'WHAT IT IS ABOUT', _extractionLines()),
        if (onWhatHappened != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: whatHappenedKey,
              onPressed: onWhatHappened,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: BondSpacing.s8,
                ),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('What happened ›'),
            ),
          ),
      ],
    );
  }

  /// One labelled section. A caption and lines rather than a `SettingsSection`:
  /// these are answers to be read, not controls to be opened, and every one of
  /// them starts expanded because folding an explanation defeats it.
  Widget _block(
    Key key,
    String label,
    List<String> lines, {
    String? headline,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: BondSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: BondType.label),
          const SizedBox(height: BondSpacing.s4),
          if (headline != null) ...[
            Text(
              headline,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
          ],
          for (final line in lines) ...[
            Text(line, style: BondType.small),
            const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }

  /// The message's needs-you probability as the percentage the Settings
  /// slider is set in, so the two read as one number: `Needs you: 72%`. A
  /// dash when the decision model has not read it: an undecided message is
  /// not a low one, and the panel never shows it as 0%.
  ///
  /// An earlier model's carried verdict (a 1.0 or 0.0 with no [decision]
  /// under this build's questions, `needsYouFromEarlierModel`) reads
  /// `Needs you: — (earlier model)`: it still counts against the slider, but
  /// no model said that number.
  ///
  /// The owner's own answer ([StoredDecision.ownerAnswer]) reads as theirs,
  /// with no percentage: `Needs you: no — you removed it`. The 0.0 or 1.0
  /// under it is the owner's word, not a model's confidence.
  String _headline(Message m) {
    switch (decision?.ownerAnswer) {
      case 'no':
        return 'Needs you: no — you removed it';
      case 'yes':
        return 'Needs you: yes — you added it';
    }
    final decidedNow = decision != null;
    if (m.needsYouP != null &&
        needsYouFromEarlierModel(m.needsYouP, decidedNow: decidedNow)) {
      return 'Needs you: — (earlier model)';
    }
    final percent = needsYouPercentWords(m.needsYouP, decidedNow: decidedNow);
    return 'Needs you: ${percent ?? '—'}';
  }

  List<String> _verdictLines(Message m) {
    final lines = <String>[];
    final reason = m.needsYouReason?.trim() ?? '';
    if (m.needsYouP == null) {
      lines.add('The needs-you pass has not reached this message.');
    } else {
      // The answer the rail acts on, against the reader's own line. The
      // reason is templated from the decision whatever its probability, so it
      // is shown only where it is an answer: under the line it would say
      // "asks you a question" about a message the reader was told needs
      // nothing (`home_result.dart` keeps the same rule).
      //
      // The owner's answer is the exception: its sentence says what the
      // owner did ("You removed a message like this from Needs You."), which
      // is the answer on either side of the line.
      final line = needsYouPercentWords(threshold);
      final owners = decision?.ownerAnswer != null;
      if (owners && reason.isNotEmpty) lines.add(_reasonSentence(reason));
      if (needsYouAt(m.needsYouP, threshold)) {
        if (!owners && reason.isNotEmpty) lines.add(_reasonSentence(reason));
        lines.add('In Needs You: at or above your $line line.');
      } else {
        lines.add('Not in Needs You: below your $line line.');
      }
    }
    final gate = m.gateReason?.trim() ?? '';
    if (gate.isNotEmpty) {
      lines.add('Skipped by the gate: '
          '${homeDropLabels[gate]?.toLowerCase() ?? _words(gate)}.');
    }
    // Dropped means the LEARNED gate took it: one of its words AND a stored
    // p(drop) over its bar. Any other gate word (an owner's Ignore is `user`)
    // is not the model's verdict, so its line reads what the model said.
    final learnedDrop = learnedGateReasons.contains(gate) &&
        (decision?.gateP ?? 0) >= DecisionPolicy.gateDrop;
    final line = decisionLine(decision, dropped: learnedDrop);
    if (line != null) lines.add(line);
    return lines;
  }

  /// The decision model's numbers in one line: `Decision model: gate keep
  /// 0.94, needs you 0.71, action 0.66, reply 0.12 · 58 ms`, fixed to two
  /// places. Null when the model never read the message.
  ///
  /// The gate is worded by the VERDICT ([dropped]: the LEARNED gate took the
  /// message), not by the head's argmax: a dropped message reads `gate drop
  /// 0.91`; every other one reads `gate keep 0.94`, or `gate keep (drop
  /// 0.60)` when the head leaned drop but under the bar, from a cold
  /// approach, or on a message the owner restored. A message another gate
  /// took (an owner's Ignore) is not dropped here: it reads as the model saw
  /// it. The other three are each field's probability of yes.
  static String? decisionLine(StoredDecision? d, {required bool dropped}) {
    if (d == null) return null;
    String p2(double? p) => p == null ? '–' : p.toStringAsFixed(2);
    final drop = d.gateP;
    final String gate;
    if (drop == null) {
      gate = dropped ? 'gate drop' : 'gate keep';
    } else if (dropped) {
      gate = 'gate drop ${p2(drop)}';
    } else if (drop >= 0.5) {
      gate = 'gate keep (drop ${p2(drop)})';
    } else {
      gate = 'gate keep ${p2(1 - drop)}';
    }
    final ms = d.latencyMs == null ? '' : ' · ${d.latencyMs!.round()} ms';
    return 'Decision model: $gate, needs you ${p2(d.needsYouP)}, '
        'action ${p2(d.needsActionP)}, reply ${p2(d.replyExpectedP)}$ms';
  }

  /// The one reason the pass writes as a token rather than as a sentence. Every
  /// other value is the model's own evidence line, which is already a sentence
  /// and is shown as it was written.
  String _reasonSentence(String reason) => reason == 'teams_direct'
      ? 'A direct message to you on Teams.'
      : reason;

  /// A stored token as words: `teams_source` reads "teams source",
  /// `bulk_sender` reads "bulk sender". The gate, triage and extraction all
  /// write snake_case enums, and an enum name on screen is the one thing this
  /// panel promised never to show.
  static String _words(String token) => token.trim().replaceAll('_', ' ');

  List<String> _triageLines(Message m) {
    if (m.triageStatus != _triaged) return ['Triage has not run yet.'];
    final lines = <String>[];
    final summary = m.summary?.trim() ?? '';
    if (summary.isNotEmpty) lines.add(summary);
    final parts = <String>[
      if ((m.urgency?.trim() ?? '').isNotEmpty)
        'Urgency ${_words(m.urgency!)}',
      if ((m.category?.trim() ?? '').isNotEmpty)
        'Category ${_words(m.category!)}',
      if ((m.label?.trim() ?? '').isNotEmpty) 'Label ${_words(m.label!)}',
    ];
    if (parts.isNotEmpty) lines.add(parts.join(' · '));
    if (lines.isEmpty) lines.add('Triage read nothing worth labelling.');
    return lines;
  }

  List<String> _askLines(Message m) {
    final lines = <String>[];
    switch (m.needsAction) {
      case true:
        lines.add('Asks for action.');
      case false:
        lines.add('No action asked.');
      case null:
        break;
    }
    switch (m.replyExpected) {
      case true:
        lines.add('A reply is expected.');
      case false:
        lines.add('No reply expected.');
      case null:
        lines.add('Not judged whether a reply is expected.');
    }
    // Same filter the chip wears: plan-relative wording ("Day 1") is not a
    // deadline, and this panel explaining the verdict must not present it as
    // one either.
    final deadline = showableDeadline(m.deadline, now: DateTime.now());
    if (deadline != null) lines.add('Deadline: $deadline');
    lines.add(m.addressedMe
        ? 'Addressed to you directly.'
        : 'Not addressed to you alone.');
    for (final item in m.actionItems) {
      final text = item.trim();
      if (text.isNotEmpty) lines.add('• $text');
    }
    return lines;
  }

  List<String> _attentionLines() {
    final lines = <String>[];
    final score = conversation?.attentionScore;
    if (score == null) {
      lines.add('Not scored yet.');
    } else {
      // The score orders Needs You and gates nothing, so it is reported on
      // its own rather than against the slider, which cuts the needs-you
      // probability.
      lines.add('Attention ${score.toStringAsFixed(1)}.');
    }

    final row = ai;
    final bucket = row?['bucket'] as String?;
    final reason = row?['bucket_reason'] as String?;
    if (bucket == 'later') {
      lines.add('In Later — ${_becauseOf(reason)}.');
    } else if (bucket == null && reason == 'user') {
      // The same pair of columns is written by Keep in inbox AND by a Later
      // date coming due, and nothing on the row says which. One sentence that
      // is true either way, rather than a confident one that is wrong half
      // the time.
      lines.add('In your inbox on your say-so — kept here, or back from Later '
          'on its date.');
    }

    final until = untilLabel(row?['snoozed_until'] as String?, now);
    if (until != null) lines.add('Back $until.');
    return lines;
  }

  /// Who filed the thread, in words. The stored words are `user`,
  /// `sender_pref` and `low_value`, and none of the three is something to show
  /// a reader.
  String _becauseOf(String? reason) => switch (reason) {
        'user' => 'you sent it there',
        'sender_pref' => 'a rule about the sender',
        'low_value' => 'the model judged it low value',
        _ => 'filed by the app',
      };

  List<String> _extractionLines() {
    final e = extraction;
    if (e == null) return ['Not yet extracted.'];
    final lines = <String>[];
    final evidence = e.evidence.trim();
    if (evidence.isNotEmpty) lines.add(evidence);
    lines.add('Intent ${_words(e.intent)} · Importance ${_words(e.importance)}');
    void list(String label, List<String> values) {
      final kept = [
        for (final v in values)
          if (v.trim().isNotEmpty) v.trim(),
      ];
      if (kept.isNotEmpty) lines.add('$label: ${kept.join(', ')}');
    }

    list('Topics', e.topics);
    list('People', e.people);
    list('Organizations', e.organizations);
    final project = e.project.trim();
    if (project.isNotEmpty) lines.add('Project: $project');
    return lines;
  }
}
