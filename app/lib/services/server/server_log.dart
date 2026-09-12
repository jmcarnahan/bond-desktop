import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// The child server's output, on disk and in memory.
///
/// Two audiences, one writer. The FILE is for the user and for a bug report:
/// it is the only record of why a server that used to work stopped, and it
/// has to survive the app quitting. The RING is for the app itself — a
/// failure state carries its last lines so the screen can show what happened
/// without asking anyone to open a log — and it holds only this session's
/// lines, because a tail read back off disk after a rotation would be from
/// the wrong run.
///
/// Rotation is checked at [open] rather than on every write. A single run
/// appends steadily and the check is a `stat`; doing it per line would put a
/// syscall in front of every log line the server prints during a load.
class ServerLog {
  ServerLog(this.file, {this.maxBytes = 10 * 1024 * 1024, this.tailLines = 200});

  final File file;
  final int maxBytes;
  final int tailLines;

  IOSink? _sink;
  final List<String> _ring = [];

  /// Makes the log's folder, rotates a log that has grown past [maxBytes],
  /// and opens the sink this session appends to.
  ///
  /// Exactly one generation is kept. A second rotation replaces `.1` rather
  /// than shifting it along to `.2`: the previous run is worth having when
  /// today's run started badly, and anything older has been superseded by the
  /// run the user is actually asking about.
  Future<void> open() async {
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() > maxBytes) {
      final rotated = File('${file.path}.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    final sink = file.openWrite(mode: FileMode.append);
    // [write] is deliberately fire-and-forget, so NOTHING else watches this
    // sink. A disk that filled or a folder that turned unwritable would then
    // land as an unhandled async error from whichever `close()` happened to be
    // running — a crash raised by the LOG, in a class whose whole contract is
    // that no public method throws. Handled here, at the one place that can
    // see it.
    unawaited(sink.done.catchError((Object e) {
      debugPrint('server log: ${file.path} stopped accepting writes: $e');
    }));
    _sink = sink;
  }

  /// Appends one line, and remembers it.
  ///
  /// Synchronous by signature and buffered underneath, because it is called
  /// from a stream listener on the child's stdout: a server loading a model
  /// prints steadily, and awaiting each line would put back-pressure on the
  /// pipe the child is writing to.
  void write(String line) {
    _sink?.writeln(line);
    _ring.add(line);
    if (_ring.length > tailLines) {
      _ring.removeRange(0, _ring.length - tailLines);
    }
  }

  /// The last [tailLines] lines written this session, oldest first.
  List<String> get tail => List.unmodifiable(_ring);

  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (e) {
      // Closing a log is the last thing a shutdown does, and a log that could
      // not be written is not a reason to fail the shutdown — the error the
      // sink is carrying has already been reported by [open]'s handler.
      debugPrint('server log: could not close ${file.path}: $e');
    }
  }
}
