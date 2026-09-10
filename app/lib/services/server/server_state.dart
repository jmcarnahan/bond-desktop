import 'package:flutter/foundation.dart' show immutable, mapEquals;

/// Where the app's own copy of llama-server stands, right now.
///
/// A sealed family rather than an enum plus a bag of nullable fields,
/// because the interesting numbers only exist in some of the states: there
/// is no pid before the child is spawned and no per-model progress before it
/// is listening. Making that structural means the settings screen cannot
/// render "port null" and the supervisor cannot report a pid it does not
/// have.
///
/// Nothing here is UI. Each state carries what a caller needs to act, and
/// [ServerStateDescribe.summary] is the one place that turns a state into a
/// sentence, so the wording lives beside the states it describes rather than
/// in whatever widget happens to draw them.
@immutable
sealed class ServerState {
  const ServerState();
}

/// The user runs the servers by hand: the managed-server preference is off.
///
/// Distinct from [ServerStopped] because the two want opposite offers. A
/// stopped managed server wants a Start button; a disabled one wants the
/// preference, and starting it behind the user's back would take three
/// gigabytes of memory they did not ask for.
@immutable
class ServerDisabled extends ServerState {
  const ServerDisabled();

  @override
  bool operator ==(Object other) => other is ServerDisabled;

  @override
  int get hashCode => (ServerDisabled).hashCode;

  @override
  String toString() => 'ServerDisabled()';
}

/// Managed, and not running — either never started this launch, or stopped.
@immutable
class ServerStopped extends ServerState {
  const ServerStopped();

  @override
  bool operator ==(Object other) => other is ServerStopped;

  @override
  int get hashCode => (ServerStopped).hashCode;

  @override
  String toString() => 'ServerStopped()';
}

/// Spawned, or about to be, and not yet listening.
///
/// [port] is null only for the sliver of time before one is chosen, which is
/// why it is nullable here and required from [ServerLoading] on.
@immutable
class ServerStarting extends ServerState {
  final int? port;

  const ServerStarting({this.port});

  @override
  bool operator ==(Object other) => other is ServerStarting && other.port == port;

  @override
  int get hashCode => Object.hash(ServerStarting, port);

  @override
  String toString() => 'ServerStarting(port: $port)';
}

/// Listening, but still pulling weights into memory.
///
/// [loaded] is every model id the preset declares mapped to whether the
/// router says it is resident. It is the whole progress report: a
/// twenty-seven-billion-parameter model takes tens of seconds to mmap, and
/// without the per-model breakdown the app can only say "starting" for the
/// entire wait.
@immutable
class ServerLoading extends ServerState {
  final int port;
  final int pid;
  final Map<String, bool> loaded;

  const ServerLoading({
    required this.port,
    required this.pid,
    required this.loaded,
  });

  @override
  bool operator ==(Object other) =>
      other is ServerLoading &&
      other.port == port &&
      other.pid == pid &&
      mapEquals(other.loaded, loaded);

  @override
  int get hashCode => Object.hash(
        ServerLoading,
        port,
        pid,
        Object.hashAllUnordered(
          [for (final e in loaded.entries) Object.hash(e.key, e.value)],
        ),
      );

  @override
  String toString() => 'ServerLoading(port: $port, pid: $pid, loaded: $loaded)';
}

/// Every model the preset declares is resident and `/health` answers 200.
@immutable
class ServerReady extends ServerState {
  final int port;
  final int pid;

  const ServerReady({required this.port, required this.pid});

  @override
  bool operator ==(Object other) =>
      other is ServerReady && other.port == port && other.pid == pid;

  @override
  int get hashCode => Object.hash(ServerReady, port, pid);

  @override
  String toString() => 'ServerReady(port: $port, pid: $pid)';
}

/// The server will not run, and retrying on its own has stopped helping.
///
/// [logTail] rides along because the reason alone never explains a crash —
/// "exited (code 1)" is the same sentence for a corrupt GGUF, a missing
/// backend module and a model too large for the machine, and the last lines
/// the server printed are what tell them apart.
@immutable
class ServerFailed extends ServerState {
  final String reason;
  final List<String> logTail;

  const ServerFailed(this.reason, {this.logTail = const []});

  @override
  bool operator ==(Object other) =>
      other is ServerFailed &&
      other.reason == reason &&
      _sameLines(other.logTail, logTail);

  static bool _sameLines(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(ServerFailed, reason, Object.hashAll(logTail));

  @override
  String toString() =>
      'ServerFailed($reason, logTail: ${logTail.length} lines)';
}

/// Something else already holds the port this app wants.
///
/// Its own state rather than a [ServerFailed] because it is the one failure
/// the user can fix without a log: either a hand-started `make model` from
/// the old workflow, or a second copy of this app. [holder] is what `lsof`
/// says is on the socket, and it is nullable because `lsof` may be absent or
/// answer nothing.
@immutable
class ServerPortInUse extends ServerState {
  final int port;
  final String? holder;

  const ServerPortInUse(this.port, {this.holder});

  @override
  bool operator ==(Object other) =>
      other is ServerPortInUse && other.port == port && other.holder == holder;

  @override
  int get hashCode => Object.hash(ServerPortInUse, port, holder);

  @override
  String toString() => 'ServerPortInUse($port, holder: $holder)';
}

/// One sentence per state, for a status line.
///
/// An extension rather than a method on each class so the states stay pure
/// data and the wording stays together, where an inconsistency between two
/// of these sentences is visible in one screenful.
extension ServerStateDescribe on ServerState {
  String get summary => switch (this) {
        ServerDisabled() => 'Off — servers are started by hand',
        ServerStopped() => 'Stopped',
        ServerStarting(port: final port) =>
          port == null ? 'Starting…' : 'Starting… on port $port',
        ServerLoading(port: final port, loaded: final loaded) =>
          'Loading models (${loaded.values.where((v) => v).length} of '
              '${loaded.length}) on port $port',
        ServerReady(port: final port) => 'Ready on 127.0.0.1:$port',
        ServerFailed(reason: final reason) => 'Failed: $reason',
        ServerPortInUse(port: final port, holder: final holder) =>
          holder == null
              ? 'Port $port is in use'
              : 'Port $port is in use by $holder',
      };
}
