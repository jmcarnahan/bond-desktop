import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rebuilds [builder] with a fresh clock reading every [interval].
///
/// For the few words on screen that go stale by the minute — "in 18m",
/// "now" — so they can keep time without the whole pane rebuilding. The first
/// build uses [initial], which is the host's own `now`, so everything drawn in
/// one frame agrees about what time it is; only later ticks read [clock].
/// Tests hand a fixed [initial] and never wait thirty seconds, so they see
/// exactly the time they chose.
class ClockTick extends StatefulWidget {
  const ClockTick({
    super.key,
    required this.initial,
    required this.builder,
    this.interval = const Duration(seconds: 30),
    this.clock = DateTime.now,
  });

  final DateTime initial;
  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration interval;
  final DateTime Function() clock;

  @override
  State<ClockTick> createState() => _ClockTickState();
}

class _ClockTickState extends State<ClockTick> {
  late DateTime _now = widget.initial;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      setState(() => _now = widget.clock());
    });
  }

  @override
  void didUpdateWidget(ClockTick oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A host rebuild carries a newer reading than the last tick did.
    if (widget.initial != oldWidget.initial) _now = widget.initial;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
