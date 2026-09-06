import 'dart:async';

/// Coalesces a burst of calls into the last one, and tells each caller whether
/// it is the one that survived.
///
/// It exists because `RawAutocomplete` has no debounce of its own: every
/// keystroke calls `optionsBuilder`, and the only thing the SDK does about the
/// pile-up is discard out-of-order results after the work is already done — a
/// directory search per keystroke either way.
///
/// The survivor flag rather than a callback or a stream, because it lets an
/// `optionsBuilder` stay one awaited expression —
/// `if (!await _debounce.settle()) return const [];` — with no state held
/// across the await and nothing to unsubscribe from.
class Debounced {
  Debounced({this.delay = const Duration(milliseconds: 250)});

  /// How long the silence has to last before the survivor is let through.
  final Duration delay;

  Timer? _timer;
  Completer<bool>? _pending;

  /// Resolves `true` after [delay] of silence — this caller is the survivor —
  /// and resolves `false` at once for every call a later call superseded.
  ///
  /// A superseded call is completed before its successor's timer starts, so
  /// the frame awaiting it is released immediately rather than at the end of
  /// the burst. Nobody is ever left hanging.
  Future<bool> settle() {
    _resolve(false);
    final completer = Completer<bool>();
    _pending = completer;
    _timer = Timer(delay, () => _resolve(true));
    return completer.future;
  }

  /// Cancels the pending call — it resolves `false` — and stops the timer.
  /// For `dispose`, where a still-armed timer would fire into a dead widget.
  void cancel() => _resolve(false);

  void _resolve(bool survived) {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(survived);
  }
}
