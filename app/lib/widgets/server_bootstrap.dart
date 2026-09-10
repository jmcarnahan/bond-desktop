import 'dart:async';
// [AppExitResponse] is an engine type. Material re-exports the widgets half of
// the lifecycle listener but not the answer its exit hook returns.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';

/// Starts the app's own model server at launch, and kills it at quit.
///
/// A widget rather than a call in `main()` because both halves need a
/// container: the supervisor is a provider, and the only thing that outlives
/// every screen while still holding a `ref` is a widget wrapped around the
/// whole tree. It renders nothing of its own — [child] is returned unchanged —
/// so it can sit above [AuthGate] without having an opinion about which screen
/// is showing.
///
/// The start is fire-and-forget on purpose. `ensureRunning` adopts a server
/// this app left behind or spawns one, and both can take tens of seconds
/// against a twenty-seven-billion-parameter model; the mail must be readable
/// during that, and every client parks and resumes on its own when the server
/// arrives. With the managed preference off — the default — it is a no-op that
/// reports `ServerDisabled` and spawns nothing.
class ServerBootstrap extends ConsumerStatefulWidget {
  final Widget child;

  const ServerBootstrap({super.key, required this.child});

  @override
  ConsumerState<ServerBootstrap> createState() => _ServerBootstrapState();
}

class _ServerBootstrapState extends ConsumerState<ServerBootstrap> {
  AppLifecycleListener? _lifecycle;

  /// How long a quit waits for the child to die before going anyway. The
  /// supervisor's own stop escalates SIGTERM to SIGKILL inside this, and a
  /// window that would not close because a server is mid-`mmap` is a worse
  /// failure than a process the OS reaps a moment later.
  static const Duration _exitGrace = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(modelServerSupervisorProvider).ensureRunning());
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
  }

  /// The FIRST line of defence, not the only one. A child started with
  /// `ProcessStartMode.normal` still outlives a parent that dies without
  /// running this — a crash, a force quit, and the Dart exit that
  /// flutter#134255 describes — so the Runner's `applicationWillTerminate`
  /// reaps the pid file as well, and the next launch reaps it again.
  ///
  /// [AppExitResponse.exit] whatever happens: a server that will not stop is
  /// not a reason to refuse to quit.
  Future<AppExitResponse> _onExit() async {
    try {
      await ref
          .read(modelServerSupervisorProvider)
          .stop()
          .timeout(_exitGrace);
    } catch (_) {}
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
