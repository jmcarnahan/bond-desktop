import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show AsyncValue, AsyncValueX;

import '../models/home_models.dart';
import '../models/message_history.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/home_result.dart';
import '../widgets/inline_alert.dart';
import '../widgets/pane_surface.dart';
import '../widgets/source_glyph.dart';
import '../widgets/stage_bar.dart';
import '../widgets/time_format.dart';

/// What happened to ONE message, and every lever that can change it.
///
/// The screen a person opens when the app has done something they did not
/// expect — a mail that never appeared, a thread filed somewhere odd, a row
/// stuck on a stage — so the whole of it is the answer to "why", in the order
/// the question gets asked: what this is, what the app decided, how far it
/// got, what it judged, where it filed the thread, what is still queued, and
/// what the log wrote about any of it. The levers come LAST, because a button
/// pressed before the reason has been read is a guess.
///
/// Dumb by construction, like [HomePane]: every value and every callback is a
/// prop and nothing is read from a provider, so the whole screen can be pumped
/// against a [MessageHistory] built from plain maps with no database around
/// it. The one thing it owns is which two-step confirmation is armed, which is
/// view state in exactly the way a scroll position is.
///
/// A null callback means the host cannot do that thing, and the button is not
/// drawn — never drawn dead. The conditions beside them are this screen's own
/// judgement about when an action would be a lie: Retry on a dropped row would
/// re-run a pipeline that is going to refuse the message again, and Restore on
/// a kept one would restore nothing.
class MessageHistoryScreen extends StatefulWidget {
  /// The story, as the provider has it: loading before the first read lands,
  /// an error only when no read has ever succeeded.
  final AsyncValue<MessageHistory> history;

  /// The clock, injected so a test pins what "3h ago" means — the same reason
  /// every row in this app takes one.
  final DateTime now;

  final VoidCallback onBack;
  final VoidCallback onHome;

  /// Opens the thread this message sits in. Takes the pair the rest of the app
  /// keys a thread by, because the message id is not one of them.
  final void Function(String source, String conversationKey) onOpenThread;

  /// Opens one of the storylines named on this screen — the filing in the
  /// outcome sentence, a membership, or a block.
  final void Function(String storylineId) onOpenStoryline;

  /// Pulls a gate-dropped message back through the pipeline. Null, or a row
  /// that was never dropped, draws nothing: there is nothing to restore from.
  final VoidCallback? onRestore;

  /// Puts the stages this row still owes back on their queues. Only offered
  /// when [resultLine] says the row is retryable — a stall or a failure — for
  /// the home feed's reason: a Retry on anything else is a button that does
  /// nothing.
  final VoidCallback? onRetry;

  /// Asks the needs-you stage its question again. Kept rows only: a gated row
  /// is never judged, so the offer would be a slot spent on a refusal.
  final VoidCallback? onRejudge;

  /// Drops this message by hand — the owner's own gate. Two-step in place,
  /// because it takes a message off the feed and the second tap is the whole
  /// confirmation the house pattern allows.
  final VoidCallback? onIgnore;

  /// Opens the pane that picks which storyline this thread joins. A pane and
  /// not a menu, so it comes back to this screen when it is done.
  final VoidCallback? onAddToStoryline;

  /// Takes the thread out of one storyline. Per membership, and two-step for
  /// [onIgnore]'s reason — it is the same removal the storyline's About block
  /// offers, and it teaches the model.
  final void Function(String storylineId)? onRemoveFromStoryline;

  /// Lifts the owner's own veto without filing the thread back — the model is
  /// simply allowed to decide about it again. Only ever offered on a block the
  /// OWNER wrote: the re-check pass's blocks are the pipeline's own working
  /// and there is no lesson in them to un-teach.
  final void Function(String storylineId)? onAllowAgain;

  /// Files the thread back by hand, which clears the block of either kind on
  /// the way in.
  final void Function(String storylineId)? onAddBack;

  /// Brings a deferred thread back into the working inbox. Shown only when the
  /// thread is actually in Later — an undo for something that never happened
  /// reads as broken.
  final VoidCallback? onKeepInInbox;

  /// Defers the thread. The other half of [onKeepInInbox], and never shown
  /// beside it.
  final VoidCallback? onSendToLater;

  /// Opens Settings, where the Needs You rules are edited. There is no deep
  /// link to the section — opening Settings IS the navigation — so this is a
  /// door rather than a jump.
  final VoidCallback? onEditRules;

  const MessageHistoryScreen({
    super.key,
    required this.history,
    required this.now,
    required this.onBack,
    required this.onHome,
    required this.onOpenThread,
    required this.onOpenStoryline,
    this.onRestore,
    this.onRetry,
    this.onRejudge,
    this.onIgnore,
    this.onAddToStoryline,
    this.onRemoveFromStoryline,
    this.onAllowAgain,
    this.onAddBack,
    this.onKeepInInbox,
    this.onSendToLater,
    this.onEditRules,
  });

  static const ValueKey<String> openThreadKey =
      ValueKey('history-open-thread');
  static const ValueKey<String> restoreKey = ValueKey('history-restore');
  static const ValueKey<String> retryKey = ValueKey('history-retry');
  static const ValueKey<String> rejudgeKey = ValueKey('history-rejudge');
  static const ValueKey<String> ignoreKey = ValueKey('history-ignore');
  static const ValueKey<String> addToStorylineKey =
      ValueKey('history-add-to-storyline');
  static const ValueKey<String> keepKey = ValueKey('history-keep');
  static const ValueKey<String> laterKey = ValueKey('history-later');
  static const ValueKey<String> editRulesKey = ValueKey('history-edit-rules');

  /// The per-storyline buttons, keyed by the storyline they act on: one
  /// message's thread can sit in several storylines and be blocked from
  /// several more, so a bare key would name four buttons at once.
  static ValueKey<String> removeKey(String storylineId) =>
      ValueKey('history-remove-$storylineId');

  static ValueKey<String> allowAgainKey(String storylineId) =>
      ValueKey('history-allow-again-$storylineId');

  static ValueKey<String> addBackKey(String storylineId) =>
      ValueKey('history-add-back-$storylineId');

  /// The link INTO a storyline from its membership entry.
  static ValueKey<String> charterKey(String storylineId) =>
      ValueKey('history-charter-$storylineId');

  @override
  State<MessageHistoryScreen> createState() => _MessageHistoryScreenState();
}

class _MessageHistoryScreenState extends State<MessageHistoryScreen> {
  /// Whether Ignore has been pressed once and is waiting for the second tap.
  bool _confirmingIgnore = false;

  /// Which membership's Remove is armed, or null. One at a time on purpose:
  /// arming a second question while the first is open is how a person answers
  /// the wrong one.
  String? _confirmingRemoveId;

  @override
  Widget build(BuildContext context) {
    return PaneSurface(
      title: 'What happened',
      onBack: widget.onBack,
      onHome: widget.onHome,
      child: _body(),
    );
  }

  /// Once loaded, never blank — the provider's rule, honoured here: a value in
  /// hand outranks a loading flag, so a re-read behind a lever the reader just
  /// pressed does not replace the story with a spinner.
  Widget _body() {
    final history = widget.history;
    if (history.hasValue) return _story(history.requireValue);
    if (history.hasError) {
      return const Padding(
        padding: EdgeInsets.all(BondSpacing.s24),
        child: Align(
          alignment: Alignment.topCenter,
          child: InlineAlert(
            severity: InlineAlertSeverity.error,
            text: "Couldn't read this message's history.",
          ),
        ),
      );
    }
    return Center(child: Text('Reading…', style: BondType.small));
  }

  /// The whole story, top to bottom. A [ListView] rather than a column in a
  /// scroller: the activity list is unbounded, and a message that has been
  /// round the pipeline three times has more of it than a window is tall.
  Widget _story(MessageHistory history) {
    if (!history.exists) {
      return ListView(
        padding: const EdgeInsets.all(BondSpacing.s24),
        children: [
          Text(
            'This message is no longer in the store.',
            style: BondType.body,
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(BondSpacing.s24),
      children: [
        ..._header(history),
        ..._outcome(history),
        ..._stages(history),
        ..._judgements(history),
        ..._storylines(history),
        ..._work(history),
        ..._activity(history),
        ..._actions(history),
      ],
    );
  }

  /// A caption heading and whatever sits under it, in the About block's
  /// spelling: caps at caption size, so the sections read as one rail of
  /// answers rather than as eight little cards.
  List<Widget> _section(String heading, List<Widget> children) => [
        const SizedBox(height: BondSpacing.s16),
        Text(heading.toUpperCase(), style: BondType.label),
        const SizedBox(height: BondSpacing.s4),
        ...children,
      ];

  /// Who sent it, when it arrived, and the way into the thread it belongs to.
  List<Widget> _header(MessageHistory history) {
    final subject = history.subject?.trim() ?? '';
    final from = history.fromName?.trim().isNotEmpty == true
        ? history.fromName!.trim()
        : (history.fromAddress?.trim() ?? '');
    final received = relativeTime(history.receivedAt, widget.now);
    return [
      Text(
        subject.isEmpty ? '(no subject)' : subject,
        style: BondType.titleSm,
      ),
      const SizedBox(height: BondSpacing.s4),
      if (from.isNotEmpty) Text('From $from', style: BondType.small),
      Text(
        '${sourceChipPrefix(history.source)}· '
        'received ${received ?? 'at an unknown time'}',
        style: BondType.caption,
      ),
      const SizedBox(height: BondSpacing.s8),
      Align(
        alignment: Alignment.centerLeft,
        child: _link(
          'Open thread',
          key: MessageHistoryScreen.openThreadKey,
          onTap: () => widget.onOpenThread(
            history.source,
            history.conversationKey,
          ),
        ),
      ),
    ];
  }

  /// The feed's own sentence about this row, in full.
  ///
  /// [resultLine]'s tooltip rather than its text: the cell on the home screen
  /// ellipsises at two flexible columns, and the whole reason somebody is here
  /// is the half that got cut.
  List<Widget> _outcome(MessageHistory history) {
    final row = history.row;
    if (row == null) {
      return _section('Outcome', [
        Text('No pipeline record for this message yet.', style: BondType.small),
      ]);
    }

    final result = resultLine(row, now: widget.now);
    final style =
        BondType.small.copyWith(color: bondToneColors[result.tone]!.foreground);
    final storylineId = row.storylineId;
    final title = row.storylineTitle;

    if (result.kind == HomeResultKind.filed &&
        storylineId != null &&
        (title?.isNotEmpty ?? false)) {
      final evidence = homeFiledEvidence(row);
      return _section('Outcome', [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Filed in ', style: style),
            _link(title!, onTap: () => widget.onOpenStoryline(storylineId)),
            if (evidence != null) Text(' — $evidence', style: style),
          ],
        ),
      ]);
    }

    return _section('Outcome', [
      Text(result.text, style: style),
      // The feed's tooltip under the feed's sentence, whenever it says
      // something more. On the table the sentence is ellipsised into two
      // flexible columns and the explanation is a hover away; here there is
      // room for both, and the explanation is the half somebody came for.
      if (result.tooltip != result.text)
        Text(
          result.tooltip,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
    ]);
  }

  /// The five stages, each with what it did, when, and what that means.
  ///
  /// The words come from [HomeStageBar.tooltipFor] rather than from a second
  /// vocabulary written here: the bar on the home row and this rail are two
  /// renderings of the same five columns, and two sets of words for them is
  /// how a screen comes to disagree with the tooltip that sent somebody to it.
  List<Widget> _stages(MessageHistory history) {
    final row = history.row;
    return _section('Stages', [
      for (final stage in history.stages)
        Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${stage.name}: ${stage.state}'
                '${_stageWhen(stage.at)}',
                style: BondType.small,
              ),
              if (_stageNote(stage, row) != stage.state)
                Text(
                  _stageNote(stage, row),
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
            ],
          ),
        ),
    ]);
  }

  String _stageWhen(String? at) {
    final when = relativeTime(at, widget.now);
    return when == null ? '' : ' · $when';
  }

  /// The line under a stage, or the state again when there is nothing to add.
  ///
  /// A gated row's skipped stages are the one case the bar cannot explain on
  /// its own: "skipped" is an end state there rather than a decision about the
  /// stage, and the reason lives on the drop.
  String _stageNote(StageRecord stage, HomeFeedRow? row) {
    if (stage.state == 'skipped' && (row?.dropped ?? false)) {
      return 'gated: ${homeDropLabel(row!.dropReason)}';
    }
    final tip = HomeStageBar.tooltipFor(
      stage.name,
      stage.state,
      workOpen: row?.workOpen ?? false,
    );
    // The bar says '<stage>: <words>'; this line already carries the stage.
    return tip.substring(stage.name.length + 2);
  }

  /// Every judgement the app made about this message, with the reason it wrote
  /// down at the time. The score is shown against the threshold it was
  /// measured against, because neither number means anything alone.
  List<Widget> _judgements(MessageHistory history) {
    final lines = <String>[];

    final verdict = switch (history.needsYouVerdict) {
      null => 'not judged',
      true => 'yes',
      false => 'no',
    };
    final why = history.needsYouReason?.trim() ?? '';
    lines.add('Needs you: $verdict${why.isEmpty ? '' : ' — $why'}');

    final score = history.attentionScore;
    lines.add(
      'Attention: ${history.bucket ?? 'inbox'} — '
      '${history.bucketReason ?? 'no rule'}; '
      'score ${score == null ? '—' : score.toStringAsFixed(2)} '
      'vs threshold ${history.threshold.toStringAsFixed(2)}',
    );

    final triage = [
      if (history.urgency?.isNotEmpty ?? false) history.urgency!,
      if (history.category?.isNotEmpty ?? false) history.category!,
    ].join(' · ');
    final summary = history.summary?.trim() ?? '';
    if (triage.isNotEmpty || summary.isNotEmpty) {
      lines.add(
        'Triage: '
        '${[
          if (triage.isNotEmpty) triage,
          if (summary.isNotEmpty) summary,
        ].join(' — ')}',
      );
    }

    final gate = history.gateReason?.trim() ?? '';
    if (gate.isNotEmpty) {
      lines.add(
        'Gate: $gate'
        '${history.gateOverride == 'user' ? ' (restored by you)' : ''}',
      );
    }

    final error = history.triageError?.trim() ?? '';
    lines.add(
      'Triage status: ${history.triageStatus}'
      '${error.isEmpty ? '' : ' — $error'}',
    );

    return _section('Judgements', [
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(line, style: BondType.small),
        ),
    ]);
  }

  /// Where the thread was filed, and where it was kept out of.
  ///
  /// Both lists on one screen because they answer the same question from
  /// opposite sides, and the four buttons here route through the same
  /// `StorylinesNotifier` methods the storyline's own About block uses — two
  /// doors onto one decision, never two decisions.
  List<Widget> _storylines(MessageHistory history) {
    if (history.memberships.isEmpty && history.blocks.isEmpty) {
      return _section('Storylines', [
        Text('Not in any storyline.', style: BondType.small),
      ]);
    }

    return _section('Storylines', [
      for (final membership in history.memberships)
        _membershipEntry(membership),
      for (final block in history.blocks) _blockEntry(block),
    ]);
  }

  Widget _membershipEntry(ThreadMembership membership) {
    final title = membership.title?.trim() ?? '';
    final evidence = membership.evidence?.trim() ?? '';
    final status = membership.status ?? '';
    // The storyline's own status, through the read's LEFT JOIN. Live is the
    // pair a storyline is answerable in; anything else — dismissed, or gone
    // altogether — is history and offers no Remove.
    final live = status == 'active' || status == 'suggested';
    final remove = widget.onRemoveFromStoryline;
    final confirming = _confirmingRemoveId == membership.storylineId;

    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${title.isEmpty ? '(a storyline that no longer exists)' : title}'
            ' — ${evidence.isEmpty ? 'no evidence recorded' : evidence}'
            '${membership.addedByUser ? ' · filed by you' : ''}'
            '${live || status.isEmpty ? '' : ' · $status'}',
            style: BondType.small,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _quietButton(
                'Open storyline',
                key: MessageHistoryScreen.charterKey(membership.storylineId),
                onPressed: () =>
                    widget.onOpenStoryline(membership.storylineId),
              ),
              if (remove != null && live) ...[
                const SizedBox(width: BondSpacing.s4),
                _quietButton(
                  confirming ? 'Really remove?' : 'Remove',
                  key: MessageHistoryScreen.removeKey(membership.storylineId),
                  onPressed: () {
                    if (!confirming) {
                      setState(
                        () => _confirmingRemoveId = membership.storylineId,
                      );
                      return;
                    }
                    setState(() => _confirmingRemoveId = null);
                    remove(membership.storylineId);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _blockEntry(ThreadBlock block) {
    final title = block.title?.trim() ?? '';
    final evidence = block.evidence?.trim() ?? '';
    final allowAgain = widget.onAllowAgain;
    final addBack = widget.onAddBack;

    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Removed ${block.blockedByUser ? 'by you' : 'by re-check'} from '
            '${title.isEmpty ? '(a storyline that no longer exists)' : title}'
            '${evidence.isEmpty ? '' : ' — $evidence'}',
            style: BondType.small,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (allowAgain != null && block.blockedByUser)
                _quietButton(
                  'Allow again',
                  key: MessageHistoryScreen.allowAgainKey(block.storylineId),
                  onPressed: () => allowAgain(block.storylineId),
                ),
              if (addBack != null) ...[
                const SizedBox(width: BondSpacing.s4),
                _quietButton(
                  'Add back',
                  key: MessageHistoryScreen.addBackKey(block.storylineId),
                  onPressed: () => addBack(block.storylineId),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// What is still on a queue for this message, and what the last attempt at
  /// it said. The entity id rides along in [WorkRecord] rather than being
  /// implied, so a row keyed by the thread reads as one.
  List<Widget> _work(MessageHistory history) {
    if (history.work.isEmpty) {
      return _section('Work', [
        Text('Nothing queued.', style: BondType.small),
      ]);
    }
    return _section('Work', [
      for (final item in history.work)
        Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${item.kind} · ${item.status} · attempt ${item.attempts}',
                style: BondType.small,
              ),
              if (item.error?.isNotEmpty ?? false)
                Text(
                  item.error!,
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
            ],
          ),
        ),
    ]);
  }

  /// Every line the log wrote about this message or its thread, newest first
  /// as the read delivers them — and described by the log panel's own
  /// sentences, so the two never say different things about one row.
  List<Widget> _activity(MessageHistory history) {
    if (history.events.isEmpty) {
      return _section('Activity', [
        Text('No activity recorded for this message.', style: BondType.small),
      ]);
    }
    return _section('Activity', [
      for (final event in history.events)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '${ActivityLogPanel.describe(event)}'
            '${_stageWhen(event.createdAt)}',
            style: BondType.small,
          ),
        ),
    ]);
  }

  /// The levers, last and together.
  ///
  /// Only the ones whose host wired them up AND whose condition holds: a
  /// dropped row is Restore's and a kept one is Ignore's, and offering both at
  /// once would be the screen asking a question it already knows the answer
  /// to.
  List<Widget> _actions(MessageHistory history) {
    final row = history.row;
    final dropped = row?.dropped ?? false;
    final retryable = row != null && resultLine(row, now: widget.now).retryable;

    final restore = widget.onRestore;
    final retry = widget.onRetry;
    final rejudge = widget.onRejudge;
    final ignore = widget.onIgnore;
    final addToStoryline = widget.onAddToStoryline;
    final keep = widget.onKeepInInbox;
    final later = widget.onSendToLater;
    final editRules = widget.onEditRules;

    final buttons = <Widget>[
      if (restore != null && dropped)
        _quietButton(
          'Restore',
          key: MessageHistoryScreen.restoreKey,
          onPressed: restore,
        ),
      if (retry != null && retryable)
        _quietButton(
          'Retry owed stages',
          key: MessageHistoryScreen.retryKey,
          onPressed: retry,
        ),
      if (rejudge != null && !dropped)
        _quietButton(
          'Re-judge Needs You',
          key: MessageHistoryScreen.rejudgeKey,
          onPressed: rejudge,
        ),
      if (ignore != null && !dropped)
        _quietButton(
          _confirmingIgnore ? 'Really ignore?' : 'Ignore this message',
          key: MessageHistoryScreen.ignoreKey,
          onPressed: () {
            if (!_confirmingIgnore) {
              setState(() => _confirmingIgnore = true);
              return;
            }
            setState(() => _confirmingIgnore = false);
            ignore();
          },
        ),
      if (addToStoryline != null && !dropped)
        _quietButton(
          'Add to storyline…',
          key: MessageHistoryScreen.addToStorylineKey,
          onPressed: addToStoryline,
        ),
      if (keep != null && history.bucket == 'later')
        _quietButton(
          'Keep in inbox',
          key: MessageHistoryScreen.keepKey,
          onPressed: keep,
        ),
      if (later != null && history.bucket != 'later')
        _quietButton(
          'Send to Later',
          key: MessageHistoryScreen.laterKey,
          onPressed: later,
        ),
      if (editRules != null)
        _quietButton(
          'Edit Needs You rules',
          key: MessageHistoryScreen.editRulesKey,
          onPressed: editRules,
        ),
    ];

    if (buttons.isEmpty) return const [];

    return _section('Actions', [
      Wrap(
        spacing: BondSpacing.s4,
        runSpacing: BondSpacing.s4,
        children: buttons,
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Everything here can be undone — from this screen or the storyline.',
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      ),
    ]);
  }

  /// A link inside a sentence, in the feed row's spelling: its own transparent
  /// Material, because ink paints on the nearest Material ANCESTOR and the
  /// pane's surface is an opaque one.
  Widget _link(String text, {required VoidCallback onTap, Key? key}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: Text(
          text,
          style: BondType.small.copyWith(
            fontWeight: FontWeight.w600,
            color: BondColors.primary,
          ),
        ),
      ),
    );
  }

  /// The storyline panel's quiet button, spelled the same way: a row of these
  /// is a row of choices rather than a row of raised claims.
  Widget _quietButton(
    String label, {
    required VoidCallback onPressed,
    Key? key,
  }) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: BondType.caption.copyWith(
          color: BondColors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
