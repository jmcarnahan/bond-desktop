import 'package:flutter/material.dart';

import '../models/calendar_models.dart' show WritePreview;
import '../services/calendar/calendar_writes.dart';
import '../services/calendar/write_rules.dart';
import '../theme/tokens.dart';
import 'write_confirm_strip.dart';

/// Starts one calendar write: [summary] is the confirm line, [doneMessage]
/// the toast once it went through.
typedef WriteStarter = void Function(
  CalendarWrite write, {
  required String summary,
  required String doneMessage,
});

/// The one state machine every place a calendar write starts shares: the
/// event panel, the meeting card, an invite row.
///
/// A press runs the dry run first. A write that emails nobody and destroys
/// nothing goes straight on and offers an Undo; anything else waits on the
/// inline [WriteConfirmStrip] drawn under the buttons (D5). A failure stays
/// here, under the buttons that caused it, in one sentence, with Try again
/// when trying again can help — never a toast, which would say "failed"
/// somewhere the person is not looking and then go away.
///
/// The widget disposed mid-write (the panel closed, the row answered and
/// gone) still hands a success to [onDone], whose toast belongs to the
/// screen; a failure it drops — the error line had nowhere left to stand,
/// and the revision bump brings every reader up to date.
class CalendarWriteFlow extends StatefulWidget {
  const CalendarWriteFlow({
    super.key,
    required this.writer,
    required this.onDone,
    required this.builder,
  });

  static const Key errorKey = ValueKey('calendar-write-error');
  static const Key retryKey = ValueKey('calendar-write-retry');
  static const Key dismissErrorKey = ValueKey('calendar-write-dismiss-error');

  final CalendarWriter writer;

  /// The host toasts [message]; [undo] non-null offers Undo (the host commits
  /// it with `isUndo: true`).
  final void Function(String message, CalendarWrite? undo) onDone;

  /// The buttons. `busy` is true from the press until the write is done or
  /// dismissed, confirm included, so a second press cannot start a second
  /// write under the first one's strip.
  ///
  /// What it builds is rebuilt FRESH after every write that went through:
  /// its state (an open "Move to…" field, the typed time) described the
  /// event before the write, and left standing it would offer the same move
  /// again over an event that has already moved.
  final Widget Function(BuildContext context, WriteStarter start, bool busy)
      builder;

  @override
  State<CalendarWriteFlow> createState() => _CalendarWriteFlowState();
}

enum _Phase { idle, previewing, confirming, committing, failed }

class _CalendarWriteFlowState extends State<CalendarWriteFlow> {
  _Phase _phase = _Phase.idle;
  CalendarWrite? _write;
  WritePreview? _preview;
  String _summary = '';
  String _doneMessage = '';
  String _error = '';
  CalendarWrite? _retry;

  /// Bumped on each success; it keys the builder's output, so the buttons'
  /// own state starts over.
  int _generation = 0;

  /// Where the keyboard lands when what held it goes: the strip, or a field
  /// disabled for the send, is gone at the end of a write, and focus would
  /// otherwise fall to the route — outside the screen's keys, so the `z`
  /// the toast offers would do nothing until a click.
  final FocusNode _focus =
      FocusNode(debugLabel: 'calendar-write-flow', skipTraversal: true);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// [change], keeping the keyboard in this flow when it was here or
  /// nowhere in particular — never taken from somewhere else it went.
  void _settle(VoidCallback change) {
    final primary = FocusManager.instance.primaryFocus;
    final keep =
        _focus.hasFocus || primary == null || primary is FocusScopeNode;
    setState(change);
    if (keep) _focus.requestFocus();
  }

  bool get _busy =>
      _phase == _Phase.previewing ||
      _phase == _Phase.confirming ||
      _phase == _Phase.committing;

  void _start(
    CalendarWrite write, {
    required String summary,
    required String doneMessage,
  }) {
    if (_busy) return;
    setState(() {
      _phase = _Phase.previewing;
      _write = write;
      _preview = null;
      _summary = summary;
      _doneMessage = doneMessage;
      _error = '';
      _retry = null;
    });
    _runPreview(write);
  }

  Future<void> _runPreview(CalendarWrite write) async {
    final result = await widget.writer.preview(write);
    if (!mounted || _write != write || _phase != _Phase.previewing) return;
    switch (result) {
      case PreviewFailed(:final message, :final retry):
        setState(() {
          _phase = _Phase.failed;
          _error = message;
          _retry = retry;
        });
      case PreviewReady(:final preview, :final needsConfirm):
        if (needsConfirm) {
          setState(() {
            _phase = _Phase.confirming;
            _preview = preview;
          });
        } else {
          _preview = preview;
          _commit(fromPreview: true);
        }
    }
  }

  /// Sends the write once. Only from the confirm, or straight from the dry
  /// run when it needs none ([fromPreview]); the phase moves to committing
  /// before the first await, so a click and an Enter landing in the same
  /// frame — both reaching here before any rebuild disables either — send
  /// one write, not two.
  Future<void> _commit({bool fromPreview = false}) async {
    final from = fromPreview ? _Phase.previewing : _Phase.confirming;
    if (_phase != from) return;
    final write = _write;
    final preview = _preview;
    if (write == null || preview == null) return;
    setState(() => _phase = _Phase.committing);
    final done = _doneMessage + emailedSuffix(preview.notifies);
    final onDone = widget.onDone;
    final outcome = await widget.writer.commit(write, preview: preview);
    if (outcome.ok) {
      // Said even when this widget has gone meanwhile: an answered invite's
      // row leaves the list the moment the mirror moves, which is before the
      // commit returns, and the toast belongs to the screen, not the row.
      onDone(done, outcome.undo);
      if (mounted) {
        _settle(() {
          _reset();
          _generation += 1;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = outcome.message;
      _retry = outcome.retry;
    });
  }

  void _reset() {
    _phase = _Phase.idle;
    _write = null;
    _preview = null;
    _error = '';
    _retry = null;
  }

  void _dismiss() => _settle(_reset);

  @override
  Widget build(BuildContext context) {
    final write = _write;
    final preview = _preview;
    final retry = _retry;
    return Focus(
      focusNode: _focus,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: ValueKey(_generation),
            child: widget.builder(context, _start, _busy),
          ),
          if (_phase == _Phase.confirming || _phase == _Phase.committing)
            if (write != null && preview != null) ...[
              const SizedBox(height: BondSpacing.s8),
              WriteConfirmStrip(
                summary: _summary,
                notifies: preview.notifies,
                confirmLabel: confirmLabelFor(write),
                dismissLabel: dismissLabelFor(write),
                busy: _phase == _Phase.committing,
                onConfirm: () => _commit(),
                onDismiss: _dismiss,
              ),
            ],
          if (_phase == _Phase.failed) ...[
            const SizedBox(height: BondSpacing.s4),
            Row(
              children: [
                Flexible(
                  child: Text(
                    _error,
                    key: CalendarWriteFlow.errorKey,
                    style: BondType.small.copyWith(color: BondColors.error),
                  ),
                ),
                if (retry != null)
                  TextButton(
                    key: CalendarWriteFlow.retryKey,
                    onPressed: () => _start(retry,
                        summary: _summary, doneMessage: _doneMessage),
                    child: const Text('Try again'),
                  ),
                IconButton(
                  key: CalendarWriteFlow.dismissErrorKey,
                  tooltip: 'Dismiss',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
